import SwiftUI

/// Where an overlay draws.
enum OverlaySurface: Sendable {
    case desktop, lockScreen
}

/// How the lyrics look, resolved from the settings and the surface.
struct LyricsStyle: Equatable {
    var fontSize: CGFloat
    var highlight: Color
    var glow: Color
    var showNextLine: Bool
    var backdrop: Bool
    var surface: OverlaySurface

    var font: Font { .system(size: fontSize, weight: .bold, design: .rounded) }
    var nextFont: Font { .system(size: fontSize * 0.55, weight: .semibold, design: .rounded) }
    var wordSpacing: CGFloat { fontSize * 0.26 }
    var unsung: Color { .white.opacity(0.38) }
    /// Widest the current line may run before wrapping.
    var maxLineWidth: CGFloat { fontSize * 22 }
}

/// The overlay's root view: picks the line for the current playback position every frame.
struct LyricsOverlayView: View {
    @ObservedObject var session: LyricsSession
    @ObservedObject var settings: Settings
    let surface: OverlaySurface
    /// The screen's menu bar and Dock, so the desktop overlay sits clear of them.
    var screenInsets = EdgeInsets()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !session.isPlaying || !session.hasSyncedLyrics)) { _ in
            LyricsStage(
                lyrics: session.lyrics,
                time: session.position(at: ProcessInfo.processInfo.systemUptime, offset: settings.syncOffset),
                style: style,
                caption: surface == .lockScreen ? caption : nil
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .padding(padding)
    }

    private var style: LyricsStyle {
        let palette = settings.colorMode == .artwork ? session.palette : .fallback
        let scale: CGFloat = surface == .lockScreen ? 1.3 : 1
        return LyricsStyle(
            fontSize: settings.textSize.pointSize * scale,
            highlight: palette.primary.color,
            glow: palette.secondary.color,
            showNextLine: settings.showNextLine,
            backdrop: false,
            surface: surface
        )
    }

    private var caption: String? {
        guard let track = session.track, !track.title.isEmpty else { return nil }
        return track.artist.isEmpty ? track.title : "\(track.title) — \(track.artist)"
    }

    private var alignment: Alignment {
        guard surface == .desktop else { return .center }
        switch settings.position {
        case .top: return .top
        case .center: return .center
        case .bottom: return .bottom
        }
    }

    private var padding: EdgeInsets {
        switch surface {
        case .desktop:
            EdgeInsets(top: screenInsets.top + 28, leading: 40, bottom: screenInsets.bottom + 48, trailing: 40)
        case .lockScreen:
            // A little below center: clear of the clock above and the login field below.
            EdgeInsets(top: 160, leading: 60, bottom: 40, trailing: 60)
        }
    }
}

/// The current line (karaoke-filled) and, beneath it, the next.
struct LyricsStage: View {
    var lyrics: Lyrics?
    var time: TimeInterval?
    var style: LyricsStyle
    var caption: String?

    var body: some View {
        let index = time.flatMap { lyrics?.lineIndex(at: $0) }
        let current = index.flatMap { lyrics?.lines[$0] }
        let next = nextLine(after: index)

        VStack(spacing: style.fontSize * 0.45) {
            if let caption {
                Text(caption)
                    .font(.system(size: style.fontSize * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
            }
            ZStack {
                if let current, let time {
                    LineView(line: current, time: time, style: style)
                        .id(index)
                        .transition(.asymmetric(
                            insertion: .offset(y: style.fontSize * 0.9).combined(with: .opacity),
                            removal: .offset(y: -style.fontSize * 0.9).combined(with: .opacity)
                        ))
                }
            }
            if style.showNextLine, let next {
                WordFlowLayout(spacing: style.wordSpacing * 0.55, lineSpacing: style.fontSize * 0.08, maxWidth: style.maxLineWidth * 0.9) {
                    ForEach(Array(next.words.enumerated()), id: \.offset) { index, word in
                        Text(word.text)
                            .font(style.nextFont)
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize()
                            .layoutValue(key: SpaceAfterKey.self, value: word.spaceAfter)
                            .layoutValue(key: BreakBeforeKey.self, value: LineView.canBreak(before: index, in: next))
                    }
                }
                .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                .id(next.start)
                .transition(.opacity.combined(with: .offset(y: style.fontSize * 0.4)))
            }
        }
        .padding(.horizontal, style.backdrop ? style.fontSize * 0.75 : 0)
        .padding(.vertical, style.backdrop ? style.fontSize * 0.45 : 0)
        .background {
            if style.backdrop, current != nil || next != nil {
                RoundedRectangle(cornerRadius: style.fontSize * 0.7, style: .continuous)
                    .fill(.black.opacity(0.32))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: style.fontSize * 0.7, style: .continuous))
                    .environment(\.colorScheme, .dark)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: index)
        .animation(.easeInOut(duration: 0.4), value: style.highlight)
    }

    /// The next line with words after `index` (or the first one, before the lyrics start).
    private func nextLine(after index: Int?) -> LyricLine? {
        guard let lines = lyrics?.lines else { return nil }
        let start = index.map { $0 + 1 } ?? 0
        guard start < lines.count else { return nil }
        return lines[start...].first { !$0.isGap }
    }
}

/// A line of words, each filling as it's sung; or, for a gap, three dots counting down to the next
/// line.
struct LineView: View {
    var line: LyricLine
    var time: TimeInterval
    var style: LyricsStyle

