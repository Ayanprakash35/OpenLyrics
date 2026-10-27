import Foundation
import os

/// Position polling tuning.
enum PositionTrackerConfig {
    /// Seconds between position samples while a track plays. Players don't announce seeks, so this
    /// bounds how long a seek takes to show. Sane range: 0.75–3.
    static let interval: TimeInterval = 1.25
    /// Seconds a sample may drift so macOS can batch the wakeup. Sane range: 0.05–0.3.
    static let tolerance: TimeInterval = 0.15
}

/// Samples the playing player's position on a short timer and keeps a `PlaybackClock` for the
/// current track. Polls only while a track plays; `sampleNow()` takes one at once (after a track
/// change, a pause or a resume).
@MainActor
final class PositionTracker {
    private let logger = Logger(subsystem: "com.openlyrics.app", category: "Position")
    private let scripts: any NowPlayingQuerying
    private let now: @MainActor () -> TimeInterval
    private var timer: Timer?
    private var inFlight = false
    private var sampleAgain = false
    /// Bumped on every target change, so a sample for an earlier target is dropped.
    private var generation = 0

    /// The player and track being followed; nil when nothing plays.
    private(set) var target: (player: NowPlayingMonitor.Player, trackID: String)?
    private(set) var clock: PlaybackClock?

    /// Main actor, after every sample that updates `clock`.
    var onClockChange: ((PlaybackClock) -> Void)?

    init(
        scripts: any NowPlayingQuerying,
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.scripts = scripts
        self.now = now
    }

    /// Follows `track` while it plays (`isPlaying`), or stops following when nil.
    func follow(_ track: NowPlayingMonitor.Track?, isPlaying: Bool) {
        let newTarget = track.map { (player: $0.player, trackID: $0.id) }
        if newTarget?.player != target?.player || newTarget?.trackID != target?.trackID {
            generation += 1
            target = newTarget
            clock = nil
        }
        if !isPlaying, var paused = clock {
            paused.pause(at: now())
            clock = paused
            onClockChange?(paused)
        }
        updateTimer(polling: target != nil && isPlaying)
        if target != nil { sampleNow() }
    }

    func sampleNow() {
        guard let target else { return }
        guard !inFlight else {
            sampleAgain = true
            return
        }
        inFlight = true
        let generation = self.generation
        let scripts = self.scripts
        let started = now()
        Task { [weak self] in
            let result = await scripts.position(of: target.player)
            self?.finish(result, generation: generation, started: started)
        }
    }

    private func finish(_ result: NowPlayingMonitor.PositionResult, generation: Int, started: TimeInterval) {
        inFlight = false
        defer {
            if sampleAgain {
                sampleAgain = false
                sampleNow()
            }
        }
        guard generation == self.generation, let target else { return }
        guard case .sample(let sample) = result else {
            logger.debug("Position query: \(result == .idle ? "idle" : "unavailable", privacy: .public)")
            return
        }
        // A sample for a different track means the player moved on before its notification
        // arrived; the monitor will report the new track, and following it resets the clock.
        if !target.trackID.isEmpty, !sample.trackID.isEmpty, sample.trackID != target.trackID {
            logger.debug("Position sample for another track (\(sample.trackID, privacy: .private) ≠ \(target.trackID, privacy: .private)); ignored")
            return
        }
        // The runner times the script itself; without that, the midpoint of the whole round trip.
        let measured = sample.measuredAt > 0 ? sample.measuredAt : (started + now()) / 2
        if var running = clock {
            // How far the clock had wandered from the player: the sync error between samples.
            let drift = sample.position - running.position(at: measured)
            logger.debug("Position sample: drift \(String(format: "%+.3f", drift), privacy: .public) s, \(sample.state == .playing ? "playing" : "paused", privacy: .public)")
            running.apply(sample, at: measured)
            clock = running
        } else {
            clock = PlaybackClock(sample: sample, at: measured)
            logger.debug("Clock started at \(String(format: "%.1f", sample.position), privacy: .public) s")
        }
        if let clock { onClockChange?(clock) }
    }

    private func updateTimer(polling: Bool) {
        if polling, timer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: PositionTrackerConfig.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sampleNow() }
            }
            timer.tolerance = PositionTrackerConfig.tolerance
            self.timer = timer
        } else if !polling, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    func stop() {
        updateTimer(polling: false)
        generation += 1
        target = nil
        clock = nil
    }
}
