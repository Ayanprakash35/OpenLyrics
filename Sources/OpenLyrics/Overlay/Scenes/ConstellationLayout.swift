import Foundation

/// One star of a constellation: a word, where it sits, and the earlier star it branches from.
/// Positions are in multiples of the base font size, from the middle of the lyrics.
struct ConstellationNode: Hashable, Sendable {
    var text: String
    var start: TimeInterval
    var x: Double
    var y: Double
    var parent: Int?
    var colorSlot: Int
}

/// Constellation tuning. Lengths are in multiples of the base font size.
enum ConstellationConfig {
    /// Half the area the stars spread over. Sane range: 4–8 wide, 1.2–2.5 high.
    static let halfWidth = 5.6
    static let halfHeight = 1.7
    /// Distance from a star to the next. Sane range: 0.9–2.4.
    static let step: ClosedRange<Double> = 1.2...1.9
    /// Chance a new star branches from an earlier one rather than the last. Sane range: 0–0.5.
    static let branchChance = 0.3
    /// Most words one constellation takes; later ones aren't drawn. Sane range: 20–60.
    static let maximumStars = 40
    /// Label size of the word being sung and of those before it.
    static let currentScale = 0.72
    static let pastScale = 0.3
    /// Seconds a label takes to shrink once the next word starts. Sane range: 0.2–0.8.
    static let shrinkDuration = 0.45
    /// Past labels still shown; older stars keep only their point. Sane range: 4–20.
    static let labelsShown = 12
    /// Seconds a line takes to reach its new star; it starts a little before the word.
    static let edgeGrow = 0.35
    static let edgeLead = 0.12
    /// Seconds the view takes to glide toward the middle of the stars so far.
    static let cameraGlide = 0.6
}

/// Lays a stretch of lyrics out as a constellation: each word a star, joined to the one before
/// it or, now and then, branching off an earlier one. Like the word styles, a frame is a pure
/// function of time.
enum ConstellationLayout {
    /// A star's point: `ring` is 1 for the word being sung.
    struct Star: Equatable {
        var x: Double
        var y: Double
        var size: Double
        var ring: Double
        var opacity: Double
        var colorSlot: Int
    }

    /// A line between two stars, drawn `progress` of the way from the older one.
    struct Edge: Equatable {
        var fromX: Double, fromY: Double
        var toX: Double, toY: Double
        var progress: Double
        var opacity: Double
        var colorSlot: Int
    }

    struct Frame: Equatable {
        var labels: [PlacedWord] = []
        var stars: [Star] = []
        var edges: [Edge] = []
    }

    /// How visible the word style and the constellation are while one hands over to the other
    /// (`takeover` 0 → 1): the words fade out first, then the stars fade in, so the two never
    /// pile up in the middle. Reversed as the constellation ends.
    static func handoff(_ takeover: Double) -> (words: Double, stars: Double) {
        (1 - Motion.clamp(takeover * 2), Motion.clamp(takeover * 2 - 1))
    }

    /// The stars for the words sung during `event`.
    static func nodes(for event: SceneEvent, in lyrics: Lyrics) -> [ConstellationNode] {
        let words = lyrics.lines.filter { !$0.isGap }
            .flatMap(\.words)
            .filter { $0.start >= event.start - 0.01 && $0.start <= event.end }
            .prefix(ConstellationConfig.maximumStars)
        var random = SeededRandom(seed: event.seed)
        var nodes: [ConstellationNode] = []
        var heading = 0.0
        let config = ConstellationConfig.self

        for (index, word) in words.enumerated() {
            let text = word.text.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            guard index > 0 else {
                nodes.append(ConstellationNode(text: text, start: word.start, x: -config.halfWidth * 0.55,
                                               y: random.next(in: -0.4...0.4), parent: nil, colorSlot: 0))
                continue
            }
            let branches = index >= 3 && random.next(in: 0...1) < config.branchChance
            let parent = branches ? Int(random.next(in: Double(max(0, index - 6))...Double(index - 2)).rounded()) : index - 1
            let origin = nodes[parent]
            // Tries a handful of spots and keeps the one with the most room, preferring to keep going
            // the same way.
            var best: (x: Double, y: Double, angle: Double, score: Double)?
            for _ in 0..<14 {
                let angle = branches ? random.next(in: -Double.pi...Double.pi) : heading + random.next(in: -1.2...1.2)
                let distance = random.next(in: config.step)
                var x = origin.x + cos(angle) * distance
                var y = origin.y + sin(angle) * distance * 0.7
                let outside = max(0, abs(x) - config.halfWidth) + max(0, abs(y) - config.halfHeight)
                x = Motion.clamp(x, -config.halfWidth, config.halfWidth)
                y = Motion.clamp(y, -config.halfHeight, config.halfHeight)
                let room = nodes.map { hypot($0.x - x, ($0.y - y) * 1.4) }.min() ?? 10
                let score = min(room, 2.5) - outside * 3 + 0.25 * cos(angle - heading)
                if best == nil || score > best!.score { best = (x, y, angle, score) }
            }
            guard let best else { continue }
            if !branches { heading = best.angle }
            nodes.append(ConstellationNode(text: text, start: word.start, x: best.x, y: best.y, parent: parent, colorSlot: index))
        }
        return nodes
    }

