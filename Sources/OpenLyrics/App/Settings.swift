import AppKit
import Combine

/// The user's choices, stored in UserDefaults. SwiftUI views observe it directly; the app reacts to
/// changes through `objectWillChange`.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    enum Position: String, CaseIterable, Sendable {
        case top, center, bottom

        var title: String {
            switch self {
            case .top: "Top"
            case .center: "Center"
            case .bottom: "Bottom"
            }
        }
    }

    enum TextSize: String, CaseIterable, Sendable {
        case small, medium, large, huge

        var title: String {
            switch self {
            case .small: "Small"
            case .medium: "Medium"
            case .large: "Large"
            case .huge: "Huge"
            }
        }

        /// Point size of the current line on the desktop; the lock screen scales it up.
        var pointSize: CGFloat {
            switch self {
            case .small: 26
            case .medium: 34
            case .large: 44
            case .huge: 56
            }
        }
    }

    enum ColorMode: String, CaseIterable, Sendable {
        case artwork, white

        var title: String {
            switch self {
            case .artwork: "Album Artwork"
            case .white: "White"
            }
        }
    }

    /// Steps the timing menu items nudge the offset by, in seconds.
    static let offsetStep: TimeInterval = 0.25
    static let offsetRange: ClosedRange<TimeInterval> = -5...5

    private let defaults: UserDefaults

    @Published var showOnDesktop: Bool { didSet { defaults.set(showOnDesktop, forKey: Key.showOnDesktop) } }
    @Published var showOnLockScreen: Bool { didSet { defaults.set(showOnLockScreen, forKey: Key.showOnLockScreen) } }
    @Published var position: Position { didSet { defaults.set(position.rawValue, forKey: Key.position) } }
    @Published var textSize: TextSize { didSet { defaults.set(textSize.rawValue, forKey: Key.textSize) } }
    @Published var colorMode: ColorMode { didSet { defaults.set(colorMode.rawValue, forKey: Key.colorMode) } }
    @Published var showNextLine: Bool { didSet { defaults.set(showNextLine, forKey: Key.showNextLine) } }
    @Published var keepAwakeWhenLocked: Bool { didSet { defaults.set(keepAwakeWhenLocked, forKey: Key.keepAwakeWhenLocked) } }
    /// Seconds added to the playback position before choosing what to show: positive shows lyrics
    /// sooner, for lyrics that lag the music.
    @Published var syncOffset: TimeInterval { didSet { defaults.set(syncOffset, forKey: Key.syncOffset) } }
    @Published var players: Set<NowPlayingMonitor.Player> {
        didSet { defaults.set(players.map(\.rawValue).sorted(), forKey: Key.players) }
    }
    @Published var providers: Set<LyricsProviderID> {
        didSet { defaults.set(providers.map(\.rawValue).sorted(), forKey: Key.providers) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.showOnDesktop: true,
            Key.showOnLockScreen: true,
            Key.showNextLine: true,
            Key.keepAwakeWhenLocked: true,
        ])
        showOnDesktop = defaults.bool(forKey: Key.showOnDesktop)
        showOnLockScreen = defaults.bool(forKey: Key.showOnLockScreen)
        position = defaults.string(forKey: Key.position).flatMap(Position.init) ?? .bottom
        textSize = defaults.string(forKey: Key.textSize).flatMap(TextSize.init) ?? .medium
        colorMode = defaults.string(forKey: Key.colorMode).flatMap(ColorMode.init) ?? .artwork
        showNextLine = defaults.bool(forKey: Key.showNextLine)
        keepAwakeWhenLocked = defaults.bool(forKey: Key.keepAwakeWhenLocked)
        syncOffset = min(max(defaults.double(forKey: Key.syncOffset), Self.offsetRange.lowerBound), Self.offsetRange.upperBound)
        let storedPlayers = (defaults.stringArray(forKey: Key.players) ?? []).compactMap(NowPlayingMonitor.Player.init)
        players = defaults.object(forKey: Key.players) == nil ? Set(NowPlayingMonitor.Player.allCases) : Set(storedPlayers)
        let storedProviders = (defaults.stringArray(forKey: Key.providers) ?? []).compactMap(LyricsProviderID.init)
        providers = defaults.object(forKey: Key.providers) == nil ? Set(LyricsProviderID.allCases) : Set(storedProviders)
    }

    func nudgeOffset(by delta: TimeInterval) {
        let nudged = ((syncOffset + delta) / Self.offsetStep).rounded() * Self.offsetStep
        syncOffset = min(max(nudged, Self.offsetRange.lowerBound), Self.offsetRange.upperBound)
    }

    /// The space-level override for troubleshooting the lock-screen overlay (`defaults write
    /// com.openlyrics.app lockScreenSpaceLevel -int 500`); nil to use the built-in level.
    var lockScreenSpaceLevel: Int32? {
        defaults.object(forKey: Key.lockScreenSpaceLevel) == nil ? nil : Int32(defaults.integer(forKey: Key.lockScreenSpaceLevel))
    }

    private enum Key {
        static let showOnDesktop = "showOnDesktop"
        static let showOnLockScreen = "showOnLockScreen"
        static let position = "position"
        static let textSize = "textSize"
        static let colorMode = "colorMode"
        static let showNextLine = "showNextLine"
        static let keepAwakeWhenLocked = "keepAwakeWhenLocked"
        static let syncOffset = "syncOffset"
        static let players = "players"
        static let providers = "providers"
        static let lockScreenSpaceLevel = "lockScreenSpaceLevel"
    }
}
