import AppKit
import Testing
@testable import OpenLyrics

private typealias Sample = NowPlayingMonitor.PositionSample

private func sample(_ position: Double, playing: Bool = true, track: String = "t1", duration: Double? = 200) -> Sample {
    Sample(state: playing ? .playing : .paused, trackID: track, position: position, duration: duration)
}

@Suite("Playback clock")
struct PlaybackClockTests {
    @Test func runsInRealTimeWhilePlaying() {
        let clock = PlaybackClock(sample: sample(10), at: 100)
        #expect(clock.position(at: 100) == 10)
        #expect(clock.position(at: 102.5) == 12.5)
    }

    @Test func standsStillWhilePaused() {
        let clock = PlaybackClock(sample: sample(10, playing: false), at: 100)
        #expect(clock.position(at: 105) == 10)
    }

    @Test func stopsAtTheEndOfTheTrack() {
        let clock = PlaybackClock(sample: sample(199), at: 0)
        #expect(clock.position(at: 10) == 200)
    }

    @Test func smallDriftIsSmoothed() {
        var clock = PlaybackClock(sample: sample(10), at: 100)
        clock.apply(sample(11.1), at: 101)
        let position = clock.position(at: 101)
        #expect(position > 11 && position < 11.1)
    }

    @Test func aSeekSnaps() {
        var clock = PlaybackClock(sample: sample(10), at: 100)
        clock.apply(sample(60), at: 101)
        #expect(clock.position(at: 101) == 60)
    }

    @Test func pauseFreezesWhereItWas() {
        var clock = PlaybackClock(sample: sample(10), at: 100)
        clock.pause(at: 103)
        #expect(clock.position(at: 110) == 13)
        #expect(!clock.isPlaying)
    }
}

@Suite("Position script replies")
struct PositionScriptTests {
    private func code(_ text: String) -> OSType { NowPlayingScript.fourCharCode(text) }

    private func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for (index, item) in items.enumerated() { list.insert(item, at: index + 1) }
        return list
    }

    private func number(_ value: Double) -> NSAppleEventDescriptor { NSAppleEventDescriptor(double: value) }

    @Test func spotifyDurationIsMilliseconds() {
        let reply = list([
            NSAppleEventDescriptor(enumCode: code("kPSP")), NSAppleEventDescriptor(string: "spotify:track:abc"),
            number(42.5), NSAppleEventDescriptor(int32: 200_000),
        ])
        guard case .sample(let sample) = NowPlayingScript.parsePosition(reply, player: .spotify) else {
            Issue.record("expected a sample")
            return
        }
        #expect(sample.trackID == "spotify:track:abc")
        #expect(sample.position == 42.5)
        #expect(sample.duration == 200)
        #expect(sample.state == .playing)
    }

    @Test func musicDurationIsSecondsAndIDsAreCanonical() {
        let reply = list([NSAppleEventDescriptor(enumCode: code("kPSp")), NSAppleEventDescriptor(string: "abc123"), number(5), number(180.5)])
        guard case .sample(let sample) = NowPlayingScript.parsePosition(reply, player: .music) else {
            Issue.record("expected a sample")
            return
        }
        #expect(sample.trackID == "0000000000ABC123")
        #expect(sample.duration == 180.5)
        #expect(sample.state == .paused)
    }

    @Test func stoppedAndEmptyReplies() {
        #expect(NowPlayingScript.parsePosition(list([NSAppleEventDescriptor(enumCode: code("kPSS"))]), player: .music) == .idle)
        #expect(NowPlayingScript.parsePosition(list([]), player: .music) == .unavailable)
    }

    @Test func missingDurationIsNil() {
        let missing = NSAppleEventDescriptor(typeCode: code("msng"))
        let reply = list([NSAppleEventDescriptor(enumCode: code("kPSP")), NSAppleEventDescriptor(string: ""), number(3), missing])
        guard case .sample(let sample) = NowPlayingScript.parsePosition(reply, player: .music) else {
            Issue.record("expected a sample")
            return
        }
        #expect(sample.duration == nil)
        #expect(sample.trackID == "")
    }
}

