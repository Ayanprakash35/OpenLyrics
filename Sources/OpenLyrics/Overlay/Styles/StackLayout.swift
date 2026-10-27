import Foundation

/// One word as a word style draws it at a given moment. Lengths are in multiples of the style's
/// base font size; angles in degrees.
struct PlacedWord: Equatable, Identifiable {
    /// Stable across frames: the line's start time and the word's index in it.
    var id: String
    var text: String
    var x: Double
    var y: Double
    /// Font size, as a multiple of the base size.
    var scale: Double
    var opacity: Double
    /// 1 = inside the highlight box (boxed text color), 0 = plain lyric color.
    var boxed: Double
    /// 1 = faded to the secondary color (applied after `boxed`).
    var faded: Double
    /// How much of the box is lit, left to right, as the word is sung.
    var fill: Double
    var tiltX: Double
    var tiltY: Double
    var tiltZ: Double
    var icon: WordIcon?
    /// The icon sits before the word (left) rather than after it.
    var iconLeading: Bool
    /// Seconds since the word started being sung (negative before), for the icon's pop and motion.
    var age: TimeInterval
    /// Which per-word color the word takes; neighboring words differ.
    var colorSlot = 0
}

/// Stack tuning. Lengths are in multiples of the base font size.
enum StackConfig {
    /// Seconds the stack takes to move up one word. Sane range: 0.2–0.5.
    static let shiftDuration: TimeInterval = 0.34
    /// Springiness of that move (0 = none). Sane range: 0–2.5.
    static let overshoot = 1.4
    /// Seconds a finished line takes to fly up and away when the next one starts.
    static let exitDuration: TimeInterval = 0.28
    /// Size by slot: entering (u = 1), being sung (0), just sung (−1), before that (−2), leaving (−3).
    static let scaleBySlot: [(Double, Double)] = [(-3.2, 0.36), (-2, 0.52), (-1, 1), (0, 0.62), (1, 0.4)]
    /// The first word of a line has nothing above it, so it's shown big from the start.
    static let leadScaleBySlot: [(Double, Double)] = [(-3.2, 0.36), (-2, 0.52), (-1, 1), (0, 1), (1, 0.6)]
    static let opacityBySlot: [(Double, Double)] = [(-3.2, 0), (-2.6, 0.45), (-2, 0.9), (-1, 1), (0, 1), (0.85, 0)]
    /// The highlight box fades as the word moves up from the bottom slot.
    static let boxBySlot: [(Double, Double)] = [(-0.8, 0), (-0.15, 1), (1, 1)]
    /// Words dim to the secondary color as they rise above the big word.
    static let fadeBySlot: [(Double, Double)] = [(-2.1, 1), (-1.1, 0)]
    /// Vertical spacing, as a fraction of each word's size. Under 1 lets descenders tuck in.
    static let lineHeight = 0.9
    /// Largest sideways offset of a word, in font sizes. Sane range: 0–0.8.
    static let maxShiftX = 0.45
    static let maxTiltY = 18.0
    static let maxTiltX = 8.0
    static let maxTiltZ = 3.5
    /// ± variation in each word's size, so the wall doesn't look mechanical. Sane range: 0–0.15.
    static let sizeVariation = 0.08
}

/// The "Stack" style: words pile into a wall, one row per word. The word being sung appears at the
/// bottom in the highlight box; when the next word starts the wall springs up a row, the sung word
/// grows into the big middle slot and loses its box, and older words shrink, dim and drift away
/// overhead. A new line clears the wall and its first word arrives big.
enum StackLayout {
    static func words(in lyrics: Lyrics, at time: TimeInterval, icons: Bool) -> [PlacedWord] {
        guard let index = lyrics.lineIndex(at: time) else { return [] }
        let line = lyrics.lines[index]
        var placed = line.isGap ? [] : words(of: line, at: time, icons: icons)

        // The previous line flies off as the new one comes in.
        if index > 0, time - line.start < StackConfig.exitDuration {
            let previous = lyrics.lines[index - 1]
            if !previous.isGap {
                let exit = Motion.smooth(time - line.start, duration: StackConfig.exitDuration)
                let frozen = words(of: previous, at: line.start, icons: icons)
                placed = frozen.map { word in
                    var word = word
                    word.y -= exit * 2.4
                    word.opacity *= (1 - exit) * (1 - exit)
                    word.scale *= 1 - 0.3 * exit
                    return word
                } + placed
            }
        }
        return placed
    }

    static func words(of line: LyricLine, at time: TimeInterval, icons: Bool) -> [PlacedWord] {
        let starts = line.words.map(\.start)
        let advance = Motion.advance(starts: starts, at: time, duration: StackConfig.shiftDuration) { t, d in
            Motion.backOut(t, duration: d, overshoot: StackConfig.overshoot)
        }

        struct Row {
            var word: PlacedWord
            var height: Double
        }
        var rows: [Row] = []
        for (index, word) in line.words.enumerated() {
            // Slot: 0 is being sung (bottom), −1 just sung (middle, big), −2 above it, and so on.
            let slot = Double(index) - advance
            // Shown once it starts being sung, until it has drifted off the top.
            guard word.start <= time, slot > -3.2 else { continue }
            let seed = { (salt: UInt64) in Motion.jitter(Motion.seed(lineStart: line.start, index: index, salt: salt)) }
            let curve = index == 0 ? StackConfig.leadScaleBySlot : StackConfig.scaleBySlot
            var scale = Motion.curve(slot, curve) * (1 + StackConfig.sizeVariation * seed(1))
            var opacity = Motion.curve(slot, StackConfig.opacityBySlot)
            if index == 0 {
                // Nothing pushes the first word in, so it pops in on its own.
                let age = time - word.start
                scale *= 0.62 + 0.38 * Motion.backOut(age, duration: StackConfig.shiftDuration, overshoot: 2.2)
                opacity *= Motion.clamp(age / 0.12)
            }
            let icon = icons ? WordIcons.icon(for: word.text) : nil
            let placed = PlacedWord(
                id: "\(line.start)-\(index)",
                text: word.text,
                x: StackConfig.maxShiftX * seed(2),
                y: 0,
                scale: scale,
                opacity: opacity,
                boxed: Motion.curve(slot, StackConfig.boxBySlot),
                faded: Motion.curve(slot, StackConfig.fadeBySlot),
                fill: word.progress(at: time),
                tiltX: StackConfig.maxTiltX * seed(3),
                tiltY: StackConfig.maxTiltY * seed(4),
                tiltZ: StackConfig.maxTiltZ * seed(5),
                icon: icon,
                iconLeading: seed(6) < 0,
                age: time - word.start,
                // Consecutive words step through the colors; each line starts somewhere new.
                colorSlot: index + Int(line.start.rounded())
            )
            // Entering and leaving words take up only part of a row, so the wall moves smoothly.
            let presence = slot > 0 ? 1 - slot : Motion.clamp((slot + 3.2) / 1.2)
            rows.append(Row(word: placed, height: scale * StackConfig.lineHeight * presence))
        }

        // Stack top (oldest) to bottom (newest), centered on the middle of the wall.
        let total = rows.reduce(0) { $0 + $1.height }
        var y = -total / 2
        return rows.map { row in
            var word = row.word
            word.y = y + row.height / 2
            y += row.height
            return word
        }
    }
}
