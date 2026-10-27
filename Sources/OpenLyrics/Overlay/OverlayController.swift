import AppKit
import SwiftUI
import os

/// Overlay tuning.
enum OverlayConfig {
    /// Seconds the overlay takes to fade in or out. Sane range: 0.15–0.6.
    static let fadeDuration: TimeInterval = 0.35
    /// Seconds "Preview Lock-Screen Layout" shows the lock-screen overlay on the desktop.
    static let previewDuration: TimeInterval = 8
}

/// One borderless, transparent, click-through window covering a screen, hosting the lyrics.
///
/// Shown and hidden by its alpha, never by ordering out: the lock-screen window lives on a private
/// space (see `LockScreenSpace`), and ordering a window out and in again isn't guaranteed to keep
/// it there. While hidden, the SwiftUI content is hidden too, which stops its animation timeline.
@MainActor
final class OverlayWindow {
    let surface: OverlaySurface
    private let logger = Logger(subsystem: "com.openlyrics.app", category: "Overlay")
    private let window: NSWindow
    /// The frame the window should have: its screen's, in global coordinates.
    private var screenFrame: NSRect
    private let hosting: NSHostingView<LyricsOverlayView>
    private let session: LyricsSession
    private let settings: Settings
    private let audio: () -> AudioAnalysisState
    private var insets: EdgeInsets
    private(set) var isVisible = false

    init(screen: NSScreen, surface: OverlaySurface, session: LyricsSession, settings: Settings,
         audio: @escaping () -> AudioAnalysisState, lockSpace: LockScreenSpace?) {
        self.surface = surface
        self.session = session
        self.settings = settings
        self.audio = audio
        screenFrame = Self.frame(for: screen)
        insets = Self.insets(of: screen)
        hosting = NSHostingView(rootView: LyricsOverlayView(
            session: session, settings: settings, surface: surface, screenInsets: Self.insets(of: screen), audio: audio,
            isVisible: false
        ))
        hosting.isHidden = true
        // With `screen:` given, AppKit adds the screen's origin to contentRect itself.
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: screen.frame.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = true
        window.alphaValue = 0
        window.contentView = hosting
        window.setFrame(screenFrame, display: false)
        if surface == .lockScreen {
            lockSpace?.adopt(window)
        }
        window.orderFrontRegardless()
    }

    func setVisible(_ visible: Bool, animated: Bool = true) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            // The window server can resize a window on a private space (seen: the lock-screen window
            // 97 pt taller than its screen); put it back before it shows.
            if window.frame != screenFrame {
                logger.notice("\(String(describing: self.surface), privacy: .public) window was \(NSStringFromRect(self.window.frame), privacy: .public); resetting to its screen")
                window.setFrame(screenFrame, display: false)
            }
            hosting.isHidden = false
            updateRoot()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? OverlayConfig.fadeDuration : 0
            window.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isVisible else { return }
                self.hosting.isHidden = true
                self.updateRoot()
            }
        }
    }

    func updateScreen(_ screen: NSScreen) {
        screenFrame = Self.frame(for: screen)
        window.setFrame(screenFrame, display: true)
        insets = Self.insets(of: screen)
        updateRoot()
        // Ordering front again is harmless on the desktop and re-asserts the window after a
        // display change; the lock-screen window keeps its space.
        window.orderFrontRegardless()
    }

    /// Rebuilds the SwiftUI root with the current insets and visibility.
    private func updateRoot() {
        hosting.rootView = LyricsOverlayView(
            session: session, settings: settings, surface: surface, screenInsets: insets, audio: audio, isVisible: isVisible
        )
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    private static func frame(for screen: NSScreen) -> NSRect {
        Diagnostics.isOffscreen ? screen.frame.offsetBy(dx: -100_000, dy: -100_000) : screen.frame
    }

    /// The menu bar's and Dock's share of the screen.
    private static func insets(of screen: NSScreen) -> EdgeInsets {
        let frame = screen.frame, visible = screen.visibleFrame
        return EdgeInsets(
            top: frame.maxY - visible.maxY,
            leading: visible.minX - frame.minX,
            bottom: visible.minY - frame.minY,
            trailing: frame.maxX - visible.maxX
        )
    }
}

