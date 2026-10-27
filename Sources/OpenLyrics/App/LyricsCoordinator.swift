import AppKit
import Combine
import os

/// Coordinator tuning.
enum CoordinatorConfig {
    /// Seconds to wait for the first position sample, which brings the track's length, before
    /// looking lyrics up without it. The length tells recordings of one song apart.
    /// Sane range: 0.5–3.
    static let durationWait: TimeInterval = 1.5
    /// Seconds before trying again when no lyrics provider could be reached. Sane range: 15–120.
    static let retryAfterUnavailable: TimeInterval = 30
}

/// Connects the parts: what's playing (`NowPlayingMonitor`) and where (`PositionTracker`), the
/// track's lyrics (`LyricsService`) and colors (`ColorExtractor`), into the `LyricsSession` the
/// overlay draws; and where the overlay shows, from the settings and the lock state.
@MainActor
final class LyricsCoordinator {
    let settings: Settings
    let session = LyricsSession()
    let overlay: OverlayController
    private let logger = Logger(subsystem: "com.openlyrics.app", category: "Coordinator")
    private let monitor: NowPlayingMonitor
    private let tracker: PositionTracker
    private let service = LyricsService()
    private let screenSession = ScreenSessionMonitor()
    private let screenAwake = ScreenAwake()
    private let reactor = MusicReactor()
    private var lookupTask: Task<Void, Never>?
    private var durationWait: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    /// The track whose lookup has started, so each track is looked up once.
    private var lookedUpIdentity: String?
    private var cancellables: Set<AnyCancellable> = []

    private(set) var nowPlaying: NowPlayingMonitor.Status = .stopped
    /// Main actor, whenever something the status menu shows changes.
    var onChange: (() -> Void)?

    init(settings: Settings) {
        self.settings = settings
        let scripts = NowPlayingScriptRunner()
        monitor = NowPlayingMonitor(scripts: scripts)
        tracker = PositionTracker(scripts: scripts)
        let reactor = self.reactor
        overlay = OverlayController(session: session, settings: settings, audio: { reactor.snapshot() })
    }

