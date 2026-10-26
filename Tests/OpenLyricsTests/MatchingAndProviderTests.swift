import Foundation
import Testing
@testable import OpenLyrics

@Suite("Track matching")
struct TrackMatcherTests {
    @Test(arguments: [
        ("Harbor Lights - Remastered 2011", "Harbor Lights"),
        ("Harbor Lights (2011 Remaster)", "Harbor Lights"),
        ("Harbor Lights (feat. Someone)", "Harbor Lights"),
        ("Harbor Lights - Radio Edit", "Harbor Lights"),
        ("Harbor Lights [Deluxe Edition]", "Harbor Lights"),
        ("Harbor Lights - Live at Somewhere", "Harbor Lights"),
        ("Harbor Lights (Remix)", "Harbor Lights (Remix)"),
        ("Harbor Lights - Acoustic", "Harbor Lights - Acoustic"),
    ])
    func cleansTitles(title: String, expected: String) {
        #expect(TrackMatcher.cleanTitle(title) == expected)
    }

    @Test func splitsArtistCredits() {
        #expect(TrackMatcher.artists(in: "Ana, Ben & Cleo feat. Dee") == ["Ana", "Ben", "Cleo", "Dee"])
        #expect(TrackMatcher.primaryArtist("Ana x Ben") == "Ana")
    }

    @Test func normalizes() {
        #expect(TrackMatcher.normalize("Beyoncé & Co.!") == "beyonce and co")
    }

    @Test func similarity() {
        #expect(TrackMatcher.similarity("Harbor Lights", "harbor lights") == 1)
        #expect(TrackMatcher.similarity("Harbor Lights", "Harbour Lights") > 0.85)
        #expect(TrackMatcher.similarity("Harbor Lights", "Paper Planes") < 0.5)
    }

    private let query = TrackQuery(title: "Harbor Lights - Remastered", artist: "The Tides, Mo", album: "Coast", duration: 200)

    @Test func scoresTheRightRecordingHighest() throws {
        let exact = try #require(TrackMatcher.score(TrackCandidate(title: "Harbor Lights", artists: ["The Tides"], duration: 201), for: query))
        let longer = try #require(TrackMatcher.score(TrackCandidate(title: "Harbor Lights", artists: ["The Tides"], duration: 208), for: query))
        #expect(exact > longer)
    }

    @Test func rejectsOtherSongsArtistsAndRecordings() {
        #expect(TrackMatcher.score(TrackCandidate(title: "Paper Planes", artists: ["The Tides"], duration: 200), for: query) == nil)
        #expect(TrackMatcher.score(TrackCandidate(title: "Harbor Lights", artists: ["Somebody Else"], duration: 200), for: query) == nil)
        #expect(TrackMatcher.score(TrackCandidate(title: "Harbor Lights", artists: ["The Tides"], duration: 260), for: query) == nil)
    }

    @Test func matchesAFeaturedArtist() {
        #expect(TrackMatcher.score(TrackCandidate(title: "Harbor Lights", artists: ["Mo"], duration: 200), for: query) != nil)
    }
}

@Suite("Providers: reading replies")
struct ProviderReplyTests {
    private let query = TrackQuery(title: "Harbor Lights", artist: "The Tides", album: "Coast", duration: 200)

    @Test func lrclibPrefersSyncedResults() throws {
        let json = """
        [
          {"trackName":"Harbor Lights","artistName":"The Tides","duration":200,"instrumental":false,
           "plainLyrics":"waves on the wall","syncedLyrics":null},
          {"trackName":"Harbor Lights","artistName":"The Tides","duration":199,"instrumental":false,
           "plainLyrics":"waves on the wall","syncedLyrics":"[00:01.00]waves on the wall\\n[00:04.00]tides in the hall"},
          {"trackName":"Other Song","artistName":"The Tides","duration":200,"instrumental":false,
           "syncedLyrics":"[00:01.00]wrong song"}
        ]
        """
        let records = try JSONDecoder().decode([LRCLibProvider.Record].self, from: Data(json.utf8))
        let match = try #require(LRCLibProvider.bestMatch(in: records, for: query))
        #expect(match.lyrics.kind == .lineSynced)
        #expect(match.lyrics.lines.first?.text == "waves on the wall")
        #expect(match.lyrics.source == "LRCLIB")
    }

