import Foundation
import os

/// AppleScript timing. Both values are written into the script sources below.
enum NowPlayingScriptConfig {
    /// Seconds a state query waits for the player before AppleScript gives up with -1712. A healthy
    /// player answers in milliseconds; a hung one holds the script queue no longer than this.
    /// Sane range: 2–10.
    static let stateTimeout = 4
    /// Seconds Music may take to hand over a track's artwork, which can be several megabytes.
    /// Sane range: 4–15.
    static let artworkTimeout = 8
    /// Seconds a playback-position query waits. It runs every second or two while lyrics show, so
    /// a hung player must give up quickly. Sane range: 1–3.
    static let positionTimeout = 2
}

extension NowPlayingMonitor {
    /// What a player says it's doing.
    enum PlaybackState: Sendable {
        case playing, paused, stopped
    }

    /// One successful state query.
    struct PlayerSnapshot: Equatable, Sendable {
        var state: PlaybackState
        /// nil when stopped, or when the player can't describe what it plays (some radio streams).
        var track: Track?
        /// Spotify's cover image. Always nil for Music, whose artwork comes over Apple Events.
        var artworkURL: URL?
    }

    enum QueryResult: Equatable, Sendable {
        case snapshot(PlayerSnapshot)
        /// The player isn't running (the script's guard, the preflight, or -600/-609).
        case notRunning
        /// The user denied OpenLyrics Automation access to this player (-1743).
        case notAuthorized
        /// Not sent: the user hasn't decided on Automation access yet, and this query may not ask.
        case consentRequired
        /// The player didn't answer within the script's timeout (-1712).
        case timedOut
        /// Any other AppleScript error, or a reply the parser didn't recognize.
        case failed(code: Int)
    }

    /// Where playback is in the current track, as one position query saw it.
    struct PositionSample: Equatable, Sendable {
        var state: PlaybackState
        /// The track the position belongs to, in the same form as `Track.id`; empty when the player
        /// can't identify what it plays.
        var trackID: String
        /// Seconds from the start of the track.
        var position: TimeInterval
        /// The track's length in seconds; nil when the player doesn't know (streams, radio).
        var duration: TimeInterval?
        /// When the player answered, in `ProcessInfo.systemUptime` seconds: the midpoint of the
        /// script's run, so time spent waiting behind other scripts doesn't count. 0 when unknown.
        var measuredAt: TimeInterval = 0
    }

    enum PositionResult: Equatable, Sendable {
        case sample(PositionSample)
        /// The player is stopped or has no current track.
        case idle
        /// Not sent or not answered: not running, no Automation access yet, a timeout, an error.
        case unavailable
    }

    enum ArtworkFetch: Equatable, Sendable {
        case image(Data)
        /// The track has no artwork, or none worth keeping (too large). Definitive for that track.
        case none
        /// Couldn't be fetched this time (timeout, network, the track changed mid-fetch).
        case unavailable

        var data: Data? {
            if case .image(let data) = self { return data }
            return nil
        }

        /// Worth caching: asking again for the same track would give the same answer.
        var isDefinitive: Bool { self != .unavailable }
    }
}

/// The AppleScript sources and the parsing of what they return.
///
/// Every script is wrapped in `if application id … is running`: a player that has just quit is
/// never relaunched, because AppleScript launches an application the moment a `tell` block sends
/// it an event. Results are lists rather than records, since records of application terms don't
/// come back with plain keys.
enum NowPlayingScript: Hashable, Sendable {
    typealias Player = NowPlayingMonitor.Player

    /// `{player state, id, name, artist, album}` plus Spotify's `artwork url`; just
    /// `{player state}` when stopped or when there is no scriptable current track; `{}` when the
    /// player isn't running.
    case state(Player)
    /// `{persistent ID, raw data}`, or `{persistent ID}` when the track has no artwork Music can
    /// hand over; `{}` when Music isn't running.
    case musicArtwork
    /// `{player state, id, player position, duration}`; `{player state}` when stopped; `{}` when
    /// the player isn't running. The ID is empty when there's no scriptable current track.
    case position(Player)

    static let all: [NowPlayingScript] = [
        .state(.music), .state(.spotify), .musicArtwork, .position(.music), .position(.spotify),
    ]

    var player: Player {
        switch self {
        case .state(let player), .position(let player): player
        case .musicArtwork: .music
        }
    }