    /// What to draw at `time`: the stars and lines so far, the sung word's label large, the
    /// earlier ones small, all glided so the stars so far sit in the middle.
    static func frame(nodes: [ConstellationNode], at time: TimeInterval) -> Frame {
        let config = ConstellationConfig.self
        guard let current = nodes.lastIndex(where: { $0.start <= time }) else { return Frame() }
        let camera = cameraCenter(nodes: nodes, current: current, at: time)
        var frame = Frame()

        for (index, node) in nodes.enumerated() where node.start - config.edgeLead <= time {
            let x = node.x - camera.x, y = node.y - camera.y
            let age = time - node.start
            if let parent = node.parent {
                let grow = Motion.smooth(age + config.edgeLead, duration: config.edgeGrow)
                let from = nodes[parent]
                frame.edges.append(Edge(fromX: from.x - camera.x, fromY: from.y - camera.y, toX: x, toY: y,
                                        progress: grow, opacity: index == current ? 0.75 : 0.45, colorSlot: node.colorSlot))
            }
            guard age >= 0 else { continue }
            let pop = Motion.backOut(age, duration: 0.4, overshoot: 2)
            let isCurrent = index == current
            frame.stars.append(Star(x: x, y: y, size: (isCurrent ? 0.15 : 0.09) * pop, ring: isCurrent ? pop : 0,
                                    opacity: 1, colorSlot: node.colorSlot))

            // The label shrinks once the next word starts, and the oldest fade away.
            let back = current - index
            guard back <= config.labelsShown else { continue }
            let since = index < current ? time - nodes[index + 1].start : 0
            let shrink = Motion.smooth(since, duration: config.shrinkDuration)
            let scale = (config.currentScale + (config.pastScale - config.currentScale) * shrink) * pop
            let ageing = Double(back) / Double(config.labelsShown)
            let opacity = 1 - shrink * (0.3 + 0.5 * ageing) - (back == config.labelsShown ? shrink : 0)
            frame.labels.append(PlacedWord(
                id: "star-\(node.start)-\(index)", text: node.text,
                x: x, y: y - (0.22 + scale * 0.62), scale: max(0.001, scale), opacity: max(0, opacity),
                boxed: 0, faded: 0.6 * shrink, fill: 0, tiltX: 0, tiltY: 0, tiltZ: 0,
                icon: nil, iconLeading: false, age: age, colorSlot: node.colorSlot
            ))
        }
        return frame
    }

    /// The middle of the stars up to `current`, glided toward from the middle before it.
    private static func cameraCenter(nodes: [ConstellationNode], current: Int, at time: TimeInterval) -> (x: Double, y: Double) {
        func center(through last: Int) -> (x: Double, y: Double) {
            let shown = nodes[0...last]
            let xs = shown.map(\.x), ys = shown.map(\.y)
            return (((xs.min() ?? 0) + (xs.max() ?? 0)) / 2, ((ys.min() ?? 0) + (ys.max() ?? 0)) / 2)
        }
        let now = center(through: current)
        guard current > 0 else { return now }
        let before = center(through: current - 1)
        let glide = Motion.smooth(time - nodes[current].start, duration: ConstellationConfig.cameraGlide)
        return (before.x + (now.x - before.x) * glide, before.y + (now.y - before.y) * glide)
    }
}

/// A small deterministic generator, so a constellation has the same shape every time it's drawn.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed ^ 0x2545_F491_4F6C_DD1D }

    mutating func nextBits() -> UInt64 {
        // SplitMix64.
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        let unit = Double(nextBits() >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
