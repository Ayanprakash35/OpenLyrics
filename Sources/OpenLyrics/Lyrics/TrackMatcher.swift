import Foundation

/// What a lyrics lookup searches for.
struct TrackQuery: Hashable, Sendable {
    var title: String
    var artist: String
    var album: String
    /// Seconds; nil when the player doesn't know.
    var duration: TimeInterval?

    /// The title without edition qualifiers, for searching and matching.
    var searchTitle: String { TrackMatcher.cleanTitle(title) }
    /// The first credited artist, for searching.
    var searchArtist: String { TrackMatcher.primaryArtist(artist) }
}

/// A search result a provider may take lyrics from.
struct TrackCandidate: Sendable {
    var title: String
    var artists: [String]
    var duration: TimeInterval?
}

/// Matching tuning.
enum TrackMatcherConfig {
    /// Lowest similarity, 0...1, a candidate's cleaned title may have to the track's.
    /// Sane range: 0.5–0.8.
    static let minTitleSimilarity = 0.6
    /// Lowest similarity of the best-matching pair of artists. Sane range: 0.3–0.7.
    static let minArtistSimilarity = 0.45
    /// Lengths within this many seconds count as the same recording. Sane range: 1–4.
    static let durationTolerance: TimeInterval = 3
    /// Lengths further apart than this are a different recording (a live or radio edit) whose
    /// timing wouldn't line up. Sane range: 8–20.
    static let maxDurationGap: TimeInterval = 12
}

/// Decides whether a search result is the track that's playing, and how confidently.
enum TrackMatcher {
    /// Qualifiers that name an edition of the same recording or credit a guest; removing them
    /// leaves the title a lyrics site files the song under. "Remix" and "Acoustic" are kept: they're
    /// different recordings with their own timing.
    private static let qualifier = try! NSRegularExpression(
        pattern: #"\s*[\(\[]\s*((\d{4}\s*)?(digital(ly)?\s*)?re-?master(ed)?|deluxe|bonus|explicit|clean|single|album|radio|mono|stereo|edit|version|anniversary|expanded|feat\.?|ft\.?|with |from |prod\.?)[^\)\]]*[\)\]]"#,
        options: [.caseInsensitive]
    )
    /// Spotify's " - Remastered 2011", " - Radio Edit", " - Single Version" suffixes.
    private static let dashQualifier = try! NSRegularExpression(
        pattern: #"\s+[-–—]\s+((\d{4}\s*)?(digital(ly)?\s*)?re-?master(ed)?.*|.*\b(edit|version|mono|stereo|mix)\b.*|live.*|from .*|feat\..*)$"#,
        options: [.caseInsensitive]
    )
    private static let featuring = try! NSRegularExpression(
        pattern: #"\s+(feat\.?|ft\.?|featuring)\s+.*$"#,
        options: [.caseInsensitive]
    )

    static func cleanTitle(_ title: String) -> String {
        var result = title
        for pattern in [qualifier, dashQualifier, featuring] {
            result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : trimmed
    }

    /// "Artist A, Artist B & C feat. D" → "Artist A".
    static func primaryArtist(_ artist: String) -> String {
        artists(in: artist).first ?? artist
    }

    static func artists(in credit: String) -> [String] {
        let separators = [",", "&", " feat. ", " feat ", " ft. ", " featuring ", " x ", " × ", " and ", " with ", "、", "/", ";"]
        var parts = [credit]
        for separator in separators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Lowercased, accents and punctuation removed, whitespace collapsed; "&" reads as "and".
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// 1 for equal strings, falling toward 0 as more edits separate them (normalized Levenshtein
    /// over characters). A string that contains the other whole scores at least 0.85.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(normalize(a)), y = Array(normalize(b))
        if x.isEmpty || y.isEmpty { return x.isEmpty && y.isEmpty ? 1 : 0 }
        if x == y { return 1 }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        let ratio = 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
        let shorter = x.count < y.count ? String(x) : String(y)
        let longer = x.count < y.count ? String(y) : String(x)
        if shorter.count >= 3, longer.contains(shorter) { return max(ratio, 0.85) }
        return ratio
    }

    /// How well `candidate` matches `query`, 0...1, or nil when it's clearly a different song or
    /// recording.
    static func score(_ candidate: TrackCandidate, for query: TrackQuery) -> Double? {
        let config = TrackMatcherConfig.self
        let titleScore = max(
            similarity(cleanTitle(candidate.title), query.searchTitle),
            similarity(candidate.title, query.title)
        )
        guard titleScore >= config.minTitleSimilarity else { return nil }

        let queryArtists = artists(in: query.artist)
        let artistScore = candidate.artists.flatMap { candidateArtist in
            queryArtists.map { similarity(candidateArtist, $0) }
        }.max() ?? 0
        guard artistScore >= config.minArtistSimilarity else { return nil }

        let durationScore: Double
        if let wanted = query.duration, let actual = candidate.duration {
            let gap = abs(wanted - actual)
            guard gap <= config.maxDurationGap else { return nil }
            durationScore = gap <= config.durationTolerance
                ? 1
                : 1 - (gap - config.durationTolerance) / (config.maxDurationGap - config.durationTolerance)
        } else {
            durationScore = 0.5
        }
        return 0.45 * titleScore + 0.3 * artistScore + 0.25 * durationScore
    }

    /// The best-scoring candidate and its score, if any matches.
    static func best<C>(_ candidates: [C], for query: TrackQuery, describe: (C) -> TrackCandidate) -> (C, Double)? {
        candidates
            .compactMap { candidate in score(describe(candidate), for: query).map { (candidate, $0) } }
            .max { $0.1 < $1.1 }
    }
}