    var body: some View {
        if line.isGap {
            GapDots(progress: line.end > line.start ? (time - line.start) / (line.end - line.start) : 1, style: style)
        } else {
            WordFlowLayout(spacing: style.wordSpacing, lineSpacing: style.fontSize * 0.12, maxWidth: style.maxLineWidth) {
                ForEach(Array(line.words.enumerated()), id: \.offset) { index, word in
                    KaraokeWord(text: word.text, progress: word.progress(at: time), style: style)
                        .layoutValue(key: SpaceAfterKey.self, value: word.spaceAfter)
                        .layoutValue(key: BreakBeforeKey.self, value: Self.canBreak(before: index, in: line))
                }
            }
        }
    }

    static func canBreak(before index: Int, in line: LyricLine) -> Bool {
        guard index > 0 else { return true }
        let previous = line.words[index - 1]
        if previous.spaceAfter { return true }
        let word = line.words[index]
        return word.text.first.map(WordTiming.isSpaceless) == true || previous.text.last.map(WordTiming.isSpaceless) == true
    }
}

/// One word: dim until sung, then filled left to right in the highlight color with a soft edge,
/// lifting slightly and glowing while it's being sung.
struct KaraokeWord: View {
    var text: String
    var progress: Double
    var style: LyricsStyle

    var body: some View {
        let active = progress > 0 && progress < 1
        let lift = style.fontSize * 0.05 * easeOut(progress)
        Text(text)
            .font(style.font)
            .foregroundStyle(style.unsung)
            .overlay {
                Text(text)
                    .font(style.font)
                    .foregroundStyle(style.highlight)
                    .mask { fillMask }
            }
            .shadow(color: .black.opacity(0.45), radius: style.fontSize * 0.12, y: 1)
            .shadow(color: style.glow.opacity(active ? 0.75 : 0), radius: style.fontSize * 0.3)
            .offset(y: -lift)
            .fixedSize()
    }

    /// Opaque up to the fill edge, clear after it, with a soft transition. At 0 nothing shows; at 1
    /// everything does.
    private var fillMask: some View {
        let softness = 0.12
        let edge = -softness + progress * (1 + 2 * softness)
        return LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: min(max(edge - softness, 0), 1)),
                .init(color: .clear, location: min(max(edge + softness, 0), 1)),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func easeOut(_ t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        return 1 - (1 - clamped) * (1 - clamped)
    }
}

/// An instrumental break: three dots that light one by one as the next line approaches, breathing
/// gently.
struct GapDots: View {
    var progress: Double
    var style: LyricsStyle

    var body: some View {
        let clamped = min(max(progress, 0), 1)
        let breath = 1 + 0.08 * sin(clamped * .pi * 12)
        HStack(spacing: style.fontSize * 0.32) {
            ForEach(0..<3, id: \.self) { dot in
                let lit = min(max(clamped * 3 - Double(dot), 0), 1)
                Circle()
                    .fill(style.unsung)
                    .overlay(Circle().fill(style.highlight).opacity(lit))
                    .frame(width: style.fontSize * 0.28, height: style.fontSize * 0.28)
                    .scaleEffect(breath)
            }
        }
        .frame(height: style.fontSize * 1.2)
        .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
    }
}