    @Test func lrclibInstrumental() throws {
        let json = #"{"trackName":"Harbor Lights","artistName":"The Tides","duration":200,"instrumental":true}"#
        let record = try JSONDecoder().decode(LRCLibProvider.Record.self, from: Data(json.utf8))
        #expect(LRCLibProvider.match(record, for: query)?.lyrics.kind == .instrumental)
    }

    @Test func netEasePicksTheMatchingSong() throws {
        let json = """
        {"result":{"songs":[
          {"id":1,"name":"Harbor Lights (Live)","artists":[{"name":"The Tides"}],"duration":260000},
          {"id":2,"name":"Harbor Lights","artists":[{"name":"The Tides"}],"duration":200400},
          {"id":3,"name":"Harbor Lights","artists":[{"name":"Cover Band"}],"duration":200000}
        ]},"code":200}
        """
        let search = try JSONDecoder().decode(NetEaseProvider.SearchResponse.self, from: Data(json.utf8))
        let (song, _) = try #require(NetEaseProvider.bestSong(in: search.result?.songs ?? [], for: query))
        #expect(song.id == 2)
    }

    @Test func netEasePrefersWordTimedLyrics() throws {
        let json = """
        {"lrc":{"lyric":"[00:01.00]waves on the wall"},
         "yrc":{"lyric":"[1000,2000](1000,1000,0)waves (2000,1000,0)on"},"code":200}
        """
        let reply = try JSONDecoder().decode(NetEaseProvider.LyricResponse.self, from: Data(json.utf8))
        let lyrics = try #require(NetEaseProvider.lyrics(from: reply, duration: 200))
        #expect(lyrics.kind == .wordSynced)
    }

    @Test func netEaseFallsBackToLineTiming() throws {
        let json = #"{"lrc":{"lyric":"[00:01.00]waves on the wall"},"code":200}"#
        let reply = try JSONDecoder().decode(NetEaseProvider.LyricResponse.self, from: Data(json.utf8))
        #expect(NetEaseProvider.lyrics(from: reply, duration: 200)?.kind == .lineSynced)
    }

    @Test func netEaseInstrumentalMarker() throws {
        let json = #"{"lrc":{"lyric":"[00:00.00]纯音乐，请欣赏"},"code":200}"#
        let reply = try JSONDecoder().decode(NetEaseProvider.LyricResponse.self, from: Data(json.utf8))
        #expect(NetEaseProvider.lyrics(from: reply, duration: 200)?.kind == .instrumental)
    }

    @Test func netEaseNoLyrics() throws {
        let json = #"{"nolyric":true,"code":200}"#
        let reply = try JSONDecoder().decode(NetEaseProvider.LyricResponse.self, from: Data(json.utf8))
        #expect(NetEaseProvider.lyrics(from: reply, duration: 200) == nil)
    }
}

/// Counts calls across concurrent tasks.
private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// A provider with a fixed answer, given after `delay`.
private struct FakeProvider: LyricsProvider {
    let id: LyricsProviderID
    let answer: Result<ProviderMatch?, ProviderError>
    var delay: Duration = .zero
    var calls: CallCounter?

    func lyrics(for query: TrackQuery) async throws(ProviderError) -> ProviderMatch? {
        await calls?.increment()
        if delay > .zero {
            do { try await Task.sleep(for: delay) } catch { throw .unreachable }
        }
        return try answer.get()
    }
}

private func lyrics(_ kind: Lyrics.Kind, from source: String) -> Lyrics {
    Lyrics(kind: kind, lines: [], plainText: nil, source: source)
}

private func temporaryCache() -> LyricsCache {
    LyricsCache(directory: FileManager.default.temporaryDirectory.appending(path: "openlyrics-tests-\(UUID().uuidString)"))
}

@Suite("Lyrics service")
struct LyricsServiceTests {
    private let query = TrackQuery(title: "Harbor Lights", artist: "The Tides", album: "", duration: 200)
    private let both = Set(LyricsProviderID.allCases)

    @Test func wordTimingWinsACloseCall() async {
        let service = LyricsService(providers: [
            FakeProvider(id: .lrclib, answer: .success(ProviderMatch(lyrics: lyrics(.lineSynced, from: "A"), confidence: 0.93))),
            FakeProvider(id: .netease, answer: .success(ProviderMatch(lyrics: lyrics(.wordSynced, from: "B"), confidence: 0.9))),
        ], cache: nil)
        #expect(await service.lookup(query, using: both) == .found(lyrics(.wordSynced, from: "B")))
    }

