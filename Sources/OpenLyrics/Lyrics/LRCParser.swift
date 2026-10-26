import Foundation

/// Parses LRC: `[mm:ss.xx]text` lines, several timestamps per line, `[offset:±ms]`, metadata tags,
/// and enhanced LRC's per-word `<mm:ss.xx>` tags. Also skips what NetEase mixes in: JSON credit
/// lines and "作词 : …" style credits.
enum LRCParser {
    static func parse(_ text: String, source: String, duration: TimeInterval?) -> Lyrics? {
        let rawLines = text.components(separatedBy: .newlines)
        let offset = rawLines.lazy.compactMap(offsetTag).first ?? 0

        var timed: [LyricLine] = []
        var plain: [String] = []
        for rawLine in rawLines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("{") else { continue }
            let (times, rest) = leadingTimestamps(line)
            if times.isEmpty {
                // A metadata tag such as [ar:…] or [offset:…], or a plain lyric line.
                if !(line.hasPrefix("[") && line.hasSuffix("]")) { plain.append(line) }
                continue
            }
            let body = rest.trimmingCharacters(in: .whitespaces)
            if LyricsCleanup.isCredit(body) { continue }
            for time in times {
                let start = max(0, time - offset)
                if let enhanced = enhancedWords(body, offset: offset) {
                    timed.append(LyricLine(start: start, end: start, words: enhanced, hasWordTiming: true))
                } else {
                    timed.append(LyricLine(start: start, end: start, words: WordTiming.tokenize(body), hasWordTiming: false))
                }
            }
        }

