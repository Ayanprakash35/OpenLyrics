import Foundation

/// One word (or, in scripts written without spaces, one character) and when it's sung.
struct LyricWord: Codable, Hashable, Sendable {
    var text: String
    /// Seconds from the start of the track.
    var start: TimeInterval
    var end: TimeInterval
    /// Whether a space follows the word when the line is laid out.
    var spaceAfter: Bool

    /// How far through the word `time` is: 0 before it starts, 1 once it ends.
    func progress(at time: TimeInterval) -> Double {
        guard end > start else { return time >= start ? 1 : 0 }
        return min(max((time - start) / (end - start), 0), 1)
    }
}

/// One line of lyrics. A line with no words is a gap: an instrumental break between lines.
struct LyricLine: Codable, Hashable, Sendable {
    /// Seconds from the start of the track at which the line becomes current.
    var start: TimeInterval
    /// When the next line takes over (or the track ends).
    var end: TimeInterval
    var words: [LyricWord]
    /// Whether the word times came from the lyrics themselves rather than being estimated.
    var hasWordTiming: Bool

    var isGap: Bool { words.isEmpty }

    var text: String {
        words.map { $0.text + ($0.spaceAfter ? " " : "") }.joined().trimmingCharacters(in: .whitespaces)
    }
}

/// A track's lyrics, as one provider supplied them.
struct Lyrics: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Every word has its own timing.
        case wordSynced
        /// Lines are timed; word timing is estimated within each line.
        case lineSynced
        /// Text without timing: nothing to follow along with, so the overlay stays hidden.
        case unsynced
        /// The provider says the track has no vocals.
        case instrumental
    }

    var kind: Kind
    /// In time order, without overlaps. Empty unless `kind` is synced.
    var lines: [LyricLine]
    /// For `unsynced`: the text as supplied.
    var plainText: String?
    /// The provider's display name, such as "LRCLIB".
    var source: String

    var isSynced: Bool { kind == .wordSynced || kind == .lineSynced }

    /// The index of the line current at `time`: the last line starting at or before it. nil before
    /// the first line.
    func lineIndex(at time: TimeInterval) -> Int? {
        var low = 0, high = lines.count - 1, found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if lines[middle].start <= time {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }
}

/// Tuning shared by the parsers.
enum LyricsConfig {
    /// How long the last line stays current when the track's length isn't known, in seconds.
    /// Sane range: 4–10.
    static let lastLineHold: TimeInterval = 6
    /// A pause between lines at least this long, in seconds, gets a gap line, so the overlay shows
    /// the break rather than holding the previous line through it. Sane range: 4–12.
    static let minGap: TimeInterval = 6
    /// Lines whose text is only these characters are breaks, not lyrics ("♪", "...").
    static let breakCharacters = CharacterSet(charactersIn: "♪♫♬♩…·•.-–—~ ").union(.whitespaces)
}

extension Lyrics {
    /// Builds synced lyrics from timed lines in any order: sorts them, gives each line its end,
    /// turns long pauses and "♪"-only lines into gaps, and estimates word timing where the source
    /// had none.
    static func synced(lines raw: [LyricLine], source: String, duration: TimeInterval?) -> Lyrics? {
        let sorted = raw.sorted { $0.start < $1.start }
        guard sorted.contains(where: { !$0.isGap }) else { return nil }

        var lines: [LyricLine] = []
        for (index, line) in sorted.enumerated() {
            let nextStart = index + 1 < sorted.count ? sorted[index + 1].start : nil
            var line = line
            if line.words.allSatisfy({ $0.text.unicodeScalars.allSatisfy(LyricsConfig.breakCharacters.contains) }) {
                line.words = []
                line.hasWordTiming = false
            }
            let end = nextStart ?? max(line.end, duration ?? (line.start + LyricsConfig.lastLineHold))
            line.end = max(end, line.start)
            if !line.isGap, !line.hasWordTiming {
                line.words = WordTiming.estimate(line.words, start: line.start, end: line.end)
            }
            // A long pause after the line's last word is a gap. Estimated word times are a guess,
            // so those lines need a longer pause before one is split off.
            let gapThreshold = line.hasWordTiming ? LyricsConfig.minGap : LyricsConfig.minGap * 1.75
            if !line.isGap, let sungUntil = line.words.last?.end, line.end - sungUntil >= gapThreshold {
                lines.append(LyricLine(start: line.start, end: sungUntil, words: line.words, hasWordTiming: line.hasWordTiming))
                lines.append(LyricLine(start: sungUntil, end: line.end, words: [], hasWordTiming: false))
                continue
            }
            // Merge consecutive gaps so a break shows as one.
            if line.isGap, let last = lines.last, last.isGap {
                lines[lines.count - 1].end = line.end
                continue
            }
            lines.append(line)
        }
        // A track that opens with a long intro gets a gap before its first line.
        if let first = lines.first, first.start >= LyricsConfig.minGap {
            lines.insert(LyricLine(start: 0, end: first.start, words: [], hasWordTiming: false), at: 0)
        }
        let wordTimed = lines.contains { $0.hasWordTiming && !$0.isGap }
        return Lyrics(kind: wordTimed ? .wordSynced : .lineSynced, lines: lines, plainText: nil, source: source)
    }
}
