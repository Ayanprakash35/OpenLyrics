import AVFoundation
import CoreAudio
import os

/// Captures the Mac's sound output with a Core Audio process tap (macOS 14.2 and later) and feeds
/// 48 kHz stereo frames into `ringBuffer` for `BeatDetector`.
///
/// Unlike ScreenCaptureKit, a tap is not a screen-recording session: the window server never
/// reports a "screen watcher", so Apple Music doesn't re-check its copy protection — and stall for
/// a moment — every time the Mac locks or unlocks. It needs only "System Audio Recording" access,
/// which macOS asks for the first time a tap starts.
///
/// The tap covers every process's output. Core Audio delivers it through a private aggregate
/// device clocked by the current output device; when the output device changes (headphones
/// plugged in), the tap is rebuilt on the new one.
@available(macOS 14.2, *)
final class SystemAudioTap: @unchecked Sendable {
    enum TapError: Error, CustomStringConvertible {
        case coreAudio(String, OSStatus)
        case format(String)

        var description: String {
            switch self {
            case .coreAudio(let step, let status): "\(step) failed (\(status))"
            case .format(let detail): detail
            }
        }
    }

    private let logger = Logger(subsystem: "com.openlyrics.app", category: "AudioTap")
    private let ringBuffer: AudioRingBuffer
    /// Delivery and conversion run here; start and stop hop here too, so they never overlap a
    /// buffer being processed.
    private let queue = DispatchQueue(label: "com.openlyrics.audio.tap", qos: .userInteractive)
    private let targetFormat: AVAudioFormat

    // Touched only on `queue`.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converted: AVAudioPCMBuffer?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var loggedFirstBuffer = false

    init(ringBuffer: AudioRingBuffer) {
        self.ringBuffer = ringBuffer
        targetFormat = AVAudioFormat(standardFormatWithSampleRate: AudioEngineConfig.targetSampleRate, channels: 2)!
    }

    deinit {
        let listener = deviceListener
        queue.sync {
            teardown()
            if let listener { Self.removeDeviceListener(listener) }
        }
    }

    private enum State { case idle, starting, running }
    /// Readable from any thread without waiting on `queue`, which can sit in a permission prompt.
    private let state = OSAllocatedUnfairLock(initialState: State.idle)

    /// Starting or running.
    var isActive: Bool { state.withLock { $0 != .idle } }
    var isRunning: Bool { state.withLock { $0 == .running } }

    /// Starts tapping in the background and reports the outcome on `queue` (nil when listening).
    /// The first start can wait for the user to answer macOS's permission prompt, so it never
    /// runs on the caller's thread. Restarts on output device changes until `stop()`.
    func start(completion: @escaping @Sendable (TapError?) -> Void) {
        let alreadyActive = state.withLock { current -> Bool in
            guard current == .idle else { return true }
            current = .starting
            return false
        }
        guard !alreadyActive else { return }
        queue.async { [self] in
            do throws(TapError) {
                try build()
                listenForDeviceChanges()
                state.withLock { $0 = .running }
                completion(nil)
            } catch {
                teardown()
                state.withLock { $0 = .idle }
                completion(error)
            }
        }
    }

    /// Stops tapping, after a start still in progress has finished.
    func stop() {
        state.withLock { $0 = .idle }
        queue.async { [self] in
            // A start that finished after stop() was called is undone here.
            guard !isActive else { return }
            if let listener = deviceListener {
                Self.removeDeviceListener(listener)
                deviceListener = nil
            }
            teardown()
        }
    }

