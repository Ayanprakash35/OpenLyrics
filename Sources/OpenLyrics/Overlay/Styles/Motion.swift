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

/// The three colors the word styles use: the lyric text, the highlight box behind the word being
/// sung, and the dimmer secondary text for words on their way out.
struct LyricColors: Equatable, Sendable {
    var lyric: PaletteColor
    var highlight: PaletteColor
    var secondary: PaletteColor
    /// Text inside the highlight box.
    var boxedText = PaletteColor(red: 1, green: 0.97, blue: 0.97)

    /// Used before any artwork has been seen and for colorless covers: a warm coral and pink.
    static let standard = LyricColors(
        lyric: PaletteColor(red: 0.96, green: 0.36, blue: 0.36),
        highlight: PaletteColor(red: 0.89, green: 0.27, blue: 0.43),
        secondary: PaletteColor(red: 0.52, green: 0.22, blue: 0.27)
    )

    /// Colors from the album: the artwork's leading color as the highlight, a lighter tint of it
    /// for the lyrics and a darker one for secondary text. Covers too gray to tint anything get
    /// `standard`.
    static func fromArtwork(_ palette: ArtworkPalette) -> LyricColors {
        let lead = ColorExtractor.HSB(palette.primary)
        guard lead.saturation >= 0.18 else { return standard }
        var highlight = lead
        highlight.saturation = max(lead.saturation, 0.62)
        highlight.brightness = 0.88
        var lyric = lead
        lyric.saturation = max(lead.saturation * 0.72, 0.35)
        lyric.brightness = 0.98
        var secondary = lead
        secondary.saturation = max(lead.saturation * 0.6, 0.3)
        secondary.brightness = 0.55
        return LyricColors(lyric: lyric.rgb, highlight: highlight.rgb, secondary: secondary.rgb)
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