    var source: String {
        switch self {
        case .state(.music): Self.musicStateSource
        case .state(.spotify): Self.spotifyStateSource
        case .musicArtwork: Self.musicArtworkSource
        case .position(.music): Self.positionSource(for: .music, idProperty: "persistent ID")
        case .position(.spotify): Self.positionSource(for: .spotify, idProperty: "id")
        }
    }

    /// Music reports `duration` in seconds and Spotify in milliseconds; `parsePosition` converts.
    private static func positionSource(for player: Player, idProperty: String) -> String {
        """
        if application id "\(player.bundleIdentifier)" is running then
        \twith timeout of \(NowPlayingScriptConfig.positionTimeout) seconds
        \t\ttell application id "\(player.bundleIdentifier)"
        \t\t\tset playerState to player state
        \t\t\tif playerState is stopped then return {playerState}
        \t\t\ttry
        \t\t\t\tset t to current track
        \t\t\t\treturn {playerState, \(idProperty) of t, player position, duration of t}
        \t\t\ton error errorMessage number errorNumber
        \t\t\t\tif errorNumber is not -1728 then error errorMessage number errorNumber
        \t\t\t\treturn {playerState, "", player position, missing value}
        \t\t\tend try
        \t\tend tell
        \tend timeout
        end if
        return {}
        """
    }

    // -1728 (no such object) is what Music and Spotify answer for `current track` when a radio
    // stream or an empty queue has none; anything else, a timeout included, propagates.
    private static let musicStateSource = """
        if application id "\(Player.music.bundleIdentifier)" is running then
        \twith timeout of \(NowPlayingScriptConfig.stateTimeout) seconds
        \t\ttell application id "\(Player.music.bundleIdentifier)"
        \t\t\tset playerState to player state
        \t\t\tif playerState is stopped then return {playerState}
        \t\t\ttry
        \t\t\t\tset t to current track
        \t\t\t\treturn {playerState, persistent ID of t, name of t, artist of t, album of t}
        \t\t\ton error errorMessage number errorNumber
        \t\t\t\tif errorNumber is not -1728 then error errorMessage number errorNumber
        \t\t\t\treturn {playerState}
        \t\t\tend try
        \t\tend tell
        \tend timeout
        end if
        return {}
        """

    private static let spotifyStateSource = """
        if application id "\(Player.spotify.bundleIdentifier)" is running then
        \twith timeout of \(NowPlayingScriptConfig.stateTimeout) seconds
        \t\ttell application id "\(Player.spotify.bundleIdentifier)"
        \t\t\tset playerState to player state
        \t\t\tif playerState is stopped then return {playerState}
        \t\t\ttry
        \t\t\t\tset t to current track
        \t\t\t\treturn {playerState, id of t, name of t, artist of t, album of t, artwork url of t}
        \t\t\ton error errorMessage number errorNumber
        \t\t\t\tif errorNumber is not -1728 then error errorMessage number errorNumber
        \t\t\t\treturn {playerState}
        \t\t\tend try
        \t\tend tell
        \tend timeout
        end if
        return {}
        """

    // Returns the track's ID with the data so a reply for a track that changed mid-fetch is
    // recognized. Tracks without artwork, and streams whose artwork Music won't hand over, fail
    // `artwork 1` with -1728 or similar: everything but a timeout means "no artwork".
    private static let musicArtworkSource = """
        if application id "\(Player.music.bundleIdentifier)" is running then
        \twith timeout of \(NowPlayingScriptConfig.artworkTimeout) seconds
        \t\ttell application id "\(Player.music.bundleIdentifier)"
        \t\t\tset t to current track
        \t\t\tset trackID to persistent ID of t
        \t\t\ttry
        \t\t\t\treturn {trackID, raw data of artwork 1 of t}
        \t\t\ton error errorMessage number errorNumber
        \t\t\t\tif errorNumber is -1712 then error errorMessage number errorNumber
        \t\t\t\treturn {trackID}
        \t\t\tend try
        \t\tend tell
        \tend timeout
        end if
        return {}
        """

    // MARK: - Parsing

    /// What an Apple Event error number means for a query.
    static func result(forErrorCode code: Int) -> NowPlayingMonitor.QueryResult {
        switch code {
        case errAEEventNotPermitted: .notAuthorized
        case errAEEventWouldRequireUserConsent: .consentRequired
        case procNotFound, connectionInvalid: .notRunning
        case errAETimeout: .timedOut
        default: .failed(code: code)
        }
    }

