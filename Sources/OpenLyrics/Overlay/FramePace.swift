import SwiftUI

/// Frame pacing tuning.
enum FramePaceConfig {
    /// Frames a second while words move: the stack's spring, the lens rolling, icons popping in.
    static let fast: Double = 60
    /// Frames a second otherwise: the box fill sweeping and the slow drift look the same at 30.
    static let calm: Double = 30
    /// Seconds after a word starts that motion stays fast. Covers the longest transition (the
    /// stack's 0.34 s spring and the icons' 0.38 s pop) with a little to spare.
    static let fastWindow: TimeInterval = 0.45
}

/// When the overlay should draw quickly. The view sets the next fast window each frame from the
/// lyrics' timing; the schedule reads it as it picks each following frame. Shared between the
/// main actor (writer) and SwiftUI's timeline (reader), hence the lock.
final class FramePace: @unchecked Sendable {
    private let lock = NSLock()
    private var fastFrom = Date.distantFuture
    private var fastUntil = Date.distantPast

    func setFastWindow(from: Date, until: Date) {
        lock.withLock {
            fastFrom = from
            fastUntil = until
        }
    }

    func interval(after date: Date) -> TimeInterval {
        lock.withLock {
            // A frame landing just short of the window starts fast pacing in time for it.
            let fast = date >= fastFrom.addingTimeInterval(-1 / FramePaceConfig.calm) && date <= fastUntil
            return 1 / (fast ? FramePaceConfig.fast : FramePaceConfig.calm)
        }
    }

    /// The fast window around `time` (song seconds) for words starting at `starts`: the one in
    /// progress, or else the next one. In song seconds; nil when no word starts ahead.
    static func window(starts: [TimeInterval], at time: TimeInterval) -> (from: TimeInterval, until: TimeInterval)? {
        var low = 0, high = starts.count - 1, last = -1
        while low <= high {
            let middle = (low + high) / 2
            if starts[middle] <= time { last = middle; low = middle + 1 } else { high = middle - 1 }
        }
        if last >= 0, time - starts[last] < FramePaceConfig.fastWindow {
            // Back-to-back words chain into one window.
            var until = starts[last] + FramePaceConfig.fastWindow
            var next = last + 1
            while next < starts.count, starts[next] <= until {
                until = starts[next] + FramePaceConfig.fastWindow
                next += 1
            }
            return (time, until)
        }
        guard last + 1 < starts.count else { return nil }
        let next = starts[last + 1]
        return (next, next + FramePaceConfig.fastWindow)
    }
}

/// A timeline whose frames come at `FramePace`'s current rate.
struct PacedSchedule: TimelineSchedule {
    let pace: FramePace

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        let pace = self.pace
        return AnySequence(sequence(first: startDate) { date in
            date.addingTimeInterval(mode == .lowFrequency ? 1 : pace.interval(after: date))
        })
    }
}