@Suite("Overlay visibility")
struct OverlayVisibilityTests {
    private func conditions(
        lyrics: Bool = true, playing: Bool = true, session: SessionPauseReasons = [],
        desktop: Bool = true, lock: Bool = true, available: Bool = true, preview: Bool = false
    ) -> OverlayController.Conditions {
        .init(hasLyrics: lyrics, isPlaying: playing, session: session, showOnDesktop: desktop,
              showOnLockScreen: lock, lockScreenAvailable: available, previewingLockScreen: preview)
    }

    private func visibility(_ conditions: OverlayController.Conditions) -> OverlayController.Visibility {
        OverlayController.visibility(for: conditions)
    }

    @Test func desktopWhileUnlocked() {
        #expect(visibility(conditions()) == .init(desktop: true, lockScreen: false))
    }

    @Test func lockScreenWhileLocked() {
        #expect(visibility(conditions(session: .screenLocked)) == .init(desktop: false, lockScreen: true))
        #expect(visibility(conditions(session: .screenLocked, lock: false)) == .init(desktop: false, lockScreen: false))
        #expect(visibility(conditions(session: .screenLocked, available: false)) == .init(desktop: false, lockScreen: false))
    }

    @Test func nothingWithoutLyricsOrPlayback() {
        #expect(visibility(conditions(lyrics: false)) == .init(desktop: false, lockScreen: false))
        #expect(visibility(conditions(playing: false)) == .init(desktop: false, lockScreen: false))
        #expect(visibility(conditions(playing: false, session: .screenLocked)) == .init(desktop: false, lockScreen: false))
    }

    @Test func nothingWhileAsleepOrSwitchedOut() {
        for reason: SessionPauseReasons in [.displaysAsleep, .systemAsleep, .screenSaver, .sessionInactive] {
            #expect(visibility(conditions(session: reason)) == .init(desktop: false, lockScreen: false))
            #expect(visibility(conditions(session: [reason, .screenLocked])) == .init(desktop: false, lockScreen: false))
        }
    }

    @Test func previewSwapsTheDesktopForTheLockScreenLayout() {
        #expect(visibility(conditions(preview: true)) == .init(desktop: false, lockScreen: true))
        #expect(visibility(conditions(playing: false, preview: true)) == .init(desktop: false, lockScreen: true))
    }
}

@Suite("Settings")
@MainActor
struct SettingsTests {
    private func freshDefaults() -> UserDefaults {
        let name = "openlyrics-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsShowEverywhereWithEveryPlayerAndSource() {
        let settings = Settings(defaults: freshDefaults())
        #expect(settings.showOnDesktop && settings.showOnLockScreen)
        #expect(settings.players == Set(NowPlayingMonitor.Player.allCases))
        #expect(settings.providers == Set(LyricsProviderID.allCases))
        #expect(settings.syncOffset == 0)
    }

    @Test func changesPersist() {
        let defaults = freshDefaults()
        let settings = Settings(defaults: defaults)
        settings.position = .top
        settings.players = [.spotify]
        settings.providers = []
        settings.nudgeOffset(by: Settings.offsetStep)
        let reloaded = Settings(defaults: defaults)
        #expect(reloaded.position == .top)
        #expect(reloaded.players == [.spotify])
        #expect(reloaded.providers.isEmpty)
        #expect(reloaded.syncOffset == 0.25)
    }

    @Test func offsetStaysOnStepsAndInRange() {
        let settings = Settings(defaults: freshDefaults())
        for _ in 0..<100 { settings.nudgeOffset(by: Settings.offsetStep) }
        #expect(settings.syncOffset == Settings.offsetRange.upperBound)
        settings.syncOffset = 0.1
        settings.nudgeOffset(by: -Settings.offsetStep)
        #expect(settings.syncOffset == -0.25)
    }
}
