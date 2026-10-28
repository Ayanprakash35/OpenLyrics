import Foundation

/// Something that happens around the lyrics for a while: weather, things floating by, a vehicle
/// driving past, a flag, or the constellation the words turn into.
enum SceneKind: Hashable, Sendable {
    /// Streaks of rain falling through and around the lyrics.
    case rain
    case snow
    /// Hearts rising and fading.
    case hearts
    /// Stars twinkling around the words.
    case stars
    /// Bills fluttering down.
    case money
    /// A burst of confetti in the album's colors.
    case confetti
    /// Sparks rising, as from a fire below.
    case embers
    /// A lightning flash.
    case flash
    /// A flag (an emoji) popping up and waving beside the lyrics.
    case flag(String)
    /// A vehicle (an emoji) driving, sailing or flying past.
    case vehicle(Vehicle)
    /// The words become stars joined by lines, a new star for each word.
    case constellation
}

/// A vehicle and the way it crosses the lyrics.
struct Vehicle: Hashable, Sendable {
    enum Path: Hashable, Sendable {
        /// Along the bottom, right to left, with a little bounce.
        case road
        /// Diagonally up across the top, left to right.
        case sky
        /// Slowly along the bottom, bobbing.
        case water
        /// Straight up from below.
        case rise
    }

    var glyph: String
    var path: Path
}

/// One scene with its timing. `seed` keeps its particles in the same places every frame.
struct SceneEvent: Hashable, Sendable, Identifiable {
    var kind: SceneKind
    var start: TimeInterval
    var end: TimeInterval
    var seed: UInt64

    var id: String { "\(kind)-\(start)" }

    /// 0 at the start and end, 1 in between: scenes fade in and out over `ramp` seconds.
    func envelope(at time: TimeInterval, ramp: TimeInterval = 0.6) -> Double {
        guard time >= start, time <= end else { return 0 }
        let fadeIn = Motion.clamp((time - start) / ramp)
        let fadeOut = Motion.clamp((end - time) / ramp)
        return min(fadeIn, fadeOut)
    }
}

/// Every scene of a song, in start order.
struct SceneScript: Hashable, Sendable {
    var events: [SceneEvent] = []

    static let empty = SceneScript()

    func active(at time: TimeInterval) -> [SceneEvent] {
        events.filter { time >= $0.start && time <= $0.end }
    }

    /// The constellation in progress at `time`, if any.
    func constellation(at time: TimeInterval) -> SceneEvent? {
        events.first { $0.kind == .constellation && time >= $0.start && time <= $0.end }
    }
}

/// Scene tuning.
enum SceneConfig {
    /// Seconds a word's effect outlasts its line. Sane range: 0.5–3.
    static let lineTail: TimeInterval = 1.5
    /// Shortest a word's effect lasts, for short lines. Sane range: 2–6.
    static let minimumEffect: TimeInterval = 3.5
    /// Seconds before the same effect may be triggered by a word again, so a chorus full of
    /// "rain" doesn't drizzle nonstop. Sane range: 5–30.
    static let cooldown: TimeInterval = 12
    /// Seconds a vehicle takes to cross. Sane range: 1.2–3.5.
    static let vehicleCrossing: TimeInterval = 2.4
    /// Seconds between two vehicles. Sane range: 1–5.
    static let vehicleGap: TimeInterval = 2.5
    /// Lines a constellation spans, counting the one that starts it. Sane range: 2–5.
    static let constellationLines = 3
    /// Longest a constellation lasts. Sane range: 6–20.
    static let constellationMaximum: TimeInterval = 13
    /// Seconds a flag stays up. Sane range: 2–8.
    static let flagDuration: TimeInterval = 4.5
    /// The area effects cover around the lyrics, in multiples of the base font size.
    static let areaWidth: CGFloat = 15
    static let areaHeight: CGFloat = 6.5
}

/// Decides a song's scenes from its title, artist and lyrics: easter eggs for particular songs,
/// and effects for words that suggest one.
enum SceneDirector {
    struct Track: Sendable {
        var title: String
        var artist: String
    }

