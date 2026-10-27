import AppKit

/// How a word's icon moves while it's on screen.
enum IconMotion: String, Sendable, CaseIterable {
    /// A springy hop: things that jump, celebrate or arrive.
    case bounce
    /// Swells and fades like a heartbeat: love, light, feelings.
    case pulse
    /// Rocks side to side: playful things, weather, motion in place.
    case wiggle
    /// Slow, calm swelling: night, sleep, sky, water.
    case breathe
    /// Spins: wheels, records, time.
    case spin
    /// Drifts upward: things that fly, rise or float.
    case float
}

/// An SF Symbol for a lyric word, and how it moves.
struct WordIcon: Hashable, Sendable {
    var symbol: String
    var motion: IconMotion
}

/// Picks an SF Symbol for a sung word, from a vocabulary of everyday lyric words (OpenLyrics' own
/// selection). Words are matched case-insensitively without surrounding punctuation, and plural,
/// "-ing", "-ed" and "-in'" endings fall back to the base word ("dancing" → "dance",
/// "hearts" → "heart"). Symbols the running macOS doesn't have are dropped.
enum WordIcons {
    /// Shortest word considered. Sane range: 2–4.
    static let minimumLength = 3

    static func icon(for word: String) -> WordIcon? {
        for candidate in candidates(for: word) {
            if let icon = available[candidate] { return icon }
        }
        return nil
    }

    /// The word lowercased and trimmed, then with common endings removed, most specific first.
    static func candidates(for word: String) -> [String] {
        let lowered = word.lowercased().replacingOccurrences(of: "’", with: "'")
        let base = lowered.trimmingCharacters(in: CharacterSet.letters.inverted)
        guard base.count >= minimumLength else { return [] }
        var forms = [base]
        func add(_ form: String) {
            if form.count >= minimumLength, !forms.contains(form) { forms.append(form) }
        }
        // "dancin'" is "dancing": checked before the apostrophe is trimmed away.
        let withApostrophe = lowered.trimmingCharacters(in: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
        if withApostrophe.hasSuffix("in'") { add(base + "g") }
        if base.hasSuffix("ies") { add(String(base.dropLast(3)) + "y") }
        if base.hasSuffix("es") { add(String(base.dropLast(2))) }
        if base.hasSuffix("s"), !base.hasSuffix("ss") { add(String(base.dropLast())) }
        for form in forms where form.hasSuffix("ing") {
            let stem = String(form.dropLast(3))
            add(stem)
            add(stem + "e")
            if let last = stem.last, stem.count >= 2, stem.dropLast().last == last { add(String(stem.dropLast())) }
        }
        if base.hasSuffix("ed") {
            let stem = String(base.dropLast(2))
            add(stem)
            add(stem + "e")
            if let last = stem.last, stem.count >= 2, stem.dropLast().last == last { add(String(stem.dropLast())) }
        }
        if base.hasSuffix("d") { add(String(base.dropLast())) }
        return forms
    }

    /// The vocabulary, filtered to symbols this macOS has.
    private static let available: [String: WordIcon] = {
        var result: [String: WordIcon] = [:]
        for (words, symbol, motion) in vocabulary where NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
            for word in words.split(separator: " ") {
                result[String(word)] = WordIcon(symbol: symbol, motion: motion)
            }
        }
        return result
    }()