    /// Stops and destroys the tap before returning (up to `timeout`), for quitting: the process
    /// must not exit with the tap still registered, or Core Audio can keep it running.
    func stopAndWait(timeout: TimeInterval = 1) {
        state.withLock { $0 = .idle }
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            if let listener = deviceListener {
                Self.removeDeviceListener(listener)
                deviceListener = nil
            }
            teardown()
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    // MARK: - Building and tearing down (on `queue`)

    private func build() throws(TapError) {
        dispatchPrecondition(condition: .onQueue(queue))
        // Whatever a quick stop-and-start left behind goes first; teardown is safe to repeat.
        teardown()
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "OpenLyrics"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the audio tap")

        var asbd = AudioStreamBasicDescription()
        try check(Self.readFormat(of: tapID, into: &asbd), "Reading the tap format")
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw .format("Unsupported tap format: \(asbd.mSampleRate) Hz, \(asbd.mChannelsPerFrame) ch")
        }
        sourceFormat = format
        converter = nil

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OpenLyrics listening",
            kAudioAggregateDeviceUIDKey: "com.openlyrics.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Creating the aggregate device")

        var newProc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.deliver(input)
        }, "Creating the audio callback")
        procID = newProc
        try check(AudioDeviceStart(aggregateID, procID), "Starting the audio tap")
        logger.notice("Listening through a process tap: \(asbd.mSampleRate, privacy: .public) Hz, \(asbd.mChannelsPerFrame, privacy: .public) ch")
    }

    private func teardown() {
        dispatchPrecondition(condition: .onQueue(queue))
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = kAudioObjectUnknown
        tapID = kAudioObjectUnknown
        converter = nil
        converted = nil
    }

    private func check(_ status: OSStatus, _ step: String) throws(TapError) {
        guard status == noErr else { throw .coreAudio(step, status) }
    }

    // MARK: - Output device changes

    private func listenForDeviceChanges() {
        guard deviceListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // Already on `queue`: the listener is registered with it.
            guard self.procID != nil else { return }
            self.logger.notice("Output device changed; rebuilding the tap")
            self.teardown()
            do { try self.build() } catch { self.logger.error("Couldn't rebuild the tap: \(String(describing: error), privacy: .public)") }
        }
        var address = Self.defaultOutputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        deviceListener = listener
    }

    private static func removeDeviceListener(_ listener: @escaping AudioObjectPropertyListenerBlock) {
        var address = defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, listener)
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func defaultOutputUID() throws(TapError) -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var address = defaultOutputAddress
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { throw .coreAudio("Finding the output device", status) }
        var uid: Unmanaged<CFString>?
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let uidStatus = AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &size, &uid)
        guard uidStatus == noErr, let uid else { throw .coreAudio("Reading the output device", uidStatus) }
        return uid.takeRetainedValue() as String
    }

    private static func readFormat(of tap: AudioObjectID, into format: inout AudioStreamBasicDescription) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
    }

    // MARK: - Delivery (on `queue`)

    private func deliver(_ input: UnsafePointer<AudioBufferList>) {
        guard let sourceFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, bufferListNoCopy: input, deallocator: nil),
              buffer.frameLength > 0 else { return }
        if !loggedFirstBuffer {
            loggedFirstBuffer = true
            logger.notice("First tapped buffer: \(buffer.frameLength, privacy: .public) frames")
        }
        if sourceFormat == targetFormat || Self.matchesTarget(sourceFormat) {
            write(buffer)
            return
        }
        if converter == nil {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate) + 32
        if converted == nil || converted!.frameCapacity < capacity {
            converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        }
        guard let converted else { return }
        converted.frameLength = 0
        let feeder = OneShotInput(buffer)
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if let next = feeder.take() {
                inputStatus.pointee = .haveData
                return next
            }
            // .noDataNow keeps the resampler's state for the next buffer.
            inputStatus.pointee = .noDataNow
            return nil
        }
        if status != .error { write(converted) }
    }

    private static func matchesTarget(_ format: AVAudioFormat) -> Bool {
        format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved
            && format.sampleRate == AudioEngineConfig.targetSampleRate && (1...2).contains(format.channelCount)
    }

    /// Non-interleaved float frames into the ring buffer; mono drives both channels.
    private func write(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let right = buffer.format.channelCount > 1 ? channels[1] : channels[0]
        ringBuffer.write(left: channels[0], right: right, count: Int(buffer.frameLength))
    }
}
