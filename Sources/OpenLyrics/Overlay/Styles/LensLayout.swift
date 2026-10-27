import Foundation

/// Lens tuning. Lengths are in multiples of the base font size.
enum LensConfig {
    /// Seconds the column takes to roll to the next word. Sane range: 0.2–0.5.
    static let rollDuration: TimeInterval = 0.3
    /// Distance between word centers at the middle of the lens. Sane range: 0.8–1.4.
    static let spacing = 1.08
    /// How sharply the column curves away, in radians per word: larger shows fewer words, more
    /// strongly bent. Sane range: 0.25–0.6.
    static let curvature = 0.5
    /// Size at the edge of the lens, relative to the middle. Sane range: 0.2–0.5.
    static let edgeScale = 0.22
    /// Words further than this from the middle aren't drawn.
    static let visibleWords = 3.6
    /// How much words lean back as they roll over the top and bottom, in degrees per radian.
    static let leanDegrees = 38.0
}

/// The "Lens" style: the whole song's words in one column, as if printed on a drum under a convex
/// lens. The word being sung rolls to the middle, closest to the glass: biggest, brightest and in
/// the highlight box. Neighbors shrink, lean away and dim with distance — sung words above in the
/// lyric color fading to secondary, upcoming ones below already faint.
enum LensLayout {
    struct Entry {
        var line: Int
        var index: Int
        var word: LyricWord
        var lineStart: TimeInterval
    }

    /// Every sung word of the song, in order.
    static func entries(in lyrics: Lyrics) -> [Entry] {
        lyrics.lines.enumerated().flatMap { lineNumber, line in
            line.words.enumerated().map { Entry(line: lineNumber, index: $0.offset, word: $0.element, lineStart: line.start) }
        }
    }

    /// `starts` is `entries.map(\.word.start)`, passed in so it isn't rebuilt every frame.
    static func words(in entries: [Entry], starts: [TimeInterval], at time: TimeInterval, icons: Bool) -> [PlacedWord] {
        guard !entries.isEmpty, entries.count == starts.count, time >= starts[0] - LensConfig.rollDuration else { return [] }
        let focus = Motion.advance(starts: starts, at: time, duration: LensConfig.rollDuration) { t, d in
            Motion.smooth(t, duration: d)
        }
        let radius = LensConfig.spacing / LensConfig.curvature
        let first = max(0, Int(focus - LensConfig.visibleWords))
        let last = min(entries.count - 1, Int(focus + LensConfig.visibleWords) + 1)
        guard first <= last else { return [] }

        return (first...last).compactMap { position in
            let entry = entries[position]
            let distance = Double(position) - focus
            guard abs(distance) <= LensConfig.visibleWords else { return nil }
            let angle = max(-Double.pi / 2, min(Double.pi / 2, distance * LensConfig.curvature))
            let depth = cos(angle)
            let seed = { (salt: UInt64) in Motion.jitter(Motion.seed(lineStart: entry.lineStart, index: entry.index, salt: salt)) }
            let sung = entry.word.start <= time
            let nearness = Motion.clamp(1 - abs(distance) * 1.4)
            return PlacedWord(
                id: "\(entry.lineStart)-\(entry.index)",
                text: entry.word.text,
                x: 0.18 * seed(2) * depth,
                y: radius * sin(angle),
                // Closest to the glass, the sung word swells beyond its neighbors.
                scale: (LensConfig.edgeScale + (1 - LensConfig.edgeScale) * pow(depth, 2.4)) * (1 + 0.3 * nearness),
                opacity: Motion.clamp(pow(depth, 0.9) * (sung || distance < 0.5 ? 1 : 0.55)),
                boxed: sung ? nearness : 0,
                faded: distance < 0 ? Motion.clamp(-distance / 2) : (distance > 0.5 ? 1 : 0),
                fill: entry.word.progress(at: time),
                tiltX: -angle * LensConfig.leanDegrees,
                tiltY: 6 * seed(4),
                tiltZ: 0,
                icon: icons ? WordIcons.icon(for: entry.word.text) : nil,
                iconLeading: seed(6) < 0,
                age: time - entry.word.start
            )
        }
    }
}
