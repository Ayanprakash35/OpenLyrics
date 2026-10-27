import AppKit
import SwiftUI

/// A menu item that runs a closure, with an optional SF Symbol beside its title.
private final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
         checked: Bool? = nil, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        keyEquivalentModifierMask = modifiers
        if let checked { state = checked ? .on : .off }
        isEnabled = enabled
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) {
        fatalError("ActionItem does not support NSCoder")
    }

    @objc private func run() {
        handler()
    }
}

/// The card at the top of the menu: the cover, the track, and where its lyrics stand.
struct NowPlayingCard: View {
    enum Tone { case good, busy, quiet, problem }

    var title: String
    var subtitle: String
    var status: String
    var tone: Tone
    var artwork: NSImage?
    var accent: Color

    var body: some View {
        HStack(spacing: 11) {
            cover
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    Circle().fill(toneColor).frame(width: 6, height: 6)
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.top, 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(width: 290, alignment: .leading)
    }

    @ViewBuilder
    private var cover: some View {
        if let artwork {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        } else {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [accent.opacity(0.85), accent.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 46, height: 46)
                .overlay(Image(systemName: "quote.bubble.fill").font(.system(size: 19, weight: .semibold)).foregroundStyle(.white))
        }
    }

    private var toneColor: Color {
        switch tone {
        case .good: .green
        case .busy: .orange
        case .quiet: .gray
        case .problem: .red
        }
    }
}

/// The menu-bar icon and its menu: a now-playing card, then the settings grouped by what they
/// change — how lyrics look, where they show, and the lyrics themselves. Rebuilt each time it
/// opens, so it always shows the current state.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let coordinator: LyricsCoordinator
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private var settings: Settings { coordinator.settings }
    private var session: LyricsSession { coordinator.session }

    init(coordinator: LyricsCoordinator) {
        self.coordinator = coordinator
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()
        coordinator.onChange = { [weak self] in self?.updateIcon() }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbol: String
        switch coordinator.nowPlaying {
        case .notAuthorized: symbol = "exclamationmark.bubble"
        case .playing where session.hasSyncedLyrics: symbol = "quote.bubble.fill"
        default: symbol = "quote.bubble"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "OpenLyrics")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "OpenLyrics — \(statusLine)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(cardItem())
        for item in attentionItems() { menu.addItem(item) }
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Look"))
        menu.addItem(choice("Style", symbol: "square.stack.3d.up", Settings.Style.allCases, \.style, title: \.title) { style in
            switch style {
            case .stack: "square.stack.3d.up"
            case .lens: "circle.circle"
            case .lines: "text.alignleft"
            }
        })
        menu.addItem(colorsMenu())
        menu.addItem(choice("Text Size", symbol: "textformat.size", Settings.TextSize.allCases, \.textSize, title: \.title))
        menu.addItem(toggle("Show Icons", symbol: "face.smiling", \.showIcons))
        menu.addItem(toggle("Bounce to the Beat", symbol: "waveform.path", \.beatBounce))
        menu.addItem(reactItem())
        if settings.style == .lines {
            menu.addItem(toggle("Show Next Line", symbol: "text.append", \.showNextLine))
        }
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Where"))
        let lockAvailable = coordinator.lockScreenAvailable
        let lockItem = toggle(lockAvailable ? "Lock Screen" : "Lock Screen (unavailable)", symbol: "lock.display", \.showOnLockScreen)
        lockItem.isEnabled = lockAvailable
        menu.addItem(lockItem)
        menu.addItem(toggle("Desktop", symbol: "macwindow", \.showOnDesktop))
        menu.addItem(choice("Position on Desktop", symbol: "rectangle.split.1x2", Settings.Position.allCases, \.position, title: \.title))
        menu.addItem(displayMenu())
        menu.addItem(toggle("Track Name on Lock Screen", symbol: "character.textbox", \.showTrackName))
        menu.addItem(toggle("Keep Display Awake on Lock Screen", symbol: "sun.max", \.keepAwakeWhenLocked))
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Lyrics"))
        menu.addItem(timingMenu())
        menu.addItem(ActionItem("Reload Lyrics", symbol: "arrow.clockwise", key: "r", enabled: session.track != nil) { [weak self] in
            self?.coordinator.reloadLyrics(bypassCache: true)
        })
        menu.addItem(ActionItem("Preview Lock Screen", symbol: "eye", enabled: lockAvailable && session.hasSyncedLyrics) { [weak self] in
            self?.coordinator.previewLockScreen()
        })
        menu.addItem(setMenu("Sources", symbol: "network", LyricsProviderID.allCases, \.providers, title: \.displayName))
        menu.addItem(setMenu("Players", symbol: "music.note.list", NowPlayingMonitor.Player.allCases, \.players, title: \.displayName))
        menu.addItem(.separator())

        menu.addItem(ActionItem("Open at Login", symbol: "power", checked: LaunchAtLogin.state == .enabled) {
            LaunchAtLogin.setEnabled(LaunchAtLogin.state != .enabled)
        })
        menu.addItem(ActionItem("Clear Lyrics Cache", symbol: "trash") { [weak self] in
            self?.coordinator.clearLyricsCache()
        })
        menu.addItem(ActionItem("OpenLyrics \(AppInfo.version) on GitHub", symbol: "chevron.left.forwardslash.chevron.right") {
            NSWorkspace.shared.open(AppInfo.repositoryURL)
        })
        menu.addItem(ActionItem("Quit OpenLyrics", symbol: "xmark.circle", key: "q") {
            NSApp.terminate(nil)
        })
    }