/// Decides where lyrics show — the desktop, the lock screen, or nowhere — and keeps one window for
/// each on the main display (the one with the menu bar).
@MainActor
final class OverlayController {
    struct Conditions: Equatable {
        var hasLyrics: Bool
        var isPlaying: Bool
        var session: SessionPauseReasons
        var showOnDesktop: Bool
        var showOnLockScreen: Bool
        var lockScreenAvailable: Bool
        var previewingLockScreen: Bool
    }

    struct Visibility: Equatable {
        var desktop: Bool
        var lockScreen: Bool
    }

    private let logger = Logger(subsystem: "com.openlyrics.app", category: "Overlay")
    private let session: LyricsSession
    private let settings: Settings
    private let audio: () -> AudioAnalysisState
    let lockSpace: LockScreenSpace
    private var desktop: OverlayWindow?
    private var lockScreen: OverlayWindow?
    private var screenID: CGDirectDisplayID?
    private var previewTask: Task<Void, Never>?
    private(set) var isPreviewingLockScreen = false
    private(set) var visibility = Visibility(desktop: false, lockScreen: false)

    /// Main actor, when the preview starts or ends, so the owner can re-evaluate visibility.
    var onPreviewChange: (() -> Void)?

    init(session: LyricsSession, settings: Settings, audio: @escaping () -> AudioAnalysisState) {
        self.session = session
        self.settings = settings
        self.audio = audio
        lockSpace = LockScreenSpace(level: settings.lockScreenSpaceLevel ?? LockScreenSpaceConfig.defaultLevel)
        rebuildForScreens()
    }

    /// Pure: where the lyrics show under `conditions`. Nothing shows while the displays or the
    /// system sleep, the screen saver runs, or another user has the screen; while locked, only the
    /// lock-screen overlay may show.
    nonisolated static func visibility(for conditions: Conditions) -> Visibility {
        let content = conditions.hasLyrics && conditions.isPlaying
        let locked = conditions.session.contains(.screenLocked)
        let otherReasons = conditions.session.subtracting(.screenLocked)
        let desktop = content && conditions.showOnDesktop && !locked && otherReasons.isEmpty
        let lockAllowed = conditions.lockScreenAvailable && otherReasons.isEmpty
        let lockScreen = lockAllowed && (
            (content && conditions.showOnLockScreen && locked) || (conditions.previewingLockScreen && conditions.hasLyrics)
        )
        return Visibility(desktop: desktop && !conditions.previewingLockScreen, lockScreen: lockScreen)
    }

    func apply(_ conditions: Conditions) {
        let new = Self.visibility(for: conditions)
        guard new != visibility else { return }
        visibility = new
        logger.info("Overlay: desktop \(new.desktop, privacy: .public), lock screen \(new.lockScreen, privacy: .public)")
        desktop?.setVisible(new.desktop)
        lockScreen?.setVisible(new.lockScreen)
    }

    /// Shows the lock-screen overlay on the unlocked desktop for a few seconds, to check how it
    /// looks without locking the Mac.
    func previewLockScreen() {
        previewTask?.cancel()
        isPreviewingLockScreen = true
        onPreviewChange?()
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(OverlayConfig.previewDuration))
            guard !Task.isCancelled else { return }
            self?.isPreviewingLockScreen = false
            self?.onPreviewChange?()
        }
    }

    /// Makes or moves the windows when displays are added, removed or rearranged, or the chosen
    /// display changes. A chosen display that isn't connected falls back to the main one.
    func rebuildForScreens() {
        let chosen = settings.displayID == 0 ? nil : NSScreen.screens.first { $0.displayID == settings.displayID }
        guard let screen = chosen ?? NSScreen.screens.first else {
            desktop?.close()
            lockScreen?.close()
            desktop = nil
            lockScreen = nil
            screenID = nil
            return
        }
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        if id == screenID, let desktop, let lockScreen {
            desktop.updateScreen(screen)
            lockScreen.updateScreen(screen)
            return
        }
        desktop?.close()
        lockScreen?.close()
        screenID = id
        desktop = OverlayWindow(screen: screen, surface: .desktop, session: session, settings: settings, audio: audio, lockSpace: nil)
        lockScreen = OverlayWindow(screen: screen, surface: .lockScreen, session: session, settings: settings, audio: audio, lockSpace: lockSpace)
        desktop?.setVisible(visibility.desktop, animated: false)
        lockScreen?.setVisible(visibility.lockScreen, animated: false)
    }
}