    /// Space-separated words, the symbol they share, and its motion.
    private static let vocabulary: [(String, String, IconMotion)] = [
        // Feelings
        ("love lover lovin heart hearts darling valentine", "heart.fill", .pulse),
        ("heartbreak heartbroken heartache", "heart.slash.fill", .wiggle),
        ("kiss kisses", "mouth.fill", .pulse),
        ("smile smiling laugh laughing happy", "face.smiling.inverse", .bounce),
        ("cry crying tears tear", "drop.fill", .float),
        ("hug hold embrace", "hands.and.sparkles.fill", .pulse),
        ("pray prayer praying amen", "hands.sparkles.fill", .breathe),
        ("soul spirit", "sparkles", .breathe),
        ("dream dreams dreaming", "cloud.fill", .breathe),
        ("sleep asleep bed", "bed.double.fill", .breathe),
        ("wake awake morning", "sunrise.fill", .float),
        // Light and sky
        ("sun sunny sunshine summer", "sun.max.fill", .spin),
        ("sunset dusk evening", "sunset.fill", .breathe),
        ("moon moonlight", "moon.fill", .breathe),
        ("night midnight tonight", "moon.stars.fill", .breathe),
        ("star stars starlight", "star.fill", .pulse),
        ("sky heaven heavens", "cloud.sun.fill", .float),
        ("light lights shine shining glow bright", "lightbulb.max.fill", .pulse),
        ("spark sparks sparkle magic", "sparkles", .pulse),
        ("rainbow", "rainbow", .breathe),
        // Weather and nature
        ("rain raining rainy", "cloud.rain.fill", .wiggle),
        ("storm thunder lightning", "cloud.bolt.rain.fill", .wiggle),
        ("snow snowing winter cold freeze frozen ice", "snowflake", .spin),
        ("wind windy breeze", "wind", .wiggle),
        ("fire flame flames burn burning hot", "flame.fill", .wiggle),
        ("water river", "drop.fill", .float),
        ("ocean sea wave waves tide beach", "water.waves", .wiggle),
        ("flower flowers rose roses bloom garden", "camera.macro", .breathe),
        ("tree trees forest", "tree.fill", .wiggle),
        ("leaf leaves autumn fall", "leaf.fill", .float),
        ("mountain mountains", "mountain.2.fill", .breathe),
        ("earth world planet globe", "globe.americas.fill", .spin),
        ("bird birds fly flying wings", "bird.fill", .float),
        ("butterfly butterflies", "sparkles", .float),
        ("cat kitty", "cat.fill", .bounce),
        ("dog puppy", "dog.fill", .bounce),
        // Places and travel
        ("home house", "house.fill", .bounce),
        ("city town street streets", "building.2.fill", .breathe),
        ("car cars drive driving ride road highway", "car.fill", .bounce),
        ("plane airplane flight", "airplane", .float),
        ("train", "tram.fill", .bounce),
        ("boat ship sail sailing", "sailboat.fill", .wiggle),
        ("bike", "bicycle", .bounce),
        ("run running runaway", "figure.run", .bounce),
        ("walk walking", "figure.walk", .bounce),
        ("map", "map.fill", .breathe),
        ("door", "door.left.hand.open", .bounce),
        ("key keys", "key.fill", .wiggle),
        // Music and party
        ("music song songs melody", "music.note", .bounce),
        ("sing singing voice", "music.mic", .pulse),
        ("dance dancing dancer floor", "figure.dance", .bounce),
        ("party celebrate celebration", "party.popper.fill", .bounce),
        ("radio", "radio.fill", .pulse),
        ("guitar", "guitars.fill", .wiggle),
        ("drum drums beat", "music.quarternote.3", .bounce),
        ("headphones", "headphones", .pulse),
        ("drink drinks drunk cheers", "wineglass.fill", .wiggle),
        ("champagne", "wineglass.fill", .wiggle),
        ("coffee", "cup.and.saucer.fill", .breathe),
        ("birthday cake", "birthday.cake.fill", .bounce),
        ("gift present", "gift.fill", .bounce),
        ("balloon balloons", "balloon.fill", .float),
        // Things
        ("money cash dollar dollars rich paid", "dollarsign.circle.fill", .spin),
        ("diamond diamonds", "diamond.fill", .pulse),
        ("gold golden", "medal.fill", .pulse),
        ("crown king queen royal", "crown.fill", .bounce),
        ("phone call calling", "phone.fill", .wiggle),
        ("text message", "message.fill", .bounce),
        ("letter mail", "envelope.fill", .bounce),
        ("camera picture photo photograph", "camera.fill", .pulse),
        ("book page pages", "book.fill", .breathe),
        ("time clock forever", "clock.fill", .spin),
        ("alarm", "alarm.fill", .wiggle),
        ("bell bells ring", "bell.fill", .wiggle),
        ("game play", "gamecontroller.fill", .bounce),
        ("ball", "basketball.fill", .bounce),
        ("trophy win winner champion", "trophy.fill", .bounce),
        ("rocket", "airplane.departure", .float),
        ("eye eyes look see watch", "eye.fill", .pulse),
        ("ear listen hear", "ear.fill", .pulse),
        ("hand hands", "hand.raised.fill", .wiggle),
        ("wave waving hello goodbye bye", "hand.wave.fill", .wiggle),
        ("brain mind think thinking", "brain.head.profile", .breathe),
        ("power electric energy", "bolt.fill", .pulse),
        ("battery", "battery.100percent", .pulse),
        ("lock locked", "lock.fill", .wiggle),
        ("bomb boom explode", "burst.fill", .bounce),
        ("crazy wild", "tornado", .spin),
        ("ghost", "theatermasks.fill", .float),
        ("mask masks", "theatermasks.fill", .wiggle),
    ]
}