    static func script(for lyrics: Lyrics, track: Track) -> SceneScript {
        guard lyrics.isSynced else { return .empty }
        let duration = lyrics.lines.last?.end ?? 0
        var events: [SceneEvent] = []
        var seed: UInt64 = 1

        func add(_ kind: SceneKind, _ start: TimeInterval, _ end: TimeInterval) {
            events.append(SceneEvent(kind: kind, start: start, end: max(end, start + 0.5), seed: seed))
            seed &+= 0x9E37_79B9
        }

        // MARK: Easter eggs
        let egg = EasterEggs.match(title: track.title, artist: track.artist)
        if let ambient = egg?.ambient, let first = lyrics.lines.first(where: { !$0.isGap }) {
            add(ambient, max(0, first.start - 2), duration)
        }

        // MARK: Word effects
        var lastByKind: [SceneKind: TimeInterval] = [:]
        var lastVehicle = -Double.infinity
        var constellationUntil = -Double.infinity
        let sungLines = lyrics.lines.enumerated().filter { !$0.element.isGap }

        for (position, (_, line)) in sungLines.enumerated() {
            let texts = line.words.map(\.text)
            for (index, word) in line.words.enumerated() {
                let next = index + 1 < texts.count ? texts[index + 1] : nil
                let previous = index > 0 ? texts[index - 1] : nil

                if let flag = egg?.flag, egg?.flagWords.contains(where: { WordIcons.candidates(for: word.text).contains($0) }) == true,
                   word.start - (lastByKind[.flag(flag)] ?? -.infinity) >= SceneConfig.flagDuration + 2 {
                    add(.flag(flag), word.start, word.start + SceneConfig.flagDuration)
                    lastByKind[.flag(flag)] = word.start
                }

                if let vehicle = Vehicles.vehicle(for: word.text, next: next, previous: previous),
                   word.start - lastVehicle >= SceneConfig.vehicleGap {
                    add(.vehicle(vehicle), word.start, word.start + SceneConfig.vehicleCrossing)
                    lastVehicle = word.start
                }

                guard let kind = WordEffects.effect(for: word.text) else { continue }
                if kind == .constellation {
                    guard word.start > constellationUntil else { continue }
                    let lastLine = sungLines[min(position + SceneConfig.constellationLines - 1, sungLines.count - 1)].element
                    let end = min(lastLine.end, word.start + SceneConfig.constellationMaximum)
                    add(.constellation, word.start, end)
                    constellationUntil = end
                    continue
                }
                // An effect the whole song already has (an easter egg) isn't doubled.
                if kind == egg?.ambient { continue }
                guard word.start - (lastByKind[kind] ?? -.infinity) >= SceneConfig.cooldown else { continue }
                let end: TimeInterval = switch kind {
                case .confetti: word.start + 2.8
                case .flash: word.start + 0.9
                default: max(line.end + SceneConfig.lineTail, word.start + SceneConfig.minimumEffect)
                }
                add(kind, word.start, end)
                lastByKind[kind] = word.start
            }
        }
        // Songs with a flag pop it as the singing starts, too.
        if let flag = egg?.flag, let first = lyrics.lines.first(where: { !$0.isGap }),
           !events.contains(where: { $0.kind == .flag(flag) && abs($0.start - first.start) < 8 }) {
            add(.flag(flag), first.start, first.start + SceneConfig.flagDuration)
        }
        return SceneScript(events: events.sorted { $0.start < $1.start })
    }
}

/// Words that set off an effect (base forms; plurals and -ing/-ed forms match too).
enum WordEffects {
    private static let table: [(String, SceneKind)] = [
        ("rain raining rainy raindrops drizzle downpour storm stormy baarish barish barsaat sawan lluvia chuva pluie 雨 비", .rain),
        ("snow snowing snowfall snowflake snowflakes blizzard", .snow),
        ("heart hearts heartbeat", .hearts),
        ("stars starlight stardust constellation galaxy taare sitare estrellas étoiles 星", .stars),
        ("money cash dollars racks bands rich millionaire paisa dinero", .money),
        ("party celebrate celebration confetti birthday fiesta", .confetti),
        ("fire flame flames burn burning blaze inferno aag fuego", .embers),
        ("thunder lightning thunderstorm", .flash),
        ("bridge bridges", .constellation),
    ]