    // MARK: - Now playing

    private func cardItem() -> NSMenuItem {
        let track = session.track
        let title: String = {
            if let track, !track.title.isEmpty { return track.title }
            switch coordinator.nowPlaying {
            case .noPlayer: return "Nothing playing"
            case .notAuthorized(let player): return "Can't read \(player.displayName)"
            default: return track == nil ? "Nothing playing" : "Unknown track"
            }
        }()
        let subtitle = track?.artist ?? (coordinator.nowPlaying == .noPlayer ? "Open Music or Spotify" : "")
        let colors = settings.lyricColors(accents: session.artworkAccents)
        let card = NowPlayingCard(
            title: title, subtitle: subtitle, status: statusLine, tone: tone,
            artwork: session.artwork, accent: colors.highlight.color
        )
        let host = NSHostingView(rootView: card)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let item = NSMenuItem()
        item.view = host
        return item
    }

    /// Actions that need the user: access to a player, or retrying unreachable lyrics services.
    private func attentionItems() -> [NSMenuItem] {
        if case .notAuthorized = coordinator.nowPlaying {
            return [
                ActionItem("Allow Access in System Settings…", symbol: "hand.raised") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                        NSWorkspace.shared.open(url)
                    }
                },
                ActionItem("Try Again", symbol: "arrow.clockwise") { [weak self] in self?.coordinator.refreshNowPlaying() },
            ]
        }
        if session.lookupState == .unavailable {
            return [ActionItem("Try Again", symbol: "arrow.clockwise") { [weak self] in self?.coordinator.reloadLyrics(bypassCache: true) }]
        }
        return []
    }

    private var tone: NowPlayingCard.Tone {
        switch coordinator.nowPlaying {
        case .notAuthorized: return .problem
        case .stopped, .noPlayer: return .quiet
        default: break
        }
        switch session.lookupState {
        case .found(.wordSynced, _), .found(.lineSynced, _): return .good
        case .searching: return .busy
        case .unavailable: return .problem
        default: return .quiet
        }
    }

    /// One line describing what OpenLyrics is doing.
    private var statusLine: String {
        switch coordinator.nowPlaying {
        case .stopped: return "Starting…"
        case .noPlayer: return "Waiting for a player"
        case .notAuthorized(let player): return "No access to \(player.displayName)"
        case .notPlaying where session.track == nil: return "Nothing playing"
        default: break
        }
        switch session.lookupState {
        case .idle: return "Nothing playing"
        case .searching: return "Looking for lyrics…"
        case .found(.wordSynced, let source): return "Word by word · \(Self.shortName(source))"
        case .found(.lineSynced, let source): return "Line by line · \(Self.shortName(source))"
        case .found(.unsynced, _): return "Only unsynced lyrics found"
        case .found(.instrumental, _): return "Instrumental"
        case .notFound: return "No lyrics found"
        case .unavailable: return "Lyrics services unreachable"
        }
    }

    private static func shortName(_ source: String) -> String {
        source == LyricsProviderID.netease.displayName ? "NetEase" : source
    }

    // MARK: - Builders

    private func toggle(_ title: String, symbol: String, _ keyPath: ReferenceWritableKeyPath<Settings, Bool>) -> NSMenuItem {
        ActionItem(title, symbol: symbol, checked: settings[keyPath: keyPath]) { [weak self] in
            guard let self else { return }
            self.settings[keyPath: keyPath].toggle()
        }
    }

    private func submenuItem(_ title: String, symbol: String) -> (NSMenuItem, NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        item.submenu = submenu
        return (item, submenu)
    }

    private func choice<Value: Equatable>(
        _ title: String, symbol: String, _ values: [Value], _ keyPath: ReferenceWritableKeyPath<Settings, Value>,
        title name: (Value) -> String, symbolFor valueSymbol: ((Value) -> String)? = nil
    ) -> NSMenuItem {
        let (item, submenu) = submenuItem(title, symbol: symbol)
        for value in values {
            submenu.addItem(ActionItem(name(value), symbol: valueSymbol?(value), checked: settings[keyPath: keyPath] == value) { [weak self] in
                self?.settings[keyPath: keyPath] = value
            })
        }
        return item
    }

    private func setMenu<Value: Hashable>(
        _ title: String, symbol: String, _ values: [Value], _ keyPath: ReferenceWritableKeyPath<Settings, Set<Value>>,
        title name: (Value) -> String
    ) -> NSMenuItem {
        let (item, submenu) = submenuItem(title, symbol: symbol)
        for value in values {
            submenu.addItem(ActionItem(name(value), checked: settings[keyPath: keyPath].contains(value)) { [weak self] in
                guard let self else { return }
                if self.settings[keyPath: keyPath].contains(value) {
                    self.settings[keyPath: keyPath].remove(value)
                } else {
                    self.settings[keyPath: keyPath].insert(value)
                }
            })
        }
        return item
    }

    private func reactItem() -> NSMenuItem {
        ActionItem("React to the Music", symbol: "ear", checked: settings.reactToMusic) { [weak self] in
            guard let self else { return }
            if self.settings.reactToMusic {
                self.settings.reactToMusic = false
            } else {
                self.coordinator.enableMusicReactions()
            }
        }
    }

    private func colorsMenu() -> NSMenuItem {
        let (item, submenu) = submenuItem("Colors", symbol: "paintpalette")
        let current = settings.lyricColors(accents: session.artworkAccents)
        item.image = Self.swatch(current.variants.map(\.highlight), size: 16)
        submenu.addItem(ActionItem("Auto Sync with Album", symbol: "photo", checked: settings.autoColors) { [weak self] in
            self?.settings.autoColors.toggle()
        })
        submenu.addItem(.separator())
        for style in Settings.ColorStyle.allCases {
            let symbol = style == .perWord ? "square.grid.3x1.below.line.grid.1x2" : "circle.lefthalf.filled"
            submenu.addItem(ActionItem(style.title, symbol: symbol, checked: settings.colorStyle == style) { [weak self] in
                self?.settings.colorStyle = style
            })
        }
        submenu.addItem(.separator())
        for role in Settings.ColorRole.allCases {
            let color: PaletteColor
            let shades: [PaletteColor]
            switch role {
            case .lyric:
                color = current.lyric
                shades = current.perWord ? current.variants.map(\.lyric) : [current.lyric, current.lyricEnd]
            case .highlight:
                color = current.highlight
                shades = current.perWord ? current.variants.map(\.highlight) : [current.highlight, current.highlightEnd]
            case .secondary:
                color = current.secondary
                shades = current.perWord ? current.variants.map(\.secondary) : [current.secondary, current.secondaryEnd]
            }
            let entry = ActionItem("\(role.title)…") { [weak self] in
                guard let self else { return }
                ColorPicker.shared.pick(role.title, starting: color) { [weak self] picked in
                    self?.settings.setCustomColor(picked, for: role, current: current)
                }
            }
            entry.image = Self.swatch(shades, size: 14)
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        submenu.addItem(ActionItem("Reset Colors", symbol: "arrow.uturn.backward") { [weak self] in self?.settings.resetColors() })
        return item
    }

    /// A rounded square showing `colors`: side-by-side stripes for per-word colors, a blend for a
    /// gradient.
    private static func swatch(_ colors: [PaletteColor], size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: size * 0.25, yRadius: size * 0.25)
            guard colors.count > 1 else {
                (colors.first ?? .white).nsColor.setFill()
                shape.fill()
                return true
            }
            if colors.count == 2 {
                NSGradient(starting: colors[0].nsColor, ending: colors[1].nsColor)?.draw(in: shape, angle: -45)
                return true
            }
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            let stripe = rect.width / CGFloat(colors.count)
            for (index, color) in colors.enumerated() {
                color.nsColor.setFill()
                NSRect(x: rect.minX + CGFloat(index) * stripe, y: rect.minY, width: stripe + 0.5, height: rect.height).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    private func displayMenu() -> NSMenuItem {
        let (item, submenu) = submenuItem("Display", symbol: "display")
        submenu.addItem(ActionItem("Main Display", checked: settings.displayID == 0) { [weak self] in
            self?.settings.displayID = 0
        })
        submenu.addItem(.separator())
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            submenu.addItem(ActionItem(screen.localizedName, checked: settings.displayID == id) { [weak self] in
                self?.settings.displayID = id
            })
        }
        return item
    }

    private func timingMenu() -> NSMenuItem {
        let offset = settings.syncOffset
        let label = offset == 0 ? "In Sync" : String(format: "%+.2f s", offset)
        let (item, submenu) = submenuItem("Timing: \(label)", symbol: "timer")
        submenu.addItem(ActionItem("Show Lyrics Sooner", symbol: "backward", key: "]") { [weak self] in
            self?.settings.nudgeOffset(by: Settings.offsetStep)
        })
        submenu.addItem(ActionItem("Show Lyrics Later", symbol: "forward", key: "[") { [weak self] in
            self?.settings.nudgeOffset(by: -Settings.offsetStep)
        })
        submenu.addItem(.separator())
        submenu.addItem(ActionItem("Reset Timing", symbol: "arrow.uturn.backward", enabled: offset != 0) { [weak self] in
            self?.settings.syncOffset = 0
        })
        return item
    }
}
