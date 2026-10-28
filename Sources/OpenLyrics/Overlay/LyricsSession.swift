import AppKit

/// Everything the overlay shows, in one observable place: the track, its lyrics, where playback is,
/// and the colors. The coordinator writes it; the SwiftUI views only read it.
@MainActor
final class LyricsSession: ObservableObject {
    enum LookupState: Equatable {
        /// No track.
        case idle
        /// Waiting for the track's length, then asking the providers.
        case searching
        case found(Lyrics.Kind, source: String)
        case notFound
        /// No provider could be reached.
        case unavailable
    }

    @Published private(set) var track: NowPlayingMonitor.Track?
    @Published var isPlaying = false
    @Published var clock: PlaybackClock?
    @Published private(set) var lyrics: Lyrics?
    @Published private(set) var lookupState: LookupState = .idle
    @Published var palette: ArtworkPalette = .fallback
    /// The artwork's distinct colors, leading first (see `ColorExtractor.Result.accents`).
    @Published var accents: [PaletteColor] = []
    /// The cover itself, for the menu.
    @Published var artwork: NSImage?
    /// The lyrics' words in order, for the Lens style, built once per lyrics.
    private(set) var lensEntries: [LensLayout.Entry] = []
    private(set) var lensStarts: [TimeInterval] = []
    /// All sung words in order, and which of them begin a line, for the beat bounce.
    private(set) var allWords: [LyricWord] = []
    private(set) var lineStartFlags: [Bool] = []
    /// The song's effects and easter eggs, and each constellation's stars by its start time.
    private(set) var sceneScript = SceneScript.empty
    private(set) var constellations: [TimeInterval: [ConstellationNode]] = [:]

    /// Synced lyrics, a running clock and playback: there is something to follow along with.
    var hasSyncedLyrics: Bool { lyrics?.isSynced == true }

    /// Starts over for a new track (or none).
    func begin(_ track: NowPlayingMonitor.Track?) {
        if track?.identity != self.track?.identity { artwork = nil }
        self.track = track
        clock = nil
        setLyrics(nil)
        lookupState = track == nil ? .idle : .searching
    }

    func setLookup(_ lookup: LyricsLookup) {
        switch lookup {
        case .found(let found):
            setLyrics(found)
            lookupState = .found(found.kind, source: found.source)
        case .notFound:
            setLyrics(nil)
            lookupState = .notFound
        case .unavailable:
            setLyrics(nil)
            lookupState = .unavailable
        }
    }

    private func setLyrics(_ new: Lyrics?) {
        lyrics = new
        lensEntries = new.map(LensLayout.entries(in:)) ?? []
        lensStarts = lensEntries.map(\.word.start)
        allWords = lensEntries.map(\.word)
        lineStartFlags = lensEntries.map { $0.index == 0 }
        let script = new.map { SceneDirector.script(for: $0, track: .init(title: track?.title ?? "", artist: track?.artist ?? "")) } ?? .empty
        sceneScript = script
        constellations = [:]
        if let new {
            for event in script.events where event.kind == .constellation {
                constellations[event.start] = ConstellationLayout.nodes(for: event, in: new)
            }
        }
    }

    /// The artwork colors to build lyric colors from: the full accent list once known, else the
    /// two the palette keeps.
    var artworkAccents: [PaletteColor] {
        accents.isEmpty ? [palette.primary, palette.secondary] : accents
    }

    func setSearching() {
        lookupState = .searching
    }

    /// The playback position at monotonic `time`, shifted by `offset`; nil without a clock.
    func position(at time: TimeInterval, offset: TimeInterval) -> TimeInterval? {
        clock.map { $0.position(at: time) + offset }
    }
}

extension NowPlayingMonitor.Track {
    /// Identifies the track across notifications and queries; falls back to its title and artist
    /// when the player gives no ID.
    var identity: String {
        "\(player.rawValue)|" + (id.isEmpty ? "\(title)|\(artist)" : id)
    }
}