    private static let lookup: [String: SceneKind] = {
        var result: [String: SceneKind] = [:]
        for (words, kind) in table {
            for word in words.split(separator: " ") { result[String(word)] = kind }
        }
        return result
    }()

    static func effect(for word: String) -> SceneKind? {
        for candidate in WordIcons.candidates(for: word) {
            if let kind = lookup[candidate] { return kind }
        }
        return nil
    }
}

/// Vehicles that drive past when sung about: kinds of vehicle, and makes and models.
enum Vehicles {
    /// Two-word names, checked before single words.
    private static let pairs: [String: Vehicle] = [
        "range rover": Vehicle(glyph: "🚙", path: .road), "land rover": Vehicle(glyph: "🚙", path: .road),
        "rolls royce": Vehicle(glyph: "🚗", path: .road), "aston martin": Vehicle(glyph: "🏎️", path: .road),
        "race car": Vehicle(glyph: "🏎️", path: .road), "police car": Vehicle(glyph: "🚓", path: .road),
        "fire truck": Vehicle(glyph: "🚒", path: .road), "pickup truck": Vehicle(glyph: "🛻", path: .road),
        "mercedes benz": Vehicle(glyph: "🚗", path: .road), "space ship": Vehicle(glyph: "🚀", path: .rise),
    ]

    private static let singles: [(String, Vehicle)] = [
        ("car cars automobile sedan coupe convertible cadillac caddy chevy chevrolet impala cutlass buick lincoln mercedes benz bmw beamer beemer audi lexus toyota honda nissan volvo volkswagen beetle tesla prius bentley maybach phantom limo limousine jaguar ford", Vehicle(glyph: "🚗", path: .road)),
        ("ferrari lambo lamborghini porsche bugatti mclaren corvette vette mustang camaro viper supra racecar", Vehicle(glyph: "🏎️", path: .road)),
        ("rover jeep wrangler suv escalade hummer tahoe suburban bronco gwagon", Vehicle(glyph: "🚙", path: .road)),
        ("truck trucks pickup silverado", Vehicle(glyph: "🛻", path: .road)),
        ("taxi cab uber lyft", Vehicle(glyph: "🚕", path: .road)),
        ("police cops", Vehicle(glyph: "🚓", path: .road)),
        ("bus", Vehicle(glyph: "🚌", path: .road)),
        ("ambulance", Vehicle(glyph: "🚑", path: .road)),
        ("tractor", Vehicle(glyph: "🚜", path: .road)),
        ("motorcycle motorbike harley ducati", Vehicle(glyph: "🏍️", path: .road)),
        ("bicycle bike", Vehicle(glyph: "🚲", path: .road)),
        ("train trains subway metro", Vehicle(glyph: "🚆", path: .road)),
        ("plane planes airplane jet jets flight", Vehicle(glyph: "✈️", path: .sky)),
        ("helicopter chopper", Vehicle(glyph: "🚁", path: .sky)),
        ("ufo spaceship", Vehicle(glyph: "🛸", path: .sky)),
        ("rocket rockets", Vehicle(glyph: "🚀", path: .rise)),
        ("boat boats ship ships sail sailing yacht", Vehicle(glyph: "⛵️", path: .water)),
    ]

    private static let lookup: [String: Vehicle] = {
        var result: [String: Vehicle] = [:]
        for (words, vehicle) in singles {
            for word in words.split(separator: " ") { result[String(word)] = vehicle }
        }
        return result
    }()

    /// The vehicle `word` names, alone or with its neighbor ("Range Rover", "rolls royce").
    static func vehicle(for word: String, next: String?, previous: String?) -> Vehicle? {
        let base = WordIcons.candidates(for: word).first ?? ""
        if let next, let pair = pairs["\(base) \(WordIcons.candidates(for: next).first ?? "")"] { return pair }
        // The second word of a pair was handled with the first.
        if let previous, pairs["\(WordIcons.candidates(for: previous).first ?? "") \(base)"] != nil { return nil }
        for candidate in WordIcons.candidates(for: word) {
            if let vehicle = lookup[candidate] { return vehicle }
        }
        return nil
    }
}