        if let lyrics = Lyrics.synced(lines: timed, source: source, duration: duration) {
            return lyrics
        }
        let unsynced = plain.filter { !LyricsCleanup.isCredit($0) }
        guard !unsynced.isEmpty else { return nil }
        return Lyrics(kind: .unsynced, lines: [], plainText: unsynced.joined(separator: "\n"), source: source)
    }

    /// The timestamps at the start of `line` and the text after them.
    static func leadingTimestamps(_ line: String) -> ([TimeInterval], Substring) {
        var times: [TimeInterval] = []
        var rest = Substring(line)
        while rest.first == "[", let close = rest.firstIndex(of: "]") {
            guard let time = timestamp(rest[rest.index(after: rest.startIndex)..<close]) else { break }
            times.append(time)
            rest = rest[rest.index(after: close)...]
        }
        return (times, rest)
    }

    /// `mm:ss`, `mm:ss.x`, `mm:ss.xx`, `mm:ss.xxx`, `mm:ss:xx` (fraction after a colon, a common
    /// variant) and `h:mm:ss.xx`. nil for anything else, including metadata tags like `ar:Name`.
    static func timestamp(_ text: Substring) -> TimeInterval? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        let minuteFields: [String]
        let secondsText: String
        let fractionText: String?
        if parts.count == 3, !parts[2].contains(".") {
            // Three fields and no dot: read as mm:ss:xx rather than h:mm:ss.
            minuteFields = [parts[0]]
            secondsText = parts[1]
            fractionText = parts[2]
        } else {
            minuteFields = Array(parts.dropLast())
            let seconds = parts[parts.count - 1].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            secondsText = String(seconds[0])
            fractionText = seconds.count == 2 ? String(seconds[1]) : nil
        }
        func isDigits(_ field: String, upTo length: Int) -> Bool {
            !field.isEmpty && field.count <= length && field.allSatisfy { $0.isASCII && $0.isNumber }
        }
        guard isDigits(secondsText, upTo: 2), let seconds = Int(secondsText), seconds < 60 else { return nil }
        var total = Double(seconds)
        if let fractionText {
            guard isDigits(fractionText, upTo: 3), let fraction = Double("0." + fractionText) else { return nil }
            total += fraction
        }
        var multiplier = 60.0
        for field in minuteFields.reversed() {
            guard isDigits(field, upTo: 3), let value = Int(field) else { return nil }
            total += Double(value) * multiplier
            multiplier *= 60
        }
        return total
    }

    /// `[offset:+250]` in milliseconds. A positive offset shows lyrics sooner.
    static func offsetTag(_ line: String) -> TimeInterval? {
        let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.hasPrefix("[offset:"), trimmed.hasSuffix("]") else { return nil }
        let value = trimmed.dropFirst("[offset:".count).dropLast().trimmingCharacters(in: .whitespaces)
        guard let milliseconds = Double(value.replacingOccurrences(of: "+", with: "")) else { return nil }
        return milliseconds / 1000
    }

    /// Enhanced LRC: `<00:12.00>Word <00:12.40>by <00:12.70>word<00:13.20>`. nil when the line has
    /// no word tags. A word ends where the next tag starts; the last word ends at a trailing tag if
    /// there is one, and otherwise when the line does.
    static func enhancedWords(_ body: String, offset: TimeInterval) -> [LyricWord]? {
        guard body.contains("<") else { return nil }
        var marks: [(time: TimeInterval, text: String)] = []
        var rest = Substring(body)
        var leading = ""
        while let open = rest.firstIndex(of: "<") {
            guard let close = rest[open...].firstIndex(of: ">"),
                  let time = timestamp(rest[rest.index(after: open)..<close]) else { return nil }
            let before = String(rest[..<open])
            if marks.isEmpty { leading += before } else { marks[marks.count - 1].text += before }
            marks.append((max(0, time - offset), ""))
            rest = rest[rest.index(after: close)...]
        }
        guard !marks.isEmpty else { return nil }
        marks[marks.count - 1].text += rest
        if !leading.trimmingCharacters(in: .whitespaces).isEmpty {
            marks[0].text = leading + marks[0].text
        }

        var words: [LyricWord] = []
        for (index, mark) in marks.enumerated() {
            let trimmed = mark.text.trimmingCharacters(in: .whitespaces)
            let end = index + 1 < marks.count ? marks[index + 1].time : mark.time
            if trimmed.isEmpty {
                // A trailing tag (or a tag before a space) only marks where the previous word ends.
                if !words.isEmpty, mark.text.contains(" ") { words[words.count - 1].spaceAfter = true }
                continue
            }
            // Spaceless scripts may tag several characters at once; they still share the tag's span.
            words.append(LyricWord(text: trimmed, start: mark.time, end: max(end, mark.time), spaceAfter: mark.text.hasSuffix(" ")))
        }
        guard !words.isEmpty else { return nil }
        // An untagged end on the last word: give it a typical length rather than zero.
        if let last = words.last, last.end <= last.start {
            words[words.count - 1].end = last.start + max(0.3, Double(last.text.count) * WordTimingConfig.secondsPerUnit)
        }
        words[words.count - 1].spaceAfter = false
        return words
    }
}

/// Lines providers mix into lyrics that aren't lyrics.
enum LyricsCleanup {
    private static let creditPattern = try! NSRegularExpression(
        pattern: #"^\s*(作词|作詞|作曲|编曲|編曲|制作人|製作人|制作|製作|混音|母带|母帶|和声|和聲|吉他|贝斯|貝斯|鼓|弦乐|弦樂|录音|錄音|监制|監製|出品|发行|發行|词|詞|曲|OP|SP|lyrics?( by)?|lyricists?|written by|writers?|composers?|composed by|music( by)?|producers?|produced by|arrangers?|arranged by|mix(ed|ing)?( by)?|master(ed|ing)?( by)?|vocals? by)\s*[:：]"#,
        options: [.caseInsensitive]
    )
    /// NetEase's marker for a track it knows is instrumental ("pure music, please enjoy").
    static let instrumentalMarkers = ["纯音乐，请欣赏", "纯音乐,请欣赏", "此歌曲为没有填词的纯音乐"]

    static func isCredit(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return creditPattern.firstMatch(in: text, range: range) != nil
    }

    static func isInstrumentalMarker(_ text: String) -> Bool {
        instrumentalMarkers.contains { text.contains($0) }
    }
}
