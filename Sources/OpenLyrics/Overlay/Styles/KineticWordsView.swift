import SwiftUI

/// Draws the words a word style placed: each at its position, size, tilt and color, the sung word
/// in its highlight box, icons beside the words that have one. The whole arrangement drifts slowly
/// in 3D and swells with the beat when music reactions are on.
struct KineticWordsView: View {
    var words: [PlacedWord]
    var colors: LyricColors
    var baseSize: CGFloat
    /// Song time, for the slow drift.
    var time: TimeInterval
    /// 0...1: how hard the current beat hits (0 without music reactions).
    var beat: Double
    var drift: Bool

    var body: some View {
        ZStack {
            ForEach(words) { word in
                WordChip(word: word, colors: colors, baseSize: baseSize, beat: beat)
                    .offset(x: word.x * baseSize, y: word.y * baseSize)
            }
        }
        .rotation3DEffect(.degrees(drift ? 7 * sin(time * 0.5) : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
        .rotation3DEffect(.degrees(drift ? 4 * sin(time * 0.37 + 1.3) : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.45)
        .scaleEffect(1 + 0.045 * beat)
    }
}

/// One word, with its box and icon.
///
/// The word is laid out once at a fixed size (`renderScale` × the base size, the largest it gets)
/// and only scaled down on the GPU as it moves through the styles. Laying text out at a new size
/// every frame would re-shape it and churn variable-font instances 60 times a second.
struct WordChip: View {
    var word: PlacedWord
    var colors: LyricColors
    var baseSize: CGFloat
    var beat: Double

    /// The largest scale a style gives a word; anything bigger is drawn scaled up.
    static let renderScale: CGFloat = 1.35

    private var size: CGFloat { max(1, baseSize * Self.renderScale) }

    var body: some View {
        HStack(spacing: size * 0.2) {
            if let icon = word.icon, word.iconLeading { iconView(icon) }
            boxedText
            if let icon = word.icon, !word.iconLeading { iconView(icon) }
        }
        .fixedSize()
        .scaleEffect(max(0.001, word.scale / Self.renderScale))
        .rotation3DEffect(.degrees(word.tiltY), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
        .rotation3DEffect(.degrees(word.tiltX), axis: (x: 1, y: 0, z: 0), perspective: 0.55)
        .rotationEffect(.degrees(word.tiltZ))
        .opacity(word.opacity)
    }

    private var textColor: PaletteColor {
        colors.lyric.mixed(with: colors.boxedText, word.boxed).mixed(with: colors.secondary, word.faded)
    }

    private var boxedText: some View {
        // Drawn white once and tinted on the GPU: changing the text's own color every frame of a
        // transition would re-rasterize its glyphs each time.
        Text(word.text)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(.white)
            .colorMultiply(textColor.color)
            .padding(.horizontal, size * 0.12)
            // The box hugs the letters rather than the full line height.
            .padding(.vertical, -size * 0.06)
            .background {
                if word.boxed > 0.01 {
                    ZStack {
                        // Unsung part: the highlight, a little darker.
                        Rectangle().fill(colors.highlight.mixed(with: PaletteColor(red: 0.1, green: 0.02, blue: 0.04), 0.14).color)
                        // Sung part: the full highlight, sweeping left to right.
                        Rectangle().fill(colors.highlight.color).mask(fillMask)
                    }
                    .brightness(0.12 * beat)
                    .opacity(word.boxed)
                }
            }
    }

    private var fillMask: some View {
        let softness = 0.06
        let edge = -softness + word.fill * (1 + 2 * softness)
        return LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: Motion.clamp(edge - softness)),
                .init(color: .clear, location: Motion.clamp(edge + softness)),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    private func iconView(_ icon: WordIcon) -> some View {
        WordIconView(icon: icon, size: size * 0.8, age: word.age, color: colors.highlight.color, beat: beat)
    }
}

/// A word's SF Symbol: pops in as the word is sung, then keeps its own motion.
struct WordIconView: View {
    var icon: WordIcon
    var size: CGFloat
    var age: TimeInterval
    var color: Color
    var beat: Double

    var body: some View {
        let pop = Motion.backOut(age, duration: 0.38, overshoot: 2.6)
        let motion = IconMotionState(icon.motion, age: max(0, age))
        glyph
            .scaleEffect(max(0.001, pop * motion.scale * (1 + 0.18 * beat)))
            .rotationEffect(.degrees(motion.rotation))
            .offset(y: motion.lift * size)
            .opacity(Motion.clamp(age / 0.08))
    }
}

extension WordIconView {
    /// An SF Symbol in the highlight color, or an emoji in its own colors.
    @ViewBuilder
    fileprivate var glyph: some View {
        if icon.isEmoji {
            Text(icon.symbol).font(.system(size: size * 0.92))
        } else {
            Image(systemName: icon.symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(color)
        }
    }
}

/// The transform an icon's motion gives it `age` seconds after it appeared.
struct IconMotionState {
    var scale = 1.0
    var rotation = 0.0
    /// Vertical offset in multiples of the icon size (negative is up).
    var lift = 0.0

    init(_ motion: IconMotion, age: TimeInterval) {
        let tau = 2 * Double.pi
        switch motion {
        case .bounce:
            lift = -0.14 * abs(sin(age * tau * 1.1))
        case .pulse:
            let beat = pow(sin(age * tau * 1.4), 2)
            scale = 1 + 0.14 * beat
        case .wiggle:
            rotation = 12 * sin(age * tau * 1.8) * exp(-age * 0.4)
        case .breathe:
            scale = 1 + 0.08 * sin(age * tau * 0.55)
        case .spin:
            rotation = age * 120
        case .float:
            lift = -0.18 * (1 - exp(-age * 1.2)) - 0.05 * sin(age * tau * 0.8)
        }
    }
}