/// Songs with a surprise of their own.
enum EasterEggs {
    struct Egg: Sendable {
        /// An effect for the whole song.
        var ambient: SceneKind?
        /// A flag that pops up on `flagWords` (and as the singing starts).
        var flag: String?
        var flagWords: Set<String> = []
    }

    private struct Rule {
        /// Matched against the cleaned title (no "Remastered", "Live", "feat." and so on).
        var title: String
        /// Part of the artist credit, or nil for any artist (covers included).
        var artist: String?
        var egg: Egg
    }

    private static let rules: [Rule] = [
        Rule(title: "iris", artist: "goo goo dolls", egg: Egg(ambient: .rain)),
        Rule(title: "viva la vida", artist: nil, egg: Egg(
            flag: "🇫🇷",
            flagWords: ["viva", "vida", "king", "bells", "jerusalem", "revolutionaries", "castle", "crown", "rule", "kingdom"]
        )),
        Rule(title: "purple rain", artist: nil, egg: Egg(ambient: .rain)),
        Rule(title: "umbrella", artist: "rihanna", egg: Egg(ambient: .rain)),
        Rule(title: "set fire to the rain", artist: "adele", egg: Egg(ambient: .rain)),
        Rule(title: "let it snow", artist: nil, egg: Egg(ambient: .snow)),
        Rule(title: "snowman", artist: "sia", egg: Egg(ambient: .snow)),
        Rule(title: "last christmas", artist: nil, egg: Egg(ambient: .snow)),
        Rule(title: "all i want for christmas is you", artist: nil, egg: Egg(ambient: .snow)),
        Rule(title: "yellow", artist: "coldplay", egg: Egg(ambient: .stars)),
        Rule(title: "a sky full of stars", artist: "coldplay", egg: Egg(ambient: .stars)),
        Rule(title: "counting stars", artist: "onerepublic", egg: Egg(ambient: .stars)),
        Rule(title: "fireflies", artist: "owl city", egg: Egg(ambient: .stars)),
        Rule(title: "firework", artist: "katy perry", egg: Egg(ambient: .confetti)),
        Rule(title: "happy", artist: "pharrell", egg: Egg(ambient: .confetti)),
        Rule(title: "diamonds", artist: "rihanna", egg: Egg(ambient: .stars)),
        Rule(title: "girl on fire", artist: "alicia keys", egg: Egg(ambient: .embers)),
        Rule(title: "fire", artist: nil, egg: Egg(ambient: .embers)),
        Rule(title: "money", artist: nil, egg: Egg(ambient: .money)),
        Rule(title: "la vie en rose", artist: nil, egg: Egg(flag: "🇫🇷", flagWords: ["vie", "rose", "amour"])),
        Rule(title: "american idiot", artist: "green day", egg: Egg(flag: "🇺🇸", flagWords: ["america", "american", "nation"])),
        Rule(title: "party in the u s a", artist: "miley", egg: Egg(ambient: .confetti, flag: "🇺🇸", flagWords: ["usa", "america"])),
        Rule(title: "despacito", artist: nil, egg: Egg(flag: "🇵🇷", flagWords: ["despacito", "puerto"])),
        Rule(title: "jai ho", artist: nil, egg: Egg(ambient: .confetti, flag: "🇮🇳", flagWords: ["jai", "ho"])),
    ]

    /// Any edition counts: "(Live)", "[Acoustic]", "- Remastered 2023", "- Cover" and the like
    /// are dropped before comparing.
    private static let edition = try! NSRegularExpression(pattern: #"\s*[\(\[][^\)\]]*[\)\]]|\s+[-–—]\s+.*$"#)

    static func match(title: String, artist: String) -> Egg? {
        let bare = edition.stringByReplacingMatches(in: title, range: NSRange(title.startIndex..., in: title), withTemplate: "")
        let cleaned = TrackMatcher.normalize(TrackMatcher.cleanTitle(bare.isEmpty ? title : bare))
        let credit = TrackMatcher.normalize(artist)
        return rules.first { rule in
            guard cleaned == TrackMatcher.normalize(rule.title) else { return false }
            return rule.artist.map { credit.contains(TrackMatcher.normalize($0)) } ?? true
        }?.egg
    }
}
