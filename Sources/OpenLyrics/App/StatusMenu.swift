import AppKit

/// A menu item that runs a closure.
private final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, checked: Bool? = nil,
         enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        keyEquivalentModifierMask = modifiers
        if let checked { state = checked ? .on : .off }
        isEnabled = enabled
    }

    required init(coder: NSCoder) {
        fatalError("ActionItem does not support NSCoder")
    }

    @objc private func run() {
        handler()
    }
}

/// The menu-bar icon and its menu: what's playing, where the lyrics come from, and every setting.
/// The menu is rebuilt each time it opens, so it always shows the current state.
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
        for item in nowPlayingItems() { menu.addItem(item) }
        menu.addItem(.separator())

        menu.addItem(toggle("Show on Desktop", \.showOnDesktop))
        let lockItem = toggle(coordinator.lockScreenAvailable ? "Show on Lock Screen" : "Show on Lock Screen (unavailable)", \.showOnLockScreen)
        lockItem.isEnabled = coordinator.lockScreenAvailable
        menu.addItem(lockItem)
        menu.addItem(choice("Position", Settings.Position.allCases, \.position, title: \.title))
        menu.addItem(choice("Text Size", Settings.TextSize.allCases, \.textSize, title: \.title))
        menu.addItem(choice("Colors", Settings.ColorMode.allCases, \.colorMode, title: \.title))
        menu.addItem(toggle("Show Next Line", \.showNextLine))
        menu.addItem(toggle("Keep Display Awake on Lock Screen", \.keepAwakeWhenLocked))
        menu.addItem(.separator())

        menu.addItem(timingMenu())
        menu.addItem(ActionItem("Reload Lyrics", key: "r", enabled: session.track != nil) { [weak self] in
            self?.coordinator.reloadLyrics(bypassCache: true)
        })
        menu.addItem(ActionItem("Preview Lock-Screen Layout", enabled: coordinator.lockScreenAvailable && session.hasSyncedLyrics) { [weak self] in
            self?.coordinator.previewLockScreen()
        })
        menu.addItem(.separator())

        menu.addItem(setMenu("Lyrics Sources", LyricsProviderID.allCases, \.providers, title: \.displayName))
        menu.addItem(setMenu("Players", NowPlayingMonitor.Player.allCases, \.players, title: \.displayName))
        menu.addItem(ActionItem("Open at Login", checked: LaunchAtLogin.state == .enabled) {
            LaunchAtLogin.setEnabled(LaunchAtLogin.state != .enabled)
        })
        menu.addItem(ActionItem("Clear Lyrics Cache") { [weak self] in
            self?.coordinator.clearLyricsCache()
        })
        menu.addItem(.separator())
        menu.addItem(ActionItem("OpenLyrics \(AppInfo.version) on GitHub") {
            NSWorkspace.shared.open(AppInfo.repositoryURL)
        })
        menu.addItem(ActionItem("Quit OpenLyrics", key: "q") {
            NSApp.terminate(nil)
        })
    }

    // MARK: - Now playing

    private func nowPlayingItems() -> [NSMenuItem] {
        if case .notAuthorized(let player) = coordinator.nowPlaying {
            return [
                disabled("OpenLyrics can't read \(player.displayName)"),
                ActionItem("Allow in System Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                        NSWorkspace.shared.open(url)
                    }
                },
                ActionItem("Try Again") { [weak self] in self?.coordinator.refreshNowPlaying() },
            ]
        }
        var items: [NSMenuItem] = []
        if let track = session.track {
            let title = track.title.isEmpty ? "Unknown track" : track.title
            let header = disabled(title)
            header.attributedTitle = NSAttributedString(
                string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
            )
            items.append(header)
            if !track.artist.isEmpty { items.append(disabled(track.artist)) }
        }
        items.append(disabled(statusLine))
        if session.lookupState == .unavailable {
            items.append(ActionItem("Try Again") { [weak self] in self?.coordinator.reloadLyrics(bypassCache: true) })
        }
        return items
    }

    /// One line describing what OpenLyrics is doing.
    private var statusLine: String {
        switch coordinator.nowPlaying {
        case .stopped: return "Starting…"
        case .noPlayer: return "Open Music or Spotify and play something"
        case .notAuthorized(let player): return "No access to \(player.displayName)"
        case .notPlaying where session.track == nil: return "Nothing playing"
        default: break
        }
        switch session.lookupState {
        case .idle: return "Nothing playing"
        case .searching: return "Looking for lyrics…"
        case .found(.wordSynced, let source): return "Word-by-word lyrics from \(source)"
        case .found(.lineSynced, let source): return "Line-synced lyrics from \(source)"
        case .found(.unsynced, _): return "Only unsynced lyrics found"
        case .found(.instrumental, _): return "Instrumental"
        case .notFound: return "No lyrics found"
        case .unavailable: return "Couldn't reach any lyrics service"
        }
    }

    // MARK: - Builders

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func toggle(_ title: String, _ keyPath: ReferenceWritableKeyPath<Settings, Bool>) -> NSMenuItem {
        ActionItem(title, checked: settings[keyPath: keyPath]) { [weak self] in
            guard let self else { return }
            self.settings[keyPath: keyPath].toggle()
        }
    }

    private func choice<Value: Equatable>(
        _ title: String, _ values: [Value], _ keyPath: ReferenceWritableKeyPath<Settings, Value>, title name: (Value) -> String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for value in values {
            submenu.addItem(ActionItem(name(value), checked: settings[keyPath: keyPath] == value) { [weak self] in
                self?.settings[keyPath: keyPath] = value
            })
        }
        item.submenu = submenu
        return item
    }

    private func setMenu<Value: Hashable>(
        _ title: String, _ values: [Value], _ keyPath: ReferenceWritableKeyPath<Settings, Set<Value>>, title name: (Value) -> String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
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
        item.submenu = submenu
        return item
    }

    private func timingMenu() -> NSMenuItem {
        let offset = settings.syncOffset
        let label = offset == 0 ? "in sync" : String(format: "%+.2f s", offset)
        let item = NSMenuItem(title: "Timing (\(label))", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(ActionItem("Show Lyrics Sooner", key: "]") { [weak self] in
            self?.settings.nudgeOffset(by: Settings.offsetStep)
        })
        submenu.addItem(ActionItem("Show Lyrics Later", key: "[") { [weak self] in
            self?.settings.nudgeOffset(by: -Settings.offsetStep)
        })
        submenu.addItem(ActionItem("Reset Timing", enabled: offset != 0) { [weak self] in
            self?.settings.syncOffset = 0
        })
        item.submenu = submenu
        return item
    }
}
