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

/// The picture for a lyric word — an SF Symbol, tinted with the highlight color, or an emoji in its
/// own colors — and how it moves.
struct WordIcon: Hashable, Sendable {
    /// An SF Symbol name, or the emoji itself when `isEmoji`.
    var symbol: String
    var motion: IconMotion
    var isEmoji = false
}

/// Picks a picture for a sung word from OpenLyrics' own vocabulary of everyday lyric words: people
/// and pronouns, feelings, talking, moving, time, weather, nature, animals, food, places, travel,
/// music, things and numbers. Words are matched case-insensitively without surrounding
/// punctuation; plural, "-ing", "-ed" and "-in'" forms fall back to the base word ("dancing" →
/// "dance", "hearts" → "heart"). SF Symbols the running macOS doesn't have are dropped.
enum WordIcons {
    /// Shortest word that can have an icon ("me", "we", "up"). Sane range: 2–4.
    static let minimumLength = 2
    /// Shortest form an ending may be stripped down to, so "uses" never becomes "us".
    static let minimumStemLength = 3

    static func icon(for word: String) -> WordIcon? {
        for candidate in candidates(for: word) {
            if let icon = available[candidate] { return icon }
        }
        return nil
    }

    /// How many words have an icon on this Mac (forms such as plurals not counted).
    static var vocabularySize: Int { available.count }

    /// The word lowercased and trimmed, then with common endings removed, most specific first.
    static func candidates(for word: String) -> [String] {
        let lowered = word.lowercased().replacingOccurrences(of: "’", with: "'")
        let base = lowered.trimmingCharacters(in: CharacterSet.letters.inverted)
        guard base.count >= minimumLength else { return [] }
        var forms = [base]
        func add(_ form: String) {
            if form.count >= minimumStemLength, !forms.contains(form) { forms.append(form) }
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
        for (words, glyph, motion) in vocabulary {
            let isEmoji = glyph.unicodeScalars.first.map { !$0.isASCII } ?? false
            guard isEmoji || NSImage(systemSymbolName: glyph, accessibilityDescription: nil) != nil else { continue }
            for word in words.split(separator: " ") {
                result[String(word)] = WordIcon(symbol: glyph, motion: motion, isEmoji: isEmoji)
            }
        }
        return result
    }()

    /// Space-separated words, the picture they share (an SF Symbol name or an emoji), and its motion.
    private static let vocabulary = WordIconVocabulary.entries
}
