import AppKit
import os

/// Lock-screen space tuning.
enum LockScreenSpaceConfig {
    /// The space's absolute level. The window server stacks whole spaces by this number, and the
    /// lock screen itself sits at 300 (kCGSSpaceAbsoluteLevelScreenLock); 400 is the level of the
    /// notifications shown over the lock screen, so lyrics appear exactly where those do. 500 would
    /// cover boot progress. Override with `defaults write com.openlyrics.app lockScreenSpaceLevel`.
    static let defaultLevel: Int32 = 400
    /// The flags argument of SLSSpaceAddWindowsAndRemoveFromSpaces: move the windows rather than
    /// add them alongside their current spaces.
    static let moveFlags: Int32 = 7
}

/// A private window-server space that draws above the lock screen, for the lock-screen overlay.
///
/// macOS has no public way to show a window over the lock screen. Its window server, SkyLight,
/// stacks spaces by an absolute level, and a space created above the lock screen's level shows its
/// windows there. The five SkyLight calls used are looked up at runtime: if a future macOS drops
/// any of them, `isAvailable` is false and OpenLyrics keeps working on the desktop only.
///
/// Windows on this space draw above every ordinary space too — including the unlocked desktop — so
/// the lock-screen overlay keeps its window invisible except while the screen is locked.
@MainActor
final class LockScreenSpace {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, UnsafeRawPointer?) -> UInt64
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Void
    private typealias AddWindowsAndRemoveFromSpaces = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void

    private static let frameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
    private let logger = Logger(subsystem: "com.openlyrics.app", category: "LockScreen")
    private let connection: Int32
    private let space: UInt64
    private let addWindows: AddWindowsAndRemoveFromSpaces?

    /// Whether windows can be put on the lock screen on this Mac.
    let isAvailable: Bool

    init(level: Int32 = LockScreenSpaceConfig.defaultLevel) {
        guard let handle = dlopen(Self.frameworkPath, RTLD_LAZY),
              let mainConnectionID = Self.symbol("SLSMainConnectionID", in: handle, as: MainConnectionID.self),
              let spaceCreate = Self.symbol("SLSSpaceCreate", in: handle, as: SpaceCreate.self),
              let setLevel = Self.symbol("SLSSpaceSetAbsoluteLevel", in: handle, as: SpaceSetAbsoluteLevel.self),
              let showSpaces = Self.symbol("SLSShowSpaces", in: handle, as: ShowSpaces.self),
              let addWindows = Self.symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", in: handle, as: AddWindowsAndRemoveFromSpaces.self)
        else {
            connection = 0
            space = 0
            addWindows = nil
            isAvailable = false
            logger.error("SkyLight calls not found; lyrics won't show on the lock screen")
            return
        }
        let connection = mainConnectionID()
        let space = spaceCreate(connection, 1, nil)
        guard connection != 0, space != 0 else {
            self.connection = 0
            self.space = 0
            self.addWindows = nil
            isAvailable = false
            logger.error("Couldn't create the lock-screen space (connection \(connection), space \(space))")
            return
        }
        setLevel(connection, space, level)
        showSpaces(connection, [NSNumber(value: space)] as CFArray)
        self.connection = connection
        self.space = space
        self.addWindows = addWindows
        isAvailable = true
        logger.notice("Lock-screen space \(space, privacy: .public) at level \(level, privacy: .public)")
    }

    /// Moves `window` onto the lock-screen space. The window needs a window number, so call this
    /// once it has been created (it needn't be visible yet).
    @discardableResult
    func adopt(_ window: NSWindow) -> Bool {
        guard isAvailable, let addWindows, window.windowNumber > 0 else { return false }
        window.canBecomeVisibleWithoutLogin = true
        addWindows(connection, space, [NSNumber(value: window.windowNumber)] as CFArray, LockScreenSpaceConfig.moveFlags)
        return true
    }

    private static func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer, as type: T.Type) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
}