    @Test func aBetterMatchBeatsBetterTiming() async {
        let service = LyricsService(providers: [
            FakeProvider(id: .lrclib, answer: .success(ProviderMatch(lyrics: lyrics(.lineSynced, from: "A"), confidence: 0.98))),
            FakeProvider(id: .netease, answer: .success(ProviderMatch(lyrics: lyrics(.wordSynced, from: "B"), confidence: 0.6))),
        ], cache: nil)
        #expect(await service.lookup(query, using: both) == .found(lyrics(.lineSynced, from: "A")))
    }

    @Test func unreachableEverywhereIsUnavailable() async {
        let service = LyricsService(providers: [
            FakeProvider(id: .lrclib, answer: .failure(.unreachable)),
            FakeProvider(id: .netease, answer: .failure(.unreachable)),
        ], cache: nil)
        #expect(await service.lookup(query, using: both) == .unavailable)
    }

    @Test func oneUnreachableOneEmptyIsNotFoundButNotCached() async {
        let cache = temporaryCache()
        defer { cache.clear() }
        let service = LyricsService(providers: [
            FakeProvider(id: .lrclib, answer: .failure(.unreachable)),
            FakeProvider(id: .netease, answer: .success(nil)),
        ], cache: cache)
        #expect(await service.lookup(query, using: both) == .notFound)
        #expect(cache.load(LyricsCache.key(for: query)) == nil)
    }

    @Test func disabledProvidersAreNotAsked() async {
        let service = LyricsService(providers: [
            FakeProvider(id: .lrclib, answer: .success(ProviderMatch(lyrics: lyrics(.lineSynced, from: "A"), confidence: 1))),
            FakeProvider(id: .netease, answer: .success(ProviderMatch(lyrics: lyrics(.wordSynced, from: "B"), confidence: 1))),
        ], cache: nil)
        #expect(await service.lookup(query, using: [.lrclib]) == .found(lyrics(.lineSynced, from: "A")))
        #expect(await service.lookup(query, using: []) == .notFound)
    }

    @Test func foundLyricsComeFromTheCacheNextTime() async {
        let cache = temporaryCache()
        defer { cache.clear() }
        let first = LyricsService(providers: [
            FakeProvider(id: .lrclib, answer: .success(ProviderMatch(lyrics: lyrics(.lineSynced, from: "A"), confidence: 1))),
        ], cache: cache)
        _ = await first.lookup(query, using: both)
        let offline = LyricsService(providers: [FakeProvider(id: .lrclib, answer: .failure(.unreachable))], cache: cache)
        #expect(await offline.lookup(query, using: both) == .found(lyrics(.lineSynced, from: "A")))
        #expect(await offline.lookup(query, using: both, bypassCache: true) == .unavailable)
    }
}

@Suite("Lyrics service: not waiting on slow sources")
struct LyricsServiceTimingTests {
    private let query = TrackQuery(title: "Harbor Lights", artist: "The Tides", album: "", duration: 200)
    private let both = Set(LyricsProviderID.allCases)

