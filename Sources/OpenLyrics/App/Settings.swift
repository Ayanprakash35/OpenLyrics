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

    enum Style: String, CaseIterable, Sendable {
        /// Words pile into a wall, one per row; the sung word in its highlight box.
        case stack
        /// The song's words on a drum under a lens; the sung word closest to the glass.
        case lens
        /// One line at a time, filling word by word.
        case lines

        var title: String {
            switch self {
            case .stack: "Stack"
            case .lens: "Lens"
            case .lines: "Lines"
            }
        }
    }

    /// How the colors spread over the words.
    enum ColorStyle: String, CaseIterable, Sendable {
        /// Each word's box, text and icon in the next of the cover's colors.
        case perWord
        /// Every word blends the same gradients.
        case gradient

        var title: String {
            switch self {
            case .perWord: "Each Word Its Own Color"
            case .gradient: "Blend Colors Within Words"
            }
        }
    }

    /// Which lyric color a custom color replaces.
    enum ColorRole: String, CaseIterable, Sendable {
        case lyric, highlight, secondary

        var title: String {
            switch self {
            case .lyric: "Lyric Text"
            case .highlight: "Highlight"
            case .secondary: "Secondary Text"
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
    @Published var style: Style { didSet { defaults.set(style.rawValue, forKey: Key.style) } }
    @Published var showIcons: Bool { didSet { defaults.set(showIcons, forKey: Key.showIcons) } }
    /// Words and icons bump gently with each sung word.
    @Published var beatBounce: Bool { didSet { defaults.set(beatBounce, forKey: Key.beatBounce) } }
    /// The track's title and artist above the lyrics on the lock screen.
    @Published var showTrackName: Bool { didSet { defaults.set(showTrackName, forKey: Key.showTrackName) } }
    /// Colors from the album artwork; off uses `customColors`.
    @Published var autoColors: Bool { didSet { defaults.set(autoColors, forKey: Key.autoColors) } }
    @Published var colorStyle: ColorStyle { didSet { defaults.set(colorStyle.rawValue, forKey: Key.colorStyle) } }
    @Published var customColors: LyricColors {
        didSet {
            defaults.set(customColors.lyric.hex, forKey: Key.lyricColor)
            defaults.set(customColors.highlight.hex, forKey: Key.highlightColor)
            defaults.set(customColors.secondary.hex, forKey: Key.secondaryColor)
        }
    }
    /// The display lyrics show on; 0 follows the main display (the one with the menu bar).
    @Published var displayID: UInt32 { didSet { defaults.set(Int(displayID), forKey: Key.displayID) } }
    /// Move with the beat of the Mac's sound output (needs Screen & System Audio Recording access).
    @Published var reactToMusic: Bool { didSet { defaults.set(reactToMusic, forKey: Key.reactToMusic) } }
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
            Key.showIcons: true,
            Key.beatBounce: true,
            Key.autoColors: true,
        ])
        showOnDesktop = defaults.bool(forKey: Key.showOnDesktop)
        showOnLockScreen = defaults.bool(forKey: Key.showOnLockScreen)
        position = defaults.string(forKey: Key.position).flatMap(Position.init) ?? .bottom
        textSize = defaults.string(forKey: Key.textSize).flatMap(TextSize.init) ?? .medium
        style = defaults.string(forKey: Key.style).flatMap(Style.init) ?? .stack
        showIcons = defaults.bool(forKey: Key.showIcons)
        beatBounce = defaults.bool(forKey: Key.beatBounce)
        showTrackName = defaults.bool(forKey: Key.showTrackName)
        autoColors = defaults.bool(forKey: Key.autoColors)
        colorStyle = defaults.string(forKey: Key.colorStyle).flatMap(ColorStyle.init) ?? .perWord
        let standard = LyricColors.standard
        customColors = LyricColors(
            lyric: defaults.string(forKey: Key.lyricColor).flatMap(PaletteColor.init(hex:)) ?? standard.lyric,
            highlight: defaults.string(forKey: Key.highlightColor).flatMap(PaletteColor.init(hex:)) ?? standard.highlight,
            secondary: defaults.string(forKey: Key.secondaryColor).flatMap(PaletteColor.init(hex:)) ?? standard.secondary
        )
        displayID = UInt32(clamping: defaults.integer(forKey: Key.displayID))
        reactToMusic = defaults.bool(forKey: Key.reactToMusic)
        showNextLine = defaults.bool(forKey: Key.showNextLine)
        keepAwakeWhenLocked = defaults.bool(forKey: Key.keepAwakeWhenLocked)
        syncOffset = min(max(defaults.double(forKey: Key.syncOffset), Self.offsetRange.lowerBound), Self.offsetRange.upperBound)
        let storedPlayers = (defaults.stringArray(forKey: Key.players) ?? []).compactMap(NowPlayingMonitor.Player.init)
        players = defaults.object(forKey: Key.players) == nil ? Set(NowPlayingMonitor.Player.allCases) : Set(storedPlayers)
        let storedProviders = (defaults.stringArray(forKey: Key.providers) ?? []).compactMap(LyricsProviderID.init)
        providers = defaults.object(forKey: Key.providers) == nil ? Set(LyricsProviderID.allCases) : Set(storedProviders)
    }

    /// The colors to draw with: from the album when `autoColors`, else the custom ones.
    func lyricColors(accents: [PaletteColor]) -> LyricColors {
        var colors = autoColors ? LyricColors.fromArtwork(accents: accents) : customColors
        colors.perWord = colorStyle == .perWord
        return colors
    }

    /// Picking a color turns Auto Sync off and keeps the other two colors as they look now.
    func setCustomColor(_ color: PaletteColor, for role: ColorRole, current: LyricColors) {
        customColors = LyricColors(
            lyric: role == .lyric ? color : current.lyric,
            highlight: role == .highlight ? color : current.highlight,
            secondary: role == .secondary ? color : current.secondary
        )
        autoColors = false
    }

    func resetColors() {
        customColors = .standard
        autoColors = true
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
        static let style = "style"
        static let showIcons = "showIcons"
        static let beatBounce = "beatBounce"
        static let showTrackName = "showTrackName"
        static let autoColors = "autoColors"
        static let colorStyle = "colorStyle"
        static let lyricColor = "lyricColor"
        static let highlightColor = "highlightColor"
        static let secondaryColor = "secondaryColor"
        static let displayID = "displayID"
        static let reactToMusic = "reactToMusic"
        static let showNextLine = "showNextLine"
        static let keepAwakeWhenLocked = "keepAwakeWhenLocked"
        static let syncOffset = "syncOffset"
        static let players = "players"
        static let providers = "providers"
        static let lockScreenSpaceLevel = "lockScreenSpaceLevel"
    }
}
