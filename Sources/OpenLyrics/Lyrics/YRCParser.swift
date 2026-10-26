import Foundation

/// Parses NetEase's word-timed "yrc" lyrics:
///
///     [lineStartMs,lineDurationMs](wordStartMs,wordDurationMs,0)Word (…)next(…)word
///
/// Times are absolute milliseconds from the start of the track. A word's text runs to the next
/// timing mark; a trailing space means a space follows it. Lines that start with `{` are JSON
/// credits and are skipped, as are "作词 : …" style credit lines.
enum YRCParser {
    private static let wordMark = try! NSRegularExpression(pattern: #"\((\d+),(\d+),-?\d+\)"#)

    static func parse(_ text: String, source: String, duration: TimeInterval?) -> Lyrics? {
        var lines: [LyricLine] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let header = line[line.index(after: line.startIndex)..<close].split(separator: ",")
            guard header.count == 2, let startMs = Double(header[0]), let durationMs = Double(header[1]) else { continue }
            let body = String(line[line.index(after: close)...])
            let words = self.words(in: body)
            guard !words.isEmpty else { continue }
            let lineText = words.map(\.text).joined(separator: " ")
            if LyricsCleanup.isCredit(lineText) { continue }
            lines.append(LyricLine(
                start: startMs / 1000,
                end: (startMs + durationMs) / 1000,
                words: words,
                hasWordTiming: true
            ))
        }
        return Lyrics.synced(lines: lines, source: source, duration: duration)
    }

    static func words(in body: String) -> [LyricWord] {
        let nsBody = body as NSString
        let matches = wordMark.matches(in: body, range: NSRange(location: 0, length: nsBody.length))
        var words: [LyricWord] = []
        for (index, match) in matches.enumerated() {
            guard let start = Double(nsBody.substring(with: match.range(at: 1))),
                  let length = Double(nsBody.substring(with: match.range(at: 2))) else { continue }
            let textStart = match.range.location + match.range.length
            let textEnd = index + 1 < matches.count ? matches[index + 1].range.location : nsBody.length
            let raw = nsBody.substring(with: NSRange(location: textStart, length: textEnd - textStart))
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if raw.first?.isWhitespace == true, !words.isEmpty { words[words.count - 1].spaceAfter = true }
            guard !trimmed.isEmpty else { continue }
            words.append(LyricWord(
                text: trimmed,
                start: start / 1000,
                end: (start + length) / 1000,
                spaceAfter: raw.last?.isWhitespace == true
            ))
        }
        if !words.isEmpty { words[words.count - 1].spaceAfter = false }
        return words
    }
}
