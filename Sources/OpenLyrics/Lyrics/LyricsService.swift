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

/// Lookup tuning.
enum LyricsServiceConfig {
    /// A match ranked at least this high (`LyricsService.rank`) is taken the moment it arrives,
    /// without waiting for slower providers. 1.12 means a word-timed match of confidence 0.97 or
    /// more: nothing another provider could send would show better. Sane range: 1.05–1.15.
    static let decisiveRank = 1.12
    /// Seconds to keep waiting for a better answer once a synced match is in. Sane range: 0.5–3.
    static let gracePeriod: TimeInterval = 1.5
    /// Seconds a provider that couldn't be reached is left out of lookups, so a blocked or down
    /// service doesn't hold every song up until it times out. Sane range: 60–1800.
    static let unreachableCooldown: TimeInterval = 300
}

/// Finds a track's lyrics: asks every enabled provider at once and keeps the best answer, ranked by
/// how well the provider's track matched plus how precisely its lyrics are timed. Answers are
/// cached on disk, so replaying a song never goes to the network.
///
/// The lookup doesn't wait for the slowest provider: a decisive match ends it at once, and any
/// synced match ends it `gracePeriod` later. A provider that couldn't be reached sits out for
/// `unreachableCooldown` (unless every enabled provider is sitting out).
actor LyricsService {
    private let logger = Logger(subsystem: "com.openlyrics.app", category: "Lyrics")
    private let providers: [any LyricsProvider]
    private let cache: LyricsCache?
    private let decisiveRank: Double
    private let gracePeriod: TimeInterval
    private let unreachableCooldown: TimeInterval
    private let now: @Sendable () -> Date
    /// When each provider that recently failed may be asked again.
    private var sittingOutUntil: [LyricsProviderID: Date] = [:]

    init(
        providers: [any LyricsProvider] = [LRCLibProvider(), NetEaseProvider()],
        cache: LyricsCache? = .standard,
        decisiveRank: Double = LyricsServiceConfig.decisiveRank,
        gracePeriod: TimeInterval = LyricsServiceConfig.gracePeriod,
        unreachableCooldown: TimeInterval = LyricsServiceConfig.unreachableCooldown,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.providers = providers
        self.cache = cache
        self.decisiveRank = decisiveRank
        self.gracePeriod = gracePeriod
        self.unreachableCooldown = unreachableCooldown
        self.now = now
    }

    /// How one provider's request ended.
    private enum Outcome: Sendable {
        case answered(ProviderMatch?)
        case unreachable
        /// Stopped because the lookup had already decided.
        case cancelled
    }

    private enum Event: Sendable {
        case provider(LyricsProviderID, Outcome)
        case graceOver
    }

    func lookup(_ query: TrackQuery, using enabled: Set<LyricsProviderID>, bypassCache: Bool = false) async -> LyricsLookup {
        let key = LyricsCache.key(for: query)
        if !bypassCache, let cached = cache?.load(key) {
            logger.debug("Lyrics from cache")
            return cached
        }
        let enabledProviders = providers.filter { enabled.contains($0.id) }
        guard !enabledProviders.isEmpty else { return .notFound }
        let started = now()
        let available = enabledProviders.filter { (sittingOutUntil[$0.id] ?? .distantPast) <= started }
        // With everything sitting out, ask anyway rather than give up.
        let active = available.isEmpty ? enabledProviders : available
        for skipped in enabledProviders where !active.contains(where: { $0.id == skipped.id }) {
            logger.info("\(skipped.id.displayName, privacy: .public): skipped, unreachable recently")
        }

        var matches: [ProviderMatch] = []
        var answeredIDs: [LyricsProviderID] = []
        var unreachable: [LyricsProviderID] = []
        let decisiveRank = self.decisiveRank
        let gracePeriod = self.gracePeriod
        await withTaskGroup(of: Event.self) { group in
            for provider in active {
                group.addTask {
                    do {
                        return .provider(provider.id, .answered(try await provider.lyrics(for: query)))
                    } catch {
                        return .provider(provider.id, Task.isCancelled ? .cancelled : .unreachable)
                    }
                }
            }
            var pending = active.count
            var graceStarted = false
            events: while let event = await group.next() {
                switch event {
                case .graceOver:
                    logger.debug("Grace period over; not waiting for \(pending, privacy: .public) more")
                    break events
                case .provider(let id, let outcome):
                    pending -= 1
                    switch outcome {
                    case .answered(let match):
                        answeredIDs.append(id)
                        if let match { matches.append(match) }
                        let description = match.map { "\($0.lyrics.kind.rawValue), confidence \(String(format: "%.2f", $0.confidence))" } ?? "nothing"
                        logger.info("\(id.displayName, privacy: .public): \(description, privacy: .public)")
                        if let match, Self.rank(match) >= decisiveRank { break events }
                        if let match, match.lyrics.isSynced, !graceStarted, pending > 0 {
                            graceStarted = true
                            group.addTask {
                                try? await Task.sleep(for: .seconds(gracePeriod))
                                return .graceOver
                            }
                        }
                    case .unreachable:
                        unreachable.append(id)
                        logger.info("\(id.displayName, privacy: .public): unreachable")
                    case .cancelled:
                        break
                    }
                    if pending == 0 { break events }
                }
            }
            // Providers still running (and the grace timer) are no longer needed.
            group.cancelAll()
        }

        let finished = now()
        for id in unreachable { sittingOutUntil[id] = finished.addingTimeInterval(unreachableCooldown) }
        for id in answeredIDs { sittingOutUntil[id] = nil }

        let result: LyricsLookup
        if let best = matches.max(by: { Self.rank($0) < Self.rank($1) }) {
            result = .found(best.lyrics)
        } else {
            result = answeredIDs.isEmpty ? .unavailable : .notFound
        }
        // "Not found" is only remembered when every enabled provider said so: one that was skipped,
        // couldn't be reached or wasn't waited for might have the lyrics next time.
        if case .found = result {
            cache?.store(result, for: key)
        } else if result == .notFound, answeredIDs.count == enabledProviders.count {
            cache?.store(result, for: key)
        }
        logger.info("Lookup took \(String(format: "%.1f", finished.timeIntervalSince(started)), privacy: .public) s")
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
