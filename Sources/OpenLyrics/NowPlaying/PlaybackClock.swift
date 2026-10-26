import Foundation

/// Clock tuning.
enum PlaybackClockConfig {
    /// Disagreement, in seconds, between a fresh sample and the running clock below which the clock
    /// is only nudged toward the sample instead of jumping to it. AppleScript round trips jitter by
    /// tens of milliseconds; jumping on each would make the word fill stutter. Anything larger is a
    /// seek and snaps. Sane range: 0.15–0.5.
    static let smoothingWindow: TimeInterval = 0.3
    /// Fraction of a small disagreement corrected per sample. Sane range: 0.2–0.6.
    static let smoothingGain = 0.4
}

/// The playback position between samples: the last sample carried forward in real time while the
/// track plays. Times are monotonic seconds (`ProcessInfo.systemUptime`), which never jump when the
/// wall clock is changed.
struct PlaybackClock: Equatable, Sendable {
    let trackID: String
    private(set) var anchorPosition: TimeInterval
    private(set) var anchorTime: TimeInterval
    private(set) var isPlaying: Bool
    private(set) var duration: TimeInterval?

    init(sample: NowPlayingMonitor.PositionSample, at time: TimeInterval) {
        trackID = sample.trackID
        anchorPosition = sample.position
        anchorTime = time
        isPlaying = sample.state == .playing
        duration = sample.duration
    }

    func position(at time: TimeInterval) -> TimeInterval {
        let elapsed = isPlaying ? max(0, time - anchorTime) : 0
        let position = anchorPosition + elapsed
        return duration.map { min(position, $0) } ?? position
    }

    /// Folds in a sample taken at `time` for the same track. Small disagreements while playing are
    /// smoothed; a seek, a pause or a resume takes effect at once.
    mutating func apply(_ sample: NowPlayingMonitor.PositionSample, at time: TimeInterval) {
        let playing = sample.state == .playing
        let predicted = position(at: time)
        let drift = sample.position - predicted
        if playing, isPlaying, abs(drift) < PlaybackClockConfig.smoothingWindow {
            anchorPosition = predicted + drift * PlaybackClockConfig.smoothingGain
        } else {
            anchorPosition = sample.position
        }
        anchorTime = time
        isPlaying = playing
        if let length = sample.duration { duration = length }
    }

    /// Stops the clock where it is, without a sample (the player said it paused).
    mutating func pause(at time: TimeInterval) {
        guard isPlaying else { return }
        anchorPosition = position(at: time)
        anchorTime = time
        isPlaying = false
    }
}
