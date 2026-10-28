import SwiftUI

/// Draws a constellation frame: the lines and star points in one `Canvas`, the labels as word
/// chips over them (so they take the lyric colors like any word), the whole thing drifting
/// slowly together.
struct ConstellationView: View {
    var frame: ConstellationLayout.Frame
    var colors: LyricColors
    var baseSize: CGFloat
    var time: TimeInterval
    var beat: Beat

    var body: some View {
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                func point(_ x: Double, _ y: Double) -> CGPoint {
                    CGPoint(x: center.x + x * baseSize, y: center.y + y * baseSize)
                }
                for edge in frame.edges where edge.progress > 0 {
                    let from = point(edge.fromX, edge.fromY), to = point(edge.toX, edge.toY)
                    let end = CGPoint(x: from.x + (to.x - from.x) * edge.progress, y: from.y + (to.y - from.y) * edge.progress)
                    var path = Path()
                    path.move(to: from)
                    path.addLine(to: end)
                    let own = colors.resolved(slot: edge.colorSlot)
                    context.stroke(path, with: .linearGradient(Gradient(colors: [own.lyric.color.opacity(edge.opacity * 0.6), own.highlight.color.opacity(edge.opacity)]),
                                                               startPoint: from, endPoint: end),
                                   style: StrokeStyle(lineWidth: baseSize * 0.03, lineCap: .round))
                }
                var sparkle = context.resolve(Image(systemName: "sparkle"))
                for star in frame.stars {
                    let at = point(star.x, star.y)
                    let own = colors.resolved(slot: star.colorSlot)
                    let side = star.size * baseSize * 2.4
                    if star.ring > 0 {
                        // The sung word's star: a glow, a ring that breathes with the beat, a bright core.
                        let glow = side * 2.2 * (1 + 0.15 * beat.pulse)
                        context.fill(Path(ellipseIn: CGRect(x: at.x - glow, y: at.y - glow, width: glow * 2, height: glow * 2)),
                                     with: .radialGradient(Gradient(colors: [own.highlight.color.opacity(0.55 * star.ring), .clear]),
                                                           center: at, startRadius: 0, endRadius: glow))
                        let ring = side * (0.95 + 0.12 * beat.pulse)
                        context.stroke(Path(ellipseIn: CGRect(x: at.x - ring, y: at.y - ring, width: ring * 2, height: ring * 2)),
                                       with: .color(own.highlight.color.opacity(0.85 * star.ring)), lineWidth: baseSize * 0.025)
                    }
                    sparkle.shading = .color(star.ring > 0 ? .white : own.lyric.color)
                    var item = context
                    item.opacity = star.opacity
                    item.draw(sparkle, in: CGRect(x: at.x - side / 2, y: at.y - side / 2, width: side, height: side))
                }
            }
            KineticWordsView(words: frame.labels, colors: colors, baseSize: baseSize, time: time, beat: .none, drift: false)
        }
        .scaleEffect(1 + 0.02 * beat.pulse)
        .rotation3DEffect(.degrees(5 * sin(time * 0.4)), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
        .rotation3DEffect(.degrees(3 * sin(time * 0.31 + 1.1)), axis: (x: 1, y: 0, z: 0), perspective: 0.45)
        .allowsHitTesting(false)
    }
}
