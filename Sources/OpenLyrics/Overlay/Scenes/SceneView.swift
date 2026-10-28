import SwiftUI

/// Draws the scenes active at a moment around the lyrics. Two layers: weather and floating
/// things behind the words, and vehicles, flags, confetti and flashes in front.
///
/// Everything is computed from the time and each scene's seed — no animation state — and drawn
/// straight into one `Canvas` per layer, so a hundred raindrops cost one view.
struct SceneView: View {
    enum Layer { case behind, front }

    var events: [SceneEvent]
    var time: TimeInterval
    var baseSize: CGFloat
    var colors: LyricColors
    var layer: Layer

    var body: some View {
        Canvas { context, size in
            for event in events where Self.layer(of: event.kind) == layer {
                let strength = event.envelope(at: time)
                guard strength > 0.001 else { continue }
                draw(event, strength: strength, in: &context, size: size)
            }
        }
        .allowsHitTesting(false)
    }

    /// Scenes that move across the screen and look choppy at the calm frame rate.
    static func needsFastFrames(_ kind: SceneKind) -> Bool {
        switch kind {
        case .vehicle, .flag, .confetti, .flash: true
        default: false
        }
    }

    static func layer(of kind: SceneKind) -> Layer {
        switch kind {
        case .vehicle, .flag, .confetti, .flash: .front
        default: .behind
        }
    }

    private func draw(_ event: SceneEvent, strength: Double, in context: inout GraphicsContext, size: CGSize) {
        let age = time - event.start
        switch event.kind {
        case .rain: drawRain(event.seed, strength, &context, size)
        case .snow: drawSnow(event.seed, strength, &context, size)
        case .hearts: drawRising(symbol: "heart.fill", count: 14, seed: event.seed, strength: strength, &context, size)
        case .stars: drawStars(event.seed, strength, &context, size)
        case .money: drawFalling(glyph: "💸", count: 14, seed: event.seed, strength: strength, &context, size)
        case .confetti: drawConfetti(event.seed, age: age, &context, size)
        case .embers: drawEmbers(event.seed, strength, &context, size)
        case .flash: drawFlash(age: age, &context, size)
        case .flag(let glyph): drawFlag(glyph, age: age, strength: strength, &context, size)
        case .vehicle(let vehicle): drawVehicle(vehicle, age: age, duration: event.end - event.start, strength: strength, &context, size)
        case .constellation: break
        }
    }

    // MARK: - Helpers

    /// A stable value in 0...1 for particle `index` of the scene seeded `seed`.
    private static func unit(_ seed: UInt64, _ index: Int, _ salt: UInt64) -> Double {
        (Motion.jitter(seed &* 31 &+ UInt64(index) &* 7919 &+ salt) + 1) / 2
    }

    /// Fades particles toward the edges of the scene area, so effects surround the lyrics
    /// without ending in a hard rectangle.
    private static func edgeFade(_ point: CGPoint, in size: CGSize) -> Double {
        func fade(_ value: CGFloat, _ length: CGFloat) -> Double {
            let t = Double(value / max(length, 1))
            return Motion.clamp(min(t, 1 - t) / 0.18)
        }
        return fade(point.x, size.width) * fade(point.y, size.height)
    }

    private var accent: [Color] {
        let solids = colors.variants.map(\.highlight.color)
        return solids.isEmpty ? [colors.highlight.color] : solids
    }

    // MARK: - Weather

    private func drawRain(_ seed: UInt64, _ strength: Double, _ context: inout GraphicsContext, _ size: CGSize) {
        let count = Int(130 * strength)
        let tint = colors.lyric.mixed(with: PaletteColor(red: 0.8, green: 0.9, blue: 1), 0.7).color
        let scale = baseSize / 60
        for index in 0..<count {
            let u = { (salt: UInt64) in Self.unit(seed, index, salt) }
            let fall = 0.5 + 0.35 * u(2)
            let progress = (time / fall + u(3)).truncatingRemainder(dividingBy: 1)
            let y = -0.1 * size.height + CGFloat(progress) * 1.2 * size.height
            let x = CGFloat(u(1)) * size.width * 1.2 - size.width * 0.1 + y * 0.16
            let length = (0.05 + 0.05 * CGFloat(u(4))) * size.height
            let head = CGPoint(x: x, y: y), tail = CGPoint(x: x - length * 0.16, y: y - length)
            let alpha = (0.25 + 0.4 * u(5)) * Self.edgeFade(head, in: size)
            var path = Path()
            path.move(to: tail)
            path.addLine(to: head)
            context.stroke(path, with: .color(tint.opacity(alpha)), style: StrokeStyle(lineWidth: (1 + CGFloat(u(6))) * scale, lineCap: .round))
        }
    }

