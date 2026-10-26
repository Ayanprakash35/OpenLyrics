import Foundation

/// LRCLIB (lrclib.net): an open, crowd-sourced lyrics database with line-synced LRC, free to use
/// without a key. It asks clients to send a descriptive User-Agent.
///
/// `/api/get` looks a track up by its exact signature (title, artist, album, length) and returns
/// 404 when there's no such entry; `/api/search` then finds near matches, ranked here by
/// `TrackMatcher`.
struct LRCLibProvider: LyricsProvider {
    let id = LyricsProviderID.lrclib
    var baseURL = "https://lrclib.net"

    struct Record: Decodable, Sendable {
        var trackName: String?
        var artistName: String?
        var albumName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    func lyrics(for query: TrackQuery) async throws(ProviderError) -> ProviderMatch? {
        let headers = ["User-Agent": LyricsNetworkConfig.userAgent]
        if let duration = query.duration,
           let url = HTTP.url("\(baseURL)/api/get", [
               ("track_name", query.title), ("artist_name", query.artist),
               ("album_name", query.album.isEmpty ? nil : query.album), ("duration", String(Int(duration.rounded()))),
           ]) {
            let (data, status) = try await HTTP.get(url, headers: headers)
            if status == 200, let record = try? JSONDecoder().decode(Record.self, from: data),
               let match = Self.match(record, for: query) {
                return match
            }
        }

        guard let url = HTTP.url("\(baseURL)/api/search", [
            ("track_name", query.searchTitle), ("artist_name", query.searchArtist),
        ]) else { return nil }
        let (data, status) = try await HTTP.get(url, headers: headers)
        if status == 404 { return nil }
        guard status == 200 else { throw .badResponse }
        guard let records = try? JSONDecoder().decode([Record].self, from: data) else { throw .badResponse }
        return Self.bestMatch(in: records, for: query)
    }

    /// The best search result that has lyrics, preferring synced ones.
    static func bestMatch(in records: [Record], for query: TrackQuery) -> ProviderMatch? {
        records.compactMap { match($0, for: query) }.max { rank($0) < rank($1) }
    }

    static func match(_ record: Record, for query: TrackQuery) -> ProviderMatch? {
        let candidate = TrackCandidate(
            title: record.trackName ?? "",
            artists: TrackMatcher.artists(in: record.artistName ?? ""),
            duration: record.duration
        )
        guard let confidence = TrackMatcher.score(candidate, for: query) else { return nil }
        let source = LyricsProviderID.lrclib.displayName
        if record.instrumental == true {
            return ProviderMatch(lyrics: Lyrics(kind: .instrumental, lines: [], plainText: nil, source: source), confidence: confidence)
        }
        if let synced = record.syncedLyrics, let lyrics = LRCParser.parse(synced, source: source, duration: query.duration ?? record.duration) {
            return ProviderMatch(lyrics: lyrics, confidence: confidence)
        }
        if let plain = record.plainLyrics, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ProviderMatch(lyrics: Lyrics(kind: .unsynced, lines: [], plainText: plain, source: source), confidence: confidence)
        }
        return nil
    }

    private static func rank(_ match: ProviderMatch) -> Double {
        match.confidence + LyricsService.qualityBonus(match.lyrics.kind)
    }
}