    private func elapsed(_ work: () async -> Void) async -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        await work()
        return clock.now - start
    }

    @Test func aDecisiveMatchDoesNotWaitForASlowProvider() async {
        let service = LyricsService(providers: [
            FakeProvider(id: .lrclib, answer: .success(nil), delay: .seconds(10)),
            FakeProvider(id: .netease, answer: .success(ProviderMatch(lyrics: lyrics(.wordSynced, from: "B"), confidence: 1))),
        ], cache: nil, gracePeriod: 5)
        var result: LyricsLookup?
        let time = await elapsed { result = await service.lookup(query, using: both) }
        #expect(result == .found(lyrics(.wordSynced, from: "B")))
        #expect(time < .seconds(2))
    }

    @Test func aBetterMatchWithinTheGracePeriodWins() async {
        let service = LyricsService(providers: [
            FakeProvider(id: .lrclib, answer: .success(ProviderMatch(lyrics: lyrics(.lineSynced, from: "A"), confidence: 1))),
            FakeProvider(id: .netease, answer: .success(ProviderMatch(lyrics: lyrics(.wordSynced, from: "B"), confidence: 1)), delay: .milliseconds(200)),
        ], cache: nil, gracePeriod: 3)
        #expect(await service.lookup(query, using: both) == .found(lyrics(.wordSynced, from: "B")))
    }

    @Test func theGracePeriodEndsTheWait() async {
        let service = LyricsService(providers: [
            FakeProvider(id: .lrclib, answer: .success(ProviderMatch(lyrics: lyrics(.lineSynced, from: "A"), confidence: 1))),
            FakeProvider(id: .netease, answer: .success(ProviderMatch(lyrics: lyrics(.wordSynced, from: "B"), confidence: 1)), delay: .seconds(10)),
        ], cache: nil, gracePeriod: 0.3)
        var result: LyricsLookup?
        let time = await elapsed { result = await service.lookup(query, using: both) }
        #expect(result == .found(lyrics(.lineSynced, from: "A")))
        #expect(time < .seconds(2))
    }

    @Test func anUnreachableProviderSitsOutThenComesBack() async {
        let failing = CallCounter()
        let clock = MutableClock()
        let service = LyricsService(providers: [
            FakeProvider(id: .lrclib, answer: .failure(.unreachable), calls: failing),
            FakeProvider(id: .netease, answer: .success(ProviderMatch(lyrics: lyrics(.lineSynced, from: "B"), confidence: 1))),
        ], cache: nil, unreachableCooldown: 300, now: { clock.date })
        _ = await service.lookup(query, using: both)
        _ = await service.lookup(query, using: both)
        #expect(await failing.count == 1)
        clock.date = clock.date.addingTimeInterval(301)
        _ = await service.lookup(query, using: both)
        #expect(await failing.count == 2)
    }

    @Test func withEverythingSittingOutItAsksAnyway() async {
        let failing = CallCounter()
        let service = LyricsService(providers: [
            FakeProvider(id: .lrclib, answer: .failure(.unreachable), calls: failing),
        ], cache: nil)
        #expect(await service.lookup(query, using: both) == .unavailable)
        #expect(await service.lookup(query, using: both) == .unavailable)
        #expect(await failing.count == 2)
    }

    @Test func aProviderCutShortIsNotMarkedUnreachable() async {
        let slow = CallCounter()
        let service = LyricsService(providers: [
            FakeProvider(id: .lrclib, answer: .success(nil), delay: .seconds(10), calls: slow),
            FakeProvider(id: .netease, answer: .success(ProviderMatch(lyrics: lyrics(.wordSynced, from: "B"), confidence: 1))),
        ], cache: nil)
        _ = await service.lookup(query, using: both)
        _ = await service.lookup(query, using: both, bypassCache: true)
        #expect(await slow.count == 2)
    }

    @Test func notFoundIsNotCachedWhenASourceWasSkipped() async {
        let cache = temporaryCache()
        defer { cache.clear() }
        let service = LyricsService(providers: [
            FakeProvider(id: .lrclib, answer: .failure(.unreachable)),
            FakeProvider(id: .netease, answer: .success(nil)),
        ], cache: cache)
        #expect(await service.lookup(query, using: both) == .notFound)
        // LRCLIB now sits out, so this "not found" hasn't heard from every source either.
        #expect(await service.lookup(query, using: both, bypassCache: true) == .notFound)
        #expect(cache.load(LyricsCache.key(for: query)) == nil)
    }
}

/// A settable date, readable from any thread.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000_000)
    var date: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@Suite("Lyrics cache")
struct LyricsCacheTests {
    @Test func keysIgnoreEditionsAndSmallLengthDifferences() {
        let a = TrackQuery(title: "Harbor Lights - Remastered 2011", artist: "The Tides, Mo", album: "A", duration: 200.4)
        let b = TrackQuery(title: "Harbor Lights", artist: "the tides", album: "B", duration: 200.9)
        let c = TrackQuery(title: "Harbor Lights", artist: "The Tides", album: "A", duration: 240)
        #expect(LyricsCache.key(for: a) == LyricsCache.key(for: b))
        #expect(LyricsCache.key(for: a) != LyricsCache.key(for: c))
    }

    @Test func notFoundExpires() {
        let cache = temporaryCache()
        defer { cache.clear() }
        let saved = Date(timeIntervalSince1970: 1_000_000)
        cache.store(.notFound, for: "k", now: saved)
        #expect(cache.load("k", now: saved.addingTimeInterval(86_400)) == .notFound)
        #expect(cache.load("k", now: saved.addingTimeInterval(86_400 * (LyricsCache.notFoundLifetimeDays + 1))) == nil)
    }

    @Test func unavailableIsNeverStored() {
        let cache = temporaryCache()
        defer { cache.clear() }
        cache.store(.unavailable, for: "k")
        #expect(cache.load("k") == nil)
    }
}