    /// Reads a state script's reply (see `state`).
    static func parseState(_ reply: NSAppleEventDescriptor, player: Player) -> NowPlayingMonitor.QueryResult {
        guard reply.descriptorType == typeAEList else { return .failed(code: errAECoercionFail) }
        let count = reply.numberOfItems
        guard count > 0 else { return .notRunning }
        guard let state = playbackState(reply.atIndex(1)) else { return .failed(code: errAECoercionFail) }

        var snapshot = NowPlayingMonitor.PlayerSnapshot(state: state)
        guard state != .stopped, count >= 5, let rawID = string(reply.atIndex(2)) else { return .snapshot(snapshot) }
        snapshot.track = NowPlayingMonitor.Track(
            player: player,
            id: player == .music ? NowPlayingMonitor.canonicalMusicID(rawID) : rawID,
            title: string(reply.atIndex(3)) ?? "",
            artist: string(reply.atIndex(4)) ?? "",
            album: string(reply.atIndex(5)) ?? ""
        )
        if player == .spotify, count >= 6, let url = string(reply.atIndex(6)) {
            snapshot.artworkURL = NowPlayingMonitor.artworkURL(from: url)
        }
        return .snapshot(snapshot)
    }

    /// Reads the Music artwork script's reply (see `musicArtwork`), accepting it only for the
    /// track it was asked about.
    static func parseMusicArtwork(_ reply: NSAppleEventDescriptor, expecting trackID: String) -> NowPlayingMonitor.ArtworkFetch {
        guard reply.descriptorType == typeAEList, reply.numberOfItems >= 1,
              let replyID = string(reply.atIndex(1)),
              NowPlayingMonitor.canonicalMusicID(replyID) == trackID else {
            return .unavailable
        }
        guard reply.numberOfItems >= 2, let data = imageData(reply.atIndex(2)),
              data.count <= NowPlayingConfig.maxArtworkBytes else {
            return .none
        }
        return .image(data)
    }

    /// Reads a position script's reply (see `position`).
    static func parsePosition(_ reply: NSAppleEventDescriptor, player: Player) -> NowPlayingMonitor.PositionResult {
        guard reply.descriptorType == typeAEList, reply.numberOfItems > 0,
              let state = playbackState(reply.atIndex(1)) else { return .unavailable }
        guard state != .stopped, reply.numberOfItems >= 3, let position = number(reply.atIndex(3)) else { return .idle }
        let rawID = string(reply.atIndex(2)) ?? ""
        let rawDuration = reply.numberOfItems >= 4 ? number(reply.atIndex(4)) : nil
        return .sample(NowPlayingMonitor.PositionSample(
            state: state,
            trackID: player == .music && !rawID.isEmpty ? NowPlayingMonitor.canonicalMusicID(rawID) : rawID,
            position: max(0, position),
            duration: NowPlayingMonitor.durationSeconds(rawDuration, player: player)
        ))
    }

    /// A number item, or nil for `missing value` or anything that isn't a number.
    private static func number(_ descriptor: NSAppleEventDescriptor?) -> Double? {
        guard let descriptor, !isMissingValue(descriptor) else { return nil }
        let numeric: Set<DescType> = [
            typeSInt16, typeSInt32, typeSInt64, typeUInt32, typeUInt64,
            typeIEEE32BitFloatingPoint, typeIEEE64BitFloatingPoint,
        ]
        if numeric.contains(descriptor.descriptorType) {
            let value = descriptor.doubleValue
            return value.isFinite ? value : nil
        }
        // Some players answer with text; anything that doesn't read as a number counts as none.
        return descriptor.stringValue.flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
    }

    static func playbackState(_ descriptor: NSAppleEventDescriptor?) -> NowPlayingMonitor.PlaybackState? {
        guard let descriptor else { return nil }
        if descriptor.descriptorType == typeEnumerated {
            // Both dictionaries share Music's ePlS codes; Spotify only has the first three.
            switch descriptor.enumCodeValue {
            case fourCharCode("kPSP"), fourCharCode("kPSF"), fourCharCode("kPSR"): return .playing
            case fourCharCode("kPSp"): return .paused
            case fourCharCode("kPSS"): return .stopped
            default: return nil
            }
        }
        switch descriptor.stringValue?.lowercased() {
        case "playing", "fast forwarding", "rewinding": return .playing
        case "paused": return .paused
        case "stopped": return .stopped
        default: return nil
        }
    }

