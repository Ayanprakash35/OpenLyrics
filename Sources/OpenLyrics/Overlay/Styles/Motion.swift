import Foundation

/// Small, pure motion helpers shared by the word styles. Everything is a function of time, so a
/// frame can be drawn (or tested) for any moment without animation state.
enum Motion {
    /// 0 before `t` = 0, 1 after `duration`, with a springy overshoot in between (ease-out-back).
    /// `overshoot` 0 is a plain ease-out; 1.7 is the classic back-out.
    static func backOut(_ t: TimeInterval, duration: TimeInterval, overshoot: Double = 1.7) -> Double {
        guard t > 0 else { return 0 }
        guard t < duration, duration > 0 else { return 1 }
        let x = t / duration - 1
        let c3 = overshoot + 1
        return 1 + c3 * x * x * x + overshoot * x * x
    }

    /// Smooth 0→1 over `duration` without overshoot (ease-in-out cubic).
    static func smooth(_ t: TimeInterval, duration: TimeInterval) -> Double {
        guard t > 0 else { return 0 }
        guard t < duration, duration > 0 else { return 1 }
        let x = t / duration
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    /// Linear interpolation through `points` (x ascending), held flat beyond the ends.
    static func curve(_ x: Double, _ points: [(Double, Double)]) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if x <= first.0 { return first.1 }
        if x >= last.0 { return last.1 }
        for (a, b) in zip(points, points.dropFirst()) where x <= b.0 {
            let f = (x - a.0) / (b.0 - a.0)
            return a.1 + (b.1 - a.1) * f
        }
        return last.1
    }

    static func clamp(_ x: Double, _ low: Double = 0, _ high: Double = 1) -> Double {
        min(max(x, low), high)
    }

    /// A stable pseudo-random value in -1...1 for `seed` (SplitMix64), so each word keeps the same
    /// tilt and offset every frame and every time the song plays.
    static func jitter(_ seed: UInt64) -> Double {
        var z = seed &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z % 2_000_001) / 1_000_000 - 1
    }

    /// A seed for word `index` of the line starting at `lineStart`, and a `salt` per property.
    static func seed(lineStart: TimeInterval, index: Int, salt: UInt64) -> UInt64 {
        UInt64(bitPattern: Int64((lineStart * 1000).rounded())) &* 1_000_003 &+ UInt64(index) &* 7919 &+ salt
    }

    /// How far the word sequence has advanced at `time`: each word's start adds one step, eased
    /// with `ease`. Words more than `duration` past their start count as whole steps, so only the
    /// last few are evaluated.
    static func advance(starts: [TimeInterval], at time: TimeInterval, duration: TimeInterval,
                        ease: (TimeInterval, TimeInterval) -> Double) -> Double {
        // The last word that has started.
        var low = 0, high = starts.count - 1, started = -1
        while low <= high {
            let middle = (low + high) / 2
            if starts[middle] <= time { started = middle; low = middle + 1 } else { high = middle - 1 }
        }
        guard started >= 1 else { return 0 }
        var total = 0.0
        var index = started
        // Walk back through the words still easing in; everything before them is complete.
        while index >= 1, time - starts[index] < duration {
            total += ease(time - starts[index], duration)
            index -= 1
        }
        return total + Double(index)
    }
}

/// The three colors the word styles use — the lyric text, the highlight box behind the word being
/// sung, and the dimmer secondary text for words on their way out — each a two-color gradient.
struct LyricColors: Equatable, Sendable {
    var lyric: PaletteColor
    var lyricEnd: PaletteColor
    var highlight: PaletteColor
    var highlightEnd: PaletteColor
    var secondary: PaletteColor
    var secondaryEnd: PaletteColor
    /// Text inside the highlight box.
    var boxedText = PaletteColor(red: 1, green: 0.97, blue: 0.97)

    init(lyric: PaletteColor, lyricEnd: PaletteColor, highlight: PaletteColor, highlightEnd: PaletteColor,
         secondary: PaletteColor, secondaryEnd: PaletteColor) {
        self.lyric = lyric
        self.lyricEnd = lyricEnd
        self.highlight = highlight
        self.highlightEnd = highlightEnd
        self.secondary = secondary
        self.secondaryEnd = secondaryEnd
    }

    /// One color per role, each spread into a gentle gradient of neighboring shades.
    init(lyric: PaletteColor, highlight: PaletteColor, secondary: PaletteColor) {
        self.init(
            lyric: lyric, lyricEnd: Self.neighbor(of: lyric),
            highlight: highlight, highlightEnd: Self.neighbor(of: highlight),
            secondary: secondary, secondaryEnd: Self.neighbor(of: secondary)
        )
    }

    /// Before any artwork has been seen, and for colorless covers: coral to peach text, a pink to
    /// violet box, deep rose secondary text.
    static let standard = LyricColors(
        lyric: PaletteColor(red: 0.98, green: 0.42, blue: 0.40),
        lyricEnd: PaletteColor(red: 1.0, green: 0.62, blue: 0.45),
        highlight: PaletteColor(red: 0.91, green: 0.25, blue: 0.45),
        highlightEnd: PaletteColor(red: 0.62, green: 0.28, blue: 0.86),
        secondary: PaletteColor(red: 0.55, green: 0.22, blue: 0.30),
        secondaryEnd: PaletteColor(red: 0.42, green: 0.22, blue: 0.52)
    )