    private func drawSnow(_ seed: UInt64, _ strength: Double, _ context: inout GraphicsContext, _ size: CGSize) {
        let count = Int(80 * strength)
        let scale = baseSize / 60
        for index in 0..<count {
            let u = { (salt: UInt64) in Self.unit(seed, index, salt) }
            let fall = 5 + 4 * u(2)
            let progress = (time / fall + u(3)).truncatingRemainder(dividingBy: 1)
            let y = -0.05 * size.height + CGFloat(progress) * 1.1 * size.height
            let x = CGFloat(u(1)) * size.width + CGFloat(sin(time * (0.6 + u(4)) + u(5) * 6.3)) * 0.04 * size.width
            let radius = (1.3 + 2.2 * CGFloat(u(6))) * scale
            let point = CGPoint(x: x, y: y)
            let alpha = (0.45 + 0.45 * u(7)) * Self.edgeFade(point, in: size)
            context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)), with: .color(.white.opacity(alpha)))
        }
    }

    private func drawStars(_ seed: UInt64, _ strength: Double, _ context: inout GraphicsContext, _ size: CGSize) {
        var symbol = context.resolve(Image(systemName: "sparkle"))
        let count = Int(28 * strength)
        let palette = accent
        for index in 0..<count {
            let u = { (salt: UInt64) in Self.unit(seed, index, salt) }
            let point = CGPoint(x: CGFloat(u(1)) * size.width, y: CGFloat(u(2)) * size.height)
            let twinkle = max(0, sin(time * 2.4 * (0.6 + u(3)) + u(4) * 6.3))
            let alpha = (0.25 + 0.75 * twinkle) * Self.edgeFade(point, in: size)
            let side = baseSize * (0.12 + 0.18 * CGFloat(u(5))) * CGFloat(0.8 + 0.4 * twinkle)
            symbol.shading = .color(index % 3 == 0 ? .white : palette[index % palette.count])
            var star = context
            star.opacity = alpha
            star.draw(symbol, in: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side))
        }
    }

    private func drawEmbers(_ seed: UInt64, _ strength: Double, _ context: inout GraphicsContext, _ size: CGSize) {
        let count = Int(46 * strength)
        let scale = baseSize / 60
        let hot = [Color(red: 1, green: 0.62, blue: 0.2), Color(red: 1, green: 0.82, blue: 0.35), Color(red: 1, green: 0.4, blue: 0.2)]
        for index in 0..<count {
            let u = { (salt: UInt64) in Self.unit(seed, index, salt) }
            let rise = 2 + 1.6 * u(2)
            let progress = (time / rise + u(3)).truncatingRemainder(dividingBy: 1)
            let y = size.height * (1.05 - CGFloat(progress) * 1.1)
            let x = CGFloat(u(1)) * size.width + CGFloat(sin(time * 3 * (0.5 + u(4)) + u(5) * 6.3)) * 0.02 * size.width
            let radius = (1 + 1.8 * CGFloat(u(6))) * scale * CGFloat(1 - progress * 0.5)
            let flicker = 0.55 + 0.45 * sin(time * 14 * (0.5 + u(7)) + u(8) * 6.3)
            let point = CGPoint(x: x, y: y)
            let alpha = flicker * (1 - progress) * Self.edgeFade(point, in: size)
            let color = hot[index % hot.count]
            context.fill(Path(ellipseIn: CGRect(x: x - radius * 2.2, y: y - radius * 2.2, width: radius * 4.4, height: radius * 4.4)), with: .color(color.opacity(alpha * 0.25)))
            context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)), with: .color(color.opacity(alpha)))
        }
    }

    // MARK: - Floating things

    private func drawRising(symbol name: String, count: Int, seed: UInt64, strength: Double, _ context: inout GraphicsContext, _ size: CGSize) {
        var symbol = context.resolve(Image(systemName: name))
        let palette = accent
        for index in 0..<Int(Double(count) * strength) {
            let u = { (salt: UInt64) in Self.unit(seed, index, salt) }
            let rise = 3 + 2 * u(2)
            let progress = (time / rise + u(3)).truncatingRemainder(dividingBy: 1)
            let y = size.height * (1 - CGFloat(progress))
            let x = CGFloat(u(1)) * size.width + CGFloat(sin(time * 1.6 + u(4) * 6.3)) * 0.03 * size.width
            let side = baseSize * (0.22 + 0.22 * CGFloat(u(5))) * CGFloat(0.6 + 0.6 * progress)
            let point = CGPoint(x: x, y: y)
            symbol.shading = .color(palette[index % palette.count])
            var item = context
            item.opacity = sin(.pi * progress) * Self.edgeFade(point, in: size)
            item.draw(symbol, in: CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side))
        }
    }

    private func drawFalling(glyph: String, count: Int, seed: UInt64, strength: Double, _ context: inout GraphicsContext, _ size: CGSize) {
        let text = context.resolve(Text(glyph).font(.system(size: baseSize * 0.42)))
        for index in 0..<Int(Double(count) * strength) {
            let u = { (salt: UInt64) in Self.unit(seed, index, salt) }
            let fall = 3.5 + 2.5 * u(2)
            let progress = (time / fall + u(3)).truncatingRemainder(dividingBy: 1)
            let point = CGPoint(
                x: CGFloat(u(1)) * size.width + CGFloat(sin(time * 2 + u(4) * 6.3)) * 0.03 * size.width,
                y: -0.05 * size.height + CGFloat(progress) * 1.1 * size.height
            )
            var item = context
            item.opacity = Self.edgeFade(point, in: size)
            item.translateBy(x: point.x, y: point.y)
            item.rotate(by: .degrees(25 * sin(time * 2.5 + u(5) * 6.3)))
            item.scaleBy(x: 0.7 + 0.5 * u(6), y: 0.7 + 0.5 * u(6))
            item.draw(text, at: .zero)
        }
    }

    private func drawConfetti(_ seed: UInt64, age: TimeInterval, _ context: inout GraphicsContext, _ size: CGSize) {
        guard age >= 0 else { return }
        let palette = accent + [.white]
        let center = CGPoint(x: size.width / 2, y: size.height * 0.45)
        let gravity = baseSize * 7
        for index in 0..<80 {
            let u = { (salt: UInt64) in Self.unit(seed, index, salt) }
            let angle = u(1) * 2 * .pi
            let speed = baseSize * (3 + 5 * CGFloat(u(2)))
            let t = CGFloat(age)
            let point = CGPoint(
                x: center.x + cos(angle) * speed * t,
                y: center.y + sin(angle) * speed * t * 0.75 + 0.5 * gravity * t * t
            )
            let alpha = Motion.clamp(2.6 - age) * Self.edgeFade(point, in: size)
            var piece = context
            piece.opacity = alpha
            piece.translateBy(x: point.x, y: point.y)
            piece.rotate(by: .radians(age * (4 + 8 * u(3)) + u(4) * 6.3))
            let w = baseSize * 0.07, h = baseSize * 0.15
            piece.fill(Path(CGRect(x: -w / 2, y: -h / 2, width: w, height: h)), with: .color(palette[index % palette.count]))
        }
    }

    private func drawFlash(age: TimeInterval, _ context: inout GraphicsContext, _ size: CGSize) {
        // Two strikes: a bright one and a fainter echo.
        let strike = Motion.curve(age, [(0, 0), (0.05, 0.42), (0.22, 0), (0.36, 0.22), (0.6, 0)])
        guard strike > 0 else { return }
        let gradient = Gradient(colors: [.white.opacity(strike), .white.opacity(0)])
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(gradient, center: CGPoint(x: size.width / 2, y: size.height / 2), startRadius: 0, endRadius: max(size.width, size.height) * 0.6)
        )
    }

    // MARK: - Flags and vehicles

    private func drawFlag(_ glyph: String, age: TimeInterval, strength: Double, _ context: inout GraphicsContext, _ size: CGSize) {
        let text = context.resolve(Text(glyph).font(.system(size: baseSize * 1.1)))
        let pop = Motion.backOut(age, duration: 0.5, overshoot: 2.4)
        var flag = context
        flag.opacity = strength
        flag.translateBy(x: size.width / 2 + baseSize * 3.4, y: size.height / 2 - baseSize * 1.5 - CGFloat(sin(age * 2.2)) * baseSize * 0.06)
        flag.rotate(by: .degrees(9 * sin(age * 4.5)))
        flag.scaleBy(x: max(0.001, pop), y: max(0.001, pop))
        flag.draw(text, at: .zero)
    }

    private func drawVehicle(_ vehicle: Vehicle, age: TimeInterval, duration: TimeInterval, strength: Double, _ context: inout GraphicsContext, _ size: CGSize) {
        let text = context.resolve(Text(vehicle.glyph).font(.system(size: baseSize * 0.95)))
        let margin = baseSize * 1.5
        let t = CGFloat(Motion.clamp(age / duration))
        let ride = CGFloat(Motion.smooth(Double(t), duration: 1)) * 0.25 + t * 0.75
        let groundY = size.height / 2 + baseSize * 1.95
        var position: CGPoint
        var rotation = 0.0
        var bounce: CGFloat = 0
        switch vehicle.path {
        case .road:
            // Emoji vehicles face left, so they drive right to left.
            position = CGPoint(x: size.width + margin - ride * (size.width + 2 * margin), y: groundY)
            bounce = -abs(CGFloat(sin(age * 11))) * baseSize * 0.05
        case .water:
            position = CGPoint(x: size.width + margin - ride * (size.width + 2 * margin), y: groundY)
            bounce = CGFloat(sin(age * 3)) * baseSize * 0.08
            rotation = 6 * sin(age * 3)
        case .sky where vehicle.glyph == "✈️":
            let start = CGPoint(x: -margin, y: size.height * 0.85), end = CGPoint(x: size.width + margin, y: size.height * 0.1)
            position = CGPoint(x: start.x + (end.x - start.x) * ride, y: start.y + (end.y - start.y) * ride)
            // The plane emoji points up and to the right; turn it onto its course.
            rotation = atan2(Double(end.y - start.y), Double(end.x - start.x)) * 180 / .pi + 45
        case .sky:
            position = CGPoint(x: size.width + margin - ride * (size.width + 2 * margin), y: size.height * 0.15)
            bounce = CGFloat(sin(age * 4)) * baseSize * 0.06
        case .rise:
            let start = CGPoint(x: size.width / 2 + baseSize * 2.5, y: size.height + margin)
            let end = CGPoint(x: size.width / 2 + baseSize * 4, y: -margin)
            position = CGPoint(x: start.x + (end.x - start.x) * ride, y: start.y + (end.y - start.y) * ride)
            rotation = atan2(Double(end.y - start.y), Double(end.x - start.x)) * 180 / .pi + 45
        }
        position.y += bounce

        // Speed lines trailing the vehicle on the road.
        if vehicle.path == .road {
            for line in 0..<3 {
                let offset = CGFloat(line) * baseSize * 0.16 - baseSize * 0.16
                var path = Path()
                let x0 = position.x + baseSize * 0.55
                path.move(to: CGPoint(x: x0, y: position.y + offset))
                path.addLine(to: CGPoint(x: x0 + baseSize * (0.35 + 0.15 * CGFloat(line % 2)), y: position.y + offset))
                context.stroke(path, with: .color(colors.lyric.color.opacity(0.5 * strength)), style: StrokeStyle(lineWidth: baseSize * 0.035, lineCap: .round))
            }
        }
        var item = context
        item.opacity = strength
        item.translateBy(x: position.x, y: position.y)
        item.rotate(by: .degrees(rotation))
        item.draw(text, at: .zero)
    }
}