    static func fourCharCode(_ code: String) -> OSType {
        code.utf8.reduce(0) { $0 << 8 | OSType($1) }
    }

    private static func isMissingValue(_ descriptor: NSAppleEventDescriptor) -> Bool {
        descriptor.descriptorType == typeNull
            || (descriptor.descriptorType == typeType && descriptor.typeCodeValue == fourCharCode("msng"))
    }

    /// A text item, or nil for `missing value`. (Coercing `missing value` itself to text would
    /// give "msng".)
    private static func string(_ descriptor: NSAppleEventDescriptor?) -> String? {
        guard let descriptor, !isMissingValue(descriptor) else { return nil }
        return descriptor.stringValue
    }

    /// `raw data` arrives as 'tdta' or an image type such as 'JPEG' or 'PNGf'; anything that is
    /// plainly not image bytes is rejected.
    private static func imageData(_ descriptor: NSAppleEventDescriptor?) -> Data? {
        guard let descriptor, !isMissingValue(descriptor) else { return nil }
        let notImages: Set<DescType> = [typeUnicodeText, typeUTF8Text, typeChar, typeEnumerated, typeAEList, typeAERecord]
        guard !notImages.contains(descriptor.descriptorType) else { return nil }
        let data = descriptor.data
        return data.isEmpty ? nil : data
    }
}

/// The Apple Events `NowPlayingMonitor` sends: `NowPlayingScriptRunner` in the app, a stand-in
/// in tests.
protocol NowPlayingQuerying: Sendable {
    /// What `player` is playing. With `mayPrompt` false, nothing is sent unless the user has
    /// already granted Automation access.
    func state(of player: NowPlayingMonitor.Player, mayPrompt: Bool) async -> NowPlayingMonitor.QueryResult
    /// The current Music track's artwork, if that track is still `trackID`. Never prompts.
    func musicArtwork(expecting trackID: String) async -> NowPlayingMonitor.ArtworkFetch
    /// Where `player` is in its current track. Never prompts.
    func position(of player: NowPlayingMonitor.Player) async -> NowPlayingMonitor.PositionResult
}

/// Runs the scripts on one serial background queue, so a slow or hung player can delay other
/// queries but never the main thread — the UI and the lyrics.
///
/// `@unchecked Sendable`: the NSAppleScript objects (neither thread-safe nor Sendable) are
/// compiled, run and kept only on `queue`, and descriptors are parsed there too; only Sendable
/// values cross back. Everything else here is immutable.
final class NowPlayingScriptRunner: NowPlayingQuerying, @unchecked Sendable {
    typealias Player = NowPlayingMonitor.Player

    private let logger = Logger(subsystem: "com.openlyrics.app", category: "NowPlaying")
    // `.workItem` drains autoreleased objects after every block, so multi-megabyte artwork
    // replies don't linger until the queue happens to go idle.
    private let queue = DispatchQueue(label: "com.openlyrics.nowplaying.applescript", qos: .utility, autoreleaseFrequency: .workItem)
    /// Compiled on first use. Only touched on `queue`.
    private var compiled: [NowPlayingScript: NSAppleScript] = [:]

    private enum Outcome {
        case reply(NSAppleEventDescriptor)
        case error(Int)
    }

    /// Asks `player` what it's playing. With `mayPrompt` false, nothing is sent unless the user has
    /// already granted Automation access, so the macOS prompt can't appear out of context.
    func state(of player: Player, mayPrompt: Bool) async -> NowPlayingMonitor.QueryResult {
        await onQueue { $0.queryState(of: player, mayPrompt: mayPrompt) }
    }

    /// The current Music track's artwork, if that track is still `trackID`. Only runs once access
    /// is granted — it follows a successful state query — so it never prompts.
    func musicArtwork(expecting trackID: String) async -> NowPlayingMonitor.ArtworkFetch {
        await onQueue { $0.fetchMusicArtwork(expecting: trackID) }
    }

    /// Where `player` is in its current track. Sent only once Automation access is granted, so it
    /// never prompts.
    func position(of player: Player) async -> NowPlayingMonitor.PositionResult {
        await onQueue { $0.queryPosition(of: player) }
    }