    /// Colors from the album's accent colors (`ColorExtractor.Result.accents`, leading first). The
    /// lyrics run from a light tint of the leading color to one of the second; the highlight box
    /// from the second color to the leading one, vivid; secondary text is a deep shade of the third.
    /// A cover with one color gets its neighboring shades. Covers too gray to tint anything get
    /// `standard`.
    static func fromArtwork(accents: [PaletteColor]) -> LyricColors {
        let colors = accents.filter { ColorExtractor.HSB($0).saturation >= 0.18 }
        guard let lead = colors.first else { return standard }
        let second = colors.count > 1 ? colors[1] : hueShifted(lead, by: 0.07)
        let third = colors.count > 2 ? colors[2] : hueShifted(second, by: 0.05)
        return LyricColors(
            lyric: tint(lead), lyricEnd: tint(second),
            highlight: vivid(second), highlightEnd: vivid(lead),
            secondary: shade(third), secondaryEnd: shade(second)
        )
    }

    /// The two artwork colors `ArtworkPalette` keeps, for callers without the full accent list.
    static func fromArtwork(_ palette: ArtworkPalette) -> LyricColors {
        fromArtwork(accents: [palette.primary, palette.secondary])
    }

    private static func tint(_ color: PaletteColor) -> PaletteColor {
        var hsb = ColorExtractor.HSB(color)
        hsb.saturation = max(hsb.saturation * 0.72, 0.32)
        hsb.brightness = 0.98
        return hsb.rgb
    }

    private static func vivid(_ color: PaletteColor) -> PaletteColor {
        var hsb = ColorExtractor.HSB(color)
        hsb.saturation = max(hsb.saturation, 0.62)
        hsb.brightness = 0.86
        return hsb.rgb
    }

    private static func shade(_ color: PaletteColor) -> PaletteColor {
        var hsb = ColorExtractor.HSB(color)
        hsb.saturation = max(hsb.saturation * 0.65, 0.3)
        hsb.brightness = 0.55
        return hsb.rgb
    }

    static func hueShifted(_ color: PaletteColor, by turns: Double) -> PaletteColor {
        var hsb = ColorExtractor.HSB(color)
        hsb.hue += turns
        return hsb.rgb
    }

    /// A shade next to `color`: a little further round the color wheel, a little lighter.
    static func neighbor(of color: PaletteColor) -> PaletteColor {
        var hsb = ColorExtractor.HSB(hueShifted(color, by: 0.05))
        hsb.brightness = min(1, hsb.brightness * 1.08)
        return hsb.rgb
    }
}

/// Beat bounce tuning.
enum BeatConfig {
    /// Seconds a word's kick takes to fade. Sane range: 0.1–0.35.
    static let decay: TimeInterval = 0.2
    /// Seconds of the little hop each kick gives. Sane range: 0.15–0.35.
    static let hopDuration: TimeInterval = 0.24
    /// Kick strength of an ordinary word, a line's first word, and the extra for a held note.
    static let wordKick = 0.55
    static let lineKick = 1.0
    static let heldKick = 0.2
    /// A word at least this long counts as held. Sane range: 0.5–1.2.
    static let heldWord: TimeInterval = 0.7
}

/// How hard the music hits right now, in two shapes the styles animate with.
struct Beat: Equatable, Sendable {
    /// 0...1, jumping up at a hit and fading: scale and brightness.
    var pulse = 0.0
    /// 0...1, a single arc up and back down after a hit: the little bounce.
    var hop = 0.0

    static let none = Beat()

    /// The beat from the lyrics' own timing: every sung word is a hit — a line's first word and
    /// held notes harder — so the words bounce with the singing without listening to any audio.
    /// `lineStarts` marks which of `words` begin a line.
    static func fromLyrics(words: [LyricWord], lineStarts: [Bool], at time: TimeInterval) -> Beat {
        var low = 0, high = words.count - 1, last = -1
        while low <= high {
            let middle = (low + high) / 2
            if words[middle].start <= time { last = middle; low = middle + 1 } else { high = middle - 1 }
        }
        guard last >= 0 else { return .none }
        let word = words[last]
        let age = time - word.start
        guard age < 1 else { return .none }
        var kick = last < lineStarts.count && lineStarts[last] ? BeatConfig.lineKick : BeatConfig.wordKick
        if word.end - word.start >= BeatConfig.heldWord { kick = min(1, kick + BeatConfig.heldKick) }
        let hop = age < BeatConfig.hopDuration ? sin(Double.pi * age / BeatConfig.hopDuration) : 0
        return Beat(pulse: kick * exp(-age / BeatConfig.decay), hop: kick * hop)
    }

    /// The stronger of two beats (lyrics and audio).
    func combined(with other: Beat) -> Beat {
        Beat(pulse: max(pulse, other.pulse), hop: max(hop, other.hop))
    }
}

extension PaletteColor {
    /// Straight sRGB mix: 0 is `self`, 1 is `other`.
    func mixed(with other: PaletteColor, _ fraction: Double) -> PaletteColor {
        let t = Motion.clamp(fraction)
        return PaletteColor(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t
        )
    }

    /// `#RRGGBB`.
    var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    init?(hex: String) {
        let digits = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
