import CryptoKit
import Foundation
import os

/// The outcome of looking a track's lyrics up.
enum LyricsLookup: Equatable, Sendable {
    case found(Lyrics)
    /// Every provider answered, and none has lyrics for the track.
    case notFound
    /// No provider could be reached; worth trying again later.
    case unavailable
}

/// Finds a track's lyrics: asks every enabled provider at once and keeps the best answer, ranked by
/// how well the provider's track matched plus how precisely its lyrics are timed. Answers are
/// cached on disk, so replaying a song never goes to the network.
actor LyricsService {
    private let logger = Logger(subsystem: "com.openlyrics.app", category: "Lyrics")
    private let providers: [any LyricsProvider]
    private let cache: LyricsCache?

    init(providers: [any LyricsProvider] = [LRCLibProvider(), NetEaseProvider()], cache: LyricsCache? = .standard) {
        self.providers = providers
        self.cache = cache
    }

    func lookup(_ query: TrackQuery, using enabled: Set<LyricsProviderID>, bypassCache: Bool = false) async -> LyricsLookup {
        let key = LyricsCache.key(for: query)
        if !bypassCache, let cached = cache?.load(key) {
            logger.debug("Lyrics from cache")
            return cached
        }
        let active = providers.filter { enabled.contains($0.id) }
        guard !active.isEmpty else { return .notFound }

        var matches: [ProviderMatch] = []
        var answered = 0
        await withTaskGroup(of: (LyricsProviderID, ProviderMatch?, Bool).self) { group in
            for provider in active {
                group.addTask {
                    do {
                        return (provider.id, try await provider.lyrics(for: query), true)
                    } catch {
                        return (provider.id, nil, false)
                    }
                }
            }
            for await (id, match, didAnswer) in group {
                if didAnswer { answered += 1 }
                if let match { matches.append(match) }
                let outcome = match.map { "\($0.lyrics.kind.rawValue), confidence \(String(format: "%.2f", $0.confidence))" }
                    ?? (didAnswer ? "nothing" : "unreachable")
                logger.info("\(id.displayName, privacy: .public): \(outcome, privacy: .public)")
            }
        }

        let result: LyricsLookup
        if let best = matches.max(by: { Self.rank($0) < Self.rank($1) }) {
            result = .found(best.lyrics)
        } else {
            result = answered > 0 ? .notFound : .unavailable
        }
        // "Not found" is only remembered when every provider said so: one that couldn't be
        // reached might have the lyrics next time.
        if case .found = result {
            cache?.store(result, for: key)
        } else if result == .notFound, answered == active.count {
            cache?.store(result, for: key)
        }
        return result
    }

    func clearCache() {
        cache?.clear()
    }

    static func rank(_ match: ProviderMatch) -> Double {
        match.confidence + qualityBonus(match.lyrics.kind)
    }

    /// Ranks precise timing above a slightly better title match: word timing beats line timing,
    /// and text without timing is a last resort, since the overlay can't follow it.
    static func qualityBonus(_ kind: Lyrics.Kind) -> Double {
        switch kind {
        case .wordSynced: 0.15
        case .lineSynced: 0.1
        case .instrumental: 0.05
        case .unsynced: -0.2
        }
    }
}

/// Lookup results on disk, one small JSON file per track, in the user's Caches folder.
struct LyricsCache: Sendable {
    /// Days a "not found" answer is trusted before asking again. Sane range: 1–14.
    static let notFoundLifetimeDays = 3.0
    /// Days found lyrics are kept. Sane range: 30–365.
    static let foundLifetimeDays = 120.0
    /// Bumped whenever the stored format or the parsers change, so stale entries are ignored.
    static let formatVersion = 1

    let directory: URL

    static var standard: LyricsCache? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return LyricsCache(directory: caches.appending(path: "com.openlyrics.app/lyrics", directoryHint: .isDirectory))
    }

    private struct Entry: Codable {
        var version: Int
        var savedAt: Date
        var lyrics: Lyrics?
    }

    /// The same track from Music and Spotify maps to one key: cleaned artist and title, and the
    /// length in 2-second steps (the two players round differently).
    static func key(for query: TrackQuery) -> String {
        let length = query.duration.map { String(Int(($0 / 2).rounded())) } ?? "?"
        let signature = [
            TrackMatcher.normalize(query.searchArtist), TrackMatcher.normalize(query.searchTitle), length,
        ].joined(separator: "|")
        return SHA256.hash(data: Data(signature.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func load(_ key: String, now: Date = Date()) -> LyricsLookup? {
        guard let data = try? Data(contentsOf: file(for: key)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.version == Self.formatVersion else { return nil }
        let lifetime = (entry.lyrics == nil ? Self.notFoundLifetimeDays : Self.foundLifetimeDays) * 86_400
        guard now.timeIntervalSince(entry.savedAt) < lifetime else { return nil }
        return entry.lyrics.map(LyricsLookup.found) ?? .notFound
    }

    func store(_ lookup: LyricsLookup, for key: String, now: Date = Date()) {
        let lyrics: Lyrics?
        switch lookup {
        case .found(let found): lyrics = found
        case .notFound: lyrics = nil
        case .unavailable: return
        }
        guard let data = try? JSONEncoder().encode(Entry(version: Self.formatVersion, savedAt: now, lyrics: lyrics)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(for: key), options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(for key: String) -> URL {
        directory.appending(path: "\(key).json", directoryHint: .notDirectory)
    }
}