    private func queryPosition(of player: Player) -> NowPlayingMonitor.PositionResult {
        guard refusal(for: player, mayPrompt: false) == nil else { return .unavailable }
        let started = ProcessInfo.processInfo.systemUptime
        switch run(.position(player)) {
        case .reply(let reply):
            let result = NowPlayingScript.parsePosition(reply, player: player)
            guard case .sample(var sample) = result else { return result }
            sample.measuredAt = (started + ProcessInfo.processInfo.systemUptime) / 2
            return .sample(sample)
        case .error:
            return .unavailable
        }
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable (NowPlayingScriptRunner) -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work(self)) }
        }
    }

    private func queryState(of player: Player, mayPrompt: Bool) -> NowPlayingMonitor.QueryResult {
        if let refusal = refusal(for: player, mayPrompt: mayPrompt) { return refusal }
        switch run(.state(player)) {
        case .reply(let reply): return NowPlayingScript.parseState(reply, player: player)
        case .error(let code): return NowPlayingScript.result(forErrorCode: code)
        }
    }

    private func fetchMusicArtwork(expecting trackID: String) -> NowPlayingMonitor.ArtworkFetch {
        guard refusal(for: .music, mayPrompt: false) == nil else { return .unavailable }
        switch run(.musicArtwork) {
        case .reply(let reply):
            return NowPlayingScript.parseMusicArtwork(reply, expecting: trackID)
        case .error(let code):
            logger.notice("Music artwork query failed: \(code, privacy: .public)")
            return .unavailable
        }
    }

    /// Why a query to `player` must not be sent, decided without sending the player anything:
    /// AEDeterminePermissionToAutomateTarget asks the privacy database, and with
    /// `askUserIfNeeded` false it never shows the prompt. nil means go ahead.
    private func refusal(for player: Player, mayPrompt: Bool) -> NowPlayingMonitor.QueryResult? {
        let target = NSAppleEventDescriptor(bundleIdentifier: player.bundleIdentifier)
        let status = withExtendedLifetime(target) { () -> OSStatus in
            guard let address = target.aeDesc else { return OSStatus(errAEEventWouldRequireUserConsent) }
            return AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, false)
        }
        switch Int(status) {
        case Int(noErr): return nil
        case errAEEventNotPermitted: return .notAuthorized
        case procNotFound: return .notRunning
        default:
            // Undecided (errAEEventWouldRequireUserConsent), or an answer this code doesn't know:
            // only a query allowed to prompt goes ahead, and the player's own reply then decides.
            return mayPrompt ? nil : .consentRequired
        }
    }

    private func run(_ script: NowPlayingScript) -> Outcome {
        dispatchPrecondition(condition: .onQueue(queue))
        let appleScript: NSAppleScript
        switch compiledScript(script) {
        case .success(let compiledScript): appleScript = compiledScript
        case .failure(let failure): return .error(failure.code)
        }
        var errorInfo: NSDictionary?
        let reply = appleScript.executeAndReturnError(&errorInfo)
        // On failure the reply is nil despite the non-optional signature: check errorInfo first
        // and don't touch the reply.
        if let errorInfo { return .error(Self.errorCode(errorInfo)) }
        return .reply(reply)
    }

    private struct CompileFailure: Error {
        let code: Int
    }

    private func compiledScript(_ script: NowPlayingScript) -> Result<NSAppleScript, CompileFailure> {
        if let existing = compiled[script] { return .success(existing) }
        guard let appleScript = NSAppleScript(source: script.source) else {
            return .failure(CompileFailure(code: errOSAScriptError))
        }
        var errorInfo: NSDictionary?
        guard appleScript.compileAndReturnError(&errorInfo) else {
            let message = errorInfo?[NSAppleScript.errorMessage] as? String ?? "unknown error"
            logger.error("Couldn't compile the \(script.player.displayName, privacy: .public) script: \(message, privacy: .public)")
            return .failure(CompileFailure(code: errorInfo.map(Self.errorCode) ?? errOSAScriptError))
        }
        compiled[script] = appleScript
        return .success(appleScript)
    }

    private static func errorCode(_ errorInfo: NSDictionary) -> Int {
        errorInfo[NSAppleScript.errorNumber] as? Int ?? errOSAScriptError
    }
}
