import AppKit
import os

/// Listens to the Mac's sound output so the lyrics can move with the music: beats, bass and
/// loudness from Open Glow's beat detection (`BeatDetector`).
///
/// On macOS 14.2 and later it listens through a Core Audio process tap (`SystemAudioTap`), which
/// needs only System Audio Recording access and isn't a screen recording — so Apple Music doesn't
/// stall when the Mac locks or unlocks. Earlier systems fall back to ScreenCaptureKit
/// (`AudioEngine`), which macOS counts as recording the screen. Never the microphone.
@MainActor
final class MusicReactor {
    private let logger = Logger(subsystem: "com.openlyrics.app", category: "MusicReactor")
    private let engine = AudioEngine()
    private let detector: BeatDetector
    /// The process tap, where the system has one (typed `AnyObject` for the availability check).
    private let tap: AnyObject?
    private var wanted = false
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0

    /// Main actor, when capture starts, stops or fails, or access changes.
    var onStateChange: (() -> Void)?

    init() {
        detector = BeatDetector(ringBuffer: engine.ringBuffer)
        if #available(macOS 14.2, *) {
            tap = SystemAudioTap(ringBuffer: engine.ringBuffer)
        } else {
            tap = nil
        }
        engine.onStateChange = { [weak self] in self?.onStateChange?() }
        engine.onStartFailed = { [weak self] _ in self?.scheduleRetry(ranFor: 0) }
        engine.onUnexpectedStop = { [weak self] _, ranFor in self?.scheduleRetry(ranFor: ranFor) }
    }

    /// Listening through a process tap rather than a screen recording.
    var usesTap: Bool { tap != nil }

    var isRunning: Bool {
        if #available(macOS 14.2, *), let tap = tap as? SystemAudioTap { return tap.isRunning }
        return engine.isCapturing
    }

    /// Whether macOS lets OpenLyrics capture audio. A live check that never prompts. A tap can't be
    /// checked ahead of time: macOS asks when it first starts.
    var hasAccess: Bool { usesTap || engine.checkPermission() == .granted }

    /// The latest analysis: beat pulse, bass, mid, treble, loudness. Safe from any thread; all
    /// zero while not running.
    nonisolated func snapshot() -> AudioAnalysisState {
        detector.snapshot()
    }

    /// Starts or stops listening.
    func setWanted(_ wanted: Bool) {
        guard wanted != self.wanted else { return }
        self.wanted = wanted
        if wanted {
            retryAttempt = 0
            start()
        } else {
            retryTask?.cancel()
            retryTask = nil
            if #available(macOS 14.2, *), let tap = tap as? SystemAudioTap { tap.stop() }
            engine.stop()
            detector.stop()
            logger.info("Stopped listening")
        }
    }

    /// Stops listening for good, waiting until the audio tap is gone: call when quitting.
    func shutdown() {
        wanted = false
        retryTask?.cancel()
        if #available(macOS 14.2, *), let tap = tap as? SystemAudioTap { tap.stopAndWait() }
        engine.stop()
        detector.stop()
        logger.info("Stopped listening (quitting)")
    }

    /// Asks macOS for access (shows its prompt the first time). Returns whether access is granted
    /// now; when it isn't, the user has to allow OpenLyrics in System Settings and relaunch it.
    func requestAccess() async -> Bool {
        if usesTap { return true }
        engine.allowRetryAfterRefusal()
        await engine.registerForScreenRecording()
        let granted = engine.permissionState == .granted
        if granted, wanted { start() }
        onStateChange?()
        return granted
    }

    static func openAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func start() {
        if #available(macOS 14.2, *), let tap = tap as? SystemAudioTap {
            guard wanted, !tap.isActive else { return }
            detector.start()
            tap.start { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.logger.error("Couldn't start the audio tap: \(String(describing: error), privacy: .public)")
                        self.scheduleRetry(ranFor: 0)
                    } else {
                        self.logger.info("Listening (process tap)")
                    }
                    self.onStateChange?()
                }
            }
            return
        }
        guard wanted, !engine.isCapturing, !engine.isStarting else { return }
        guard engine.checkPermission() == .granted else {
            logger.notice("Not listening: no Screen & System Audio Recording access")
            onStateChange?()
            return
        }
        detector.start()
        engine.start()
        logger.info("Listening")
    }

    /// Capture stopped on its own (the display changed, the system restarted capture services):
    /// try again after a growing delay, starting over once a run lasted long enough.
    private func scheduleRetry(ranFor: TimeInterval) {
        guard wanted else { return }
        if ranFor >= CaptureRetryConfig.healthyRunDuration { retryAttempt = 0 }
        let delay = CaptureRetryConfig.delay(CaptureRetryConfig.restartDelays, attempt: retryAttempt)
        retryAttempt += 1
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.wanted else { return }
            self.detector.restartSession()
            self.start()
        }
    }
}
