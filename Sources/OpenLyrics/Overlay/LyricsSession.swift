import Foundation

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

    /// Synced lyrics, a running clock and playback: there is something to follow along with.
    var hasSyncedLyrics: Bool { lyrics?.isSynced == true }

    /// Starts over for a new track (or none).
    func begin(_ track: NowPlayingMonitor.Track?) {
        self.track = track
        clock = nil
        lyrics = nil
        lookupState = track == nil ? .idle : .searching
    }

    func setLookup(_ lookup: LyricsLookup) {
        switch lookup {
        case .found(let found):
            lyrics = found
            lookupState = .found(found.kind, source: found.source)
        case .notFound:
            lyrics = nil
            lookupState = .notFound
        case .unavailable:
            lyrics = nil
            lookupState = .unavailable
        }
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