    func start() {
        monitor.players = settings.players
        monitor.onStatusChange = { [weak self] in self?.handle($0) }
        monitor.onArtwork = { [weak self] track, data in self?.handleArtwork(for: track, data: data) }
        tracker.onClockChange = { [weak self] in self?.handleClock($0) }
        screenSession.onChange = { [weak self] _, _ in self?.refreshOverlay() }
        overlay.onPreviewChange = { [weak self] in self?.refreshOverlay() }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.overlay.rebuildForScreens() }
        }
        settings.$players.dropFirst().removeDuplicates().sink { [weak self] players in
            self?.monitor.players = players
        }.store(in: &cancellables)
        settings.$providers.dropFirst().removeDuplicates().sink { [weak self] _ in
            // Published in willSet: read the new set once it's stored.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.reloadLyrics(bypassCache: true) } }
        }.store(in: &cancellables)
        settings.$displayID.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.overlay.rebuildForScreens() } }
        }.store(in: &cancellables)
        settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshOverlay() } }
        }.store(in: &cancellables)

        if Diagnostics.isDemo {
            startDemo()
        } else {
            monitor.start()
        }
        refreshOverlay()
    }

    /// Plays the built-in demo lyrics on a loop instead of following a player.
    private func startDemo() {
        logger.notice("Demo mode")
        let track = Diagnostics.demoTrack
        nowPlaying = .playing(track)
        session.begin(track)
        session.setLookup(.found(Diagnostics.demoLyrics))
        session.palette = Diagnostics.demoPalette
        session.accents = Diagnostics.demoAccents
        session.isPlaying = true
        restartDemoClock()
        Timer.scheduledTimer(withTimeInterval: Diagnostics.demoDuration, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartDemoClock() }
        }
        onChange?()
    }

    private func restartDemoClock() {
        let sample = NowPlayingMonitor.PositionSample(
            state: .playing, trackID: Diagnostics.demoTrack.id, position: 0, duration: Diagnostics.demoDuration
        )
        session.clock = PlaybackClock(sample: sample, at: ProcessInfo.processInfo.systemUptime)
    }

    func stop() {
        monitor.stop()
        tracker.stop()
        reactor.setWanted(false)
        screenAwake.setHeld(false)
    }

    /// Turns music reactions on, asking macOS for audio capture access first if needed. Without
    /// access, explains where to allow it and leaves the setting off.
    func enableMusicReactions() {
        Task { [weak self] in
            guard let self else { return }
            let granted = self.reactor.hasAccess ? true : await self.reactor.requestAccess()
            if granted {
                self.settings.reactToMusic = true
                self.refreshOverlay()
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Allow OpenLyrics to hear your Mac's sound"
            alert.informativeText = """
                To move with the music, OpenLyrics listens to your Mac's sound output (never the \
                microphone or the screen's contents). Turn OpenLyrics on under Screen & System Audio \
                Recording in System Settings, then quit and reopen OpenLyrics.

                While it listens, macOS counts OpenLyrics as recording the screen, so Apple Music may \
                pause for a moment when you lock or unlock your Mac.
                """
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { MusicReactor.openAccessSettings() }
        }
    }

    /// Asks the players again (after granting Automation access in System Settings).
    func refreshNowPlaying() {
        monitor.refresh()
    }

    /// Looks the current track's lyrics up again, skipping the cache when `bypassCache`.
    func reloadLyrics(bypassCache: Bool) {
        guard let track = session.track else { return }
        lookedUpIdentity = track.identity
        lookUp(track, bypassCache: bypassCache)
    }

    func clearLyricsCache() {
        Task { await service.clearCache() }
    }

    func previewLockScreen() {
        overlay.previewLockScreen()
    }

    var lockScreenAvailable: Bool { overlay.lockSpace.isAvailable }

    // MARK: - Now playing

    private func handle(_ status: NowPlayingMonitor.Status) {
        nowPlaying = status
        switch status {
        case .playing(let track):
            if session.track?.identity != track.identity {
                begin(track)
            }
            session.isPlaying = true
            tracker.follow(track, isPlaying: true)
        case .notPlaying:
            session.isPlaying = false
            tracker.follow(session.track, isPlaying: false)
        case .noPlayer, .stopped, .notAuthorized:
            session.isPlaying = false
            tracker.stop()
            if session.track != nil { begin(nil) }
        }
        refreshOverlay()
        onChange?()
    }

    private func begin(_ track: NowPlayingMonitor.Track?) {
        lookupTask?.cancel()
        durationWait?.cancel()
        retryTask?.cancel()
        lookedUpIdentity = nil
        session.begin(track)
        guard track != nil else { return }
        if let track { logger.info("New track on \(track.player.displayName, privacy: .public)") }
        durationWait = Task { [weak self] in
            try? await Task.sleep(for: .seconds(CoordinatorConfig.durationWait))
            guard !Task.isCancelled else { return }
            self?.lookUpIfNeeded(withoutLength: true)
        }
    }

    private func handleClock(_ clock: PlaybackClock) {
        guard let track = session.track, track.id.isEmpty || clock.trackID.isEmpty || clock.trackID == track.id else { return }
        session.clock = clock
        lookUpIfNeeded(withoutLength: false)
    }

    private func lookUpIfNeeded(withoutLength: Bool) {
        guard let track = session.track, lookedUpIdentity != track.identity else { return }
        guard withoutLength || session.clock?.duration != nil else { return }
        lookedUpIdentity = track.identity
        durationWait?.cancel()
        lookUp(track, bypassCache: false)
    }

    private func lookUp(_ track: NowPlayingMonitor.Track, bypassCache: Bool) {
        lookupTask?.cancel()
        retryTask?.cancel()
        guard !track.title.trimmingCharacters(in: .whitespaces).isEmpty else {
            session.setLookup(.notFound)
            onChange?()
            return
        }
        let query = TrackQuery(title: track.title, artist: track.artist, album: track.album, duration: session.clock?.duration)
        let providers = settings.providers
        let service = self.service
        session.setSearching()
        onChange?()
        lookupTask = Task { [weak self] in
            let result = await service.lookup(query, using: providers, bypassCache: bypassCache)
            guard !Task.isCancelled, let self, self.session.track?.identity == track.identity else { return }
            self.session.setLookup(result)
            self.refreshOverlay()
            self.onChange?()
            if result == .unavailable { self.scheduleRetry(for: track) }
        }
    }

    private func scheduleRetry(for track: NowPlayingMonitor.Track) {
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(CoordinatorConfig.retryAfterUnavailable))
            guard !Task.isCancelled, let self, self.session.track?.identity == track.identity,
                  self.session.lookupState == .unavailable else { return }
            self.lookUp(track, bypassCache: true)
        }
    }

    // MARK: - Colors

    private func handleArtwork(for track: NowPlayingMonitor.Track, data: Data?) {
        guard session.track?.identity == track.identity else { return }
        guard let data else {
            session.palette = .fallback
            session.accents = []
            return
        }
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { ColorExtractor.extract(fromImageData: data) }.value
            guard let self, self.session.track?.identity == track.identity else { return }
            self.session.palette = result?.palette ?? .fallback
            self.session.accents = result?.accents ?? []
        }
    }

    // MARK: - Overlay

    private func refreshOverlay() {
        overlay.apply(OverlayController.Conditions(
            hasLyrics: session.hasSyncedLyrics,
            isPlaying: session.isPlaying,
            session: screenSession.reasons,
            showOnDesktop: settings.showOnDesktop,
            showOnLockScreen: settings.showOnLockScreen,
            lockScreenAvailable: overlay.lockSpace.isAvailable,
            previewingLockScreen: overlay.isPreviewingLockScreen
        ))
        let onLockScreen = overlay.visibility.lockScreen && screenSession.reasons.contains(.screenLocked)
        screenAwake.setHeld(onLockScreen && settings.keepAwakeWhenLocked)
        // Listening runs steadily while a song is loaded, not just while lyrics show: every start
        // and stop of capture makes Apple Music re-check its copy protection, which can stutter it.
        reactor.setWanted(settings.reactToMusic && session.track != nil)
    }
}
