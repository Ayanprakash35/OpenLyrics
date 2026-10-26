import Foundation

/// Word timing tuning, for lines whose source only times the line.
enum WordTimingConfig {
    /// Seconds of singing per unit of weight (one Latin letter). A typical sung line runs about ten
    /// letters a second. Sane range: 0.06–0.15.
    static let secondsPerUnit: TimeInterval = 0.1
    /// Weight of one character from a script written without spaces (Chinese, Japanese, Thai):
    /// each is about a syllable, so it takes longer to sing than a letter. Sane range: 2–4.
    static let spacelessCharacterWeight = 2.5
    /// Extra seconds a line takes beyond its letters (breath, held last note). Sane range: 0–1.
    static let lineLeadIn: TimeInterval = 0.4
    /// Shortest a line's singing is assumed to take, unless the line itself is shorter.
    /// Sane range: 0.3–1.
    static let minimumSinging: TimeInterval = 0.5
    /// Most of the line's slot the singing may fill, so the fill finishes just before the next
    /// line. Sane range: 0.85–1.
    static let maximumFill = 0.95
}

/// Splitting a line into words, and estimating when each word is sung.
enum WordTiming {
    /// Words of `text`, separated at whitespace. Characters of scripts written without spaces
    /// (Han, Hiragana, Katakana, Thai, Lao, Khmer, Myanmar) each become a word of their own, so a
    /// Chinese line fills character by character; runs of anything else stay together.
    static func tokenize(_ text: String) -> [LyricWord] {
        var words: [LyricWord] = []
        var current = ""

        func flush(spaceAfter: Bool) {
            if !current.isEmpty {
                words.append(LyricWord(text: current, start: 0, end: 0, spaceAfter: spaceAfter))
                current = ""
            } else if spaceAfter, !words.isEmpty {
                words[words.count - 1].spaceAfter = true
            }
        }

        for character in text {
            if character.isWhitespace {
                flush(spaceAfter: true)
            } else if isSpaceless(character) {
                flush(spaceAfter: false)
                words.append(LyricWord(text: String(character), start: 0, end: 0, spaceAfter: false))
            } else {
                current.append(character)
            }
        }
        flush(spaceAfter: false)
        if !words.isEmpty { words[words.count - 1].spaceAfter = false }
        return words
    }

    /// `words` with start and end times spread over the line, in proportion to their length, as
    /// fast as a line is typically sung but never past the next line.
    static func estimate(_ words: [LyricWord], start: TimeInterval, end: TimeInterval) -> [LyricWord] {
        guard !words.isEmpty else { return [] }
        let config = WordTimingConfig.self
        let weights = words.map(weight)
        let total = weights.reduce(0, +)
        let slot = max(end - start, 0)
        let natural = total * config.secondsPerUnit + config.lineLeadIn
        let singing = min(slot * config.maximumFill, max(natural, min(config.minimumSinging, slot)))

        var result: [LyricWord] = []
        result.reserveCapacity(words.count)
        var elapsed = 0.0
        for (word, weight) in zip(words, weights) {
            var timed = word
            timed.start = start + singing * elapsed / total
            elapsed += weight
            timed.end = start + singing * elapsed / total
            result.append(timed)
        }
        return result
    }

    private static func weight(of word: LyricWord) -> Double {
        let letters = word.text.reduce(0.0) { sum, character in
            sum + (isSpaceless(character) ? WordTimingConfig.spacelessCharacterWeight : 1)
        }
        // The space after a word takes a moment too.
        return max(letters, 1) + (word.spaceAfter ? 0.5 : 0)
    }

    static func isSpaceless(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, // Hiragana, Katakana
             0x3400...0x4DBF, // CJK Extension A
             0x4E00...0x9FFF, // CJK Unified Ideographs
             0xF900...0xFAFF, // CJK Compatibility Ideographs
             0x20000...0x2FA1F, // CJK Extensions B–F and supplements
             0x0E00...0x0EFF, // Thai, Lao
             0x1000...0x109F, // Myanmar
             0x1780...0x17FF: // Khmer
            return true
        default:
            return false
        }
    }
}
