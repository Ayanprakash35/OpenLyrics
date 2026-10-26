import AppKit
import os

/// Listens to the Mac's sound output while lyrics show, so the lyrics can move with the music:
/// beats, bass and loudness from Open Glow's capture and beat detection (`AudioEngine`,
/// `BeatDetector`).
///
/// Needs Screen & System Audio Recording access, which macOS asks for the first time capture is
/// requested; OpenLyrics only ever captures audio (and a 2×2 placeholder video frame
/// ScreenCaptureKit insists on), never the screen's contents or the microphone. Runs only while
/// it's wanted — the setting is on, a song plays and lyrics are visible — and stops the moment it
/// isn't.
@MainActor
final class MusicReactor {
    private let logger = Logger(subsystem: "com.openlyrics.app", category: "MusicReactor")
    private let engine = AudioEngine()
    private let detector: BeatDetector
    private var wanted = false
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0

    /// Main actor, when capture starts, stops or fails, or access changes.
    var onStateChange: (() -> Void)?

    init() {
        detector = BeatDetector(ringBuffer: engine.ringBuffer)
        engine.onStateChange = { [weak self] in self?.onStateChange?() }
        engine.onStartFailed = { [weak self] _ in self?.scheduleRetry(ranFor: 0) }
        engine.onUnexpectedStop = { [weak self] _, ranFor in self?.scheduleRetry(ranFor: ranFor) }
    }

    var isRunning: Bool { engine.isCapturing }

    /// Whether macOS lets OpenLyrics capture audio. A live check that never prompts.
    var hasAccess: Bool { engine.checkPermission() == .granted }

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
            engine.stop()
            detector.stop()
            logger.info("Stopped listening")
        }
    }

    /// Asks macOS for access (shows its prompt the first time). Returns whether access is granted
    /// now; when it isn't, the user has to allow OpenLyrics in System Settings and relaunch it.
    func requestAccess() async -> Bool {
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
