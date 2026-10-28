import Foundation

/// NetEase Cloud Music's public web API (music.163.com), the source Verci uses. It has a large
/// catalog, including Western music, and word-timed "yrc" lyrics for many tracks, which give the
/// most precise word-by-word fill. It's an unofficial API: it may change without notice, so this
/// provider is one of several and fails soft.
///
/// Two requests: a search (`/api/search/get`), ranked by `TrackMatcher`, then the chosen song's
/// lyrics (`/api/song/lyric/v1`) with both `lrc` (line-timed) and `yrc` (word-timed).
struct NetEaseProvider: LyricsProvider {
    let id = LyricsProviderID.netease
    var baseURL = "https://music.163.com"
    /// Search results considered. Sane range: 5–20.
    var searchLimit = 10
    /// Matching uploads tried for lyrics, best first. Sane range: 1–6.
    var candidateLimit = 4

    /// The site serves its API to browsers; a browser-like agent and referer avoid odd replies.
    private static let headers = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        "Referer": "https://music.163.com/",
    ]

    struct SearchResponse: Decodable, Sendable {
        struct Result: Decodable, Sendable { var songs: [Song]? }
        var result: Result?
        var code: Int?
    }

    struct Song: Decodable, Sendable {
        struct Artist: Decodable, Sendable { var name: String? }
        var id: Int
        var name: String?
        var artists: [Artist]?
        /// Milliseconds.
        var duration: Double?
    }

    struct LyricResponse: Decodable, Sendable {
        struct Block: Decodable, Sendable { var lyric: String? }
        var lrc: Block?
        var yrc: Block?
        var nolyric: Bool?
        var uncollected: Bool?
        var pureMusic: Bool?
        var code: Int?
    }

    func lyrics(for query: TrackQuery) async throws(ProviderError) -> ProviderMatch? {
        let terms = "\(query.searchTitle) \(query.searchArtist)"
        guard let searchURL = HTTP.url("\(baseURL)/api/search/get", [
            ("s", terms), ("type", "1"), ("limit", String(searchLimit)), ("offset", "0"),
        ]) else { return nil }
        let (searchData, searchStatus) = try await HTTP.get(searchURL, headers: Self.headers)
        guard searchStatus == 200 else { throw .badResponse }
        guard let search = try? JSONDecoder().decode(SearchResponse.self, from: searchData) else { throw .badResponse }
        // The catalog often holds the same recording several times, and only some uploads have
        // lyrics attached: try the best matches in turn until one has synced lyrics.
        let ranked = Self.rankedSongs(in: search.result?.songs ?? [], for: query).prefix(candidateLimit)
        var fallback: ProviderMatch?
        for (song, confidence) in ranked {
            guard let lyrics = try await lyrics(forSong: song, query: query) else { continue }
            let match = ProviderMatch(lyrics: lyrics, confidence: confidence)
            if lyrics.isSynced { return match }
            if fallback == nil { fallback = match }
        }
        return fallback
    }

    private func lyrics(forSong song: Song, query: TrackQuery) async throws(ProviderError) -> Lyrics? {
        guard let lyricURL = HTTP.url("\(baseURL)/api/song/lyric/v1", [
            ("id", String(song.id)), ("cp", "false"), ("lv", "1"), ("kv", "0"), ("tv", "0"),
            ("rv", "0"), ("yv", "1"), ("ytv", "0"), ("yrv", "0"),
        ]) else { return nil }
        let (lyricData, lyricStatus) = try await HTTP.get(lyricURL, headers: Self.headers)
        guard lyricStatus == 200 else { throw .badResponse }
        guard let response = try? JSONDecoder().decode(LyricResponse.self, from: lyricData) else { throw .badResponse }
        let duration = query.duration ?? song.duration.map { $0 / 1000 }
        return Self.lyrics(from: response, duration: duration)
    }

    /// Matching songs, best first.
    static func rankedSongs(in songs: [Song], for query: TrackQuery) -> [(Song, Double)] {
        songs.compactMap { song -> (Song, Double)? in
            let candidate = TrackCandidate(
                title: song.name ?? "",
                artists: (song.artists ?? []).compactMap(\.name),
                duration: song.duration.map { $0 / 1000 }
            )
            return TrackMatcher.score(candidate, for: query).map { (song, $0) }
        }
        .sorted { $0.1 > $1.1 }
    }

    static func bestSong(in songs: [Song], for query: TrackQuery) -> (Song, Double)? {
        TrackMatcher.best(songs, for: query) { song in
            TrackCandidate(
                title: song.name ?? "",
                artists: (song.artists ?? []).compactMap(\.name),
                duration: song.duration.map { $0 / 1000 }
            )
        }
    }

    /// Word-timed yrc when present, else line-timed lrc; instrumental when NetEase says so.
    static func lyrics(from response: LyricResponse, duration: TimeInterval?) -> Lyrics? {
        let source = LyricsProviderID.netease.displayName
        let lrc = response.lrc?.lyric ?? ""
        if response.pureMusic == true || LyricsCleanup.isInstrumentalMarker(lrc) {
            return Lyrics(kind: .instrumental, lines: [], plainText: nil, source: source)
        }
        if let yrc = response.yrc?.lyric, let lyrics = YRCParser.parse(yrc, source: source, duration: duration) {
            return lyrics
        }
        if response.nolyric == true || response.uncollected == true { return nil }
        return LRCParser.parse(lrc, source: source, duration: duration)
    }
}
