import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: LyricsCoordinator?
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu-bar app: no Dock icon, no main menu, never the active app on its own.
        NSApp.setActivationPolicy(.accessory)
        let coordinator = LyricsCoordinator(settings: .shared)
        statusMenu = StatusMenuController(coordinator: coordinator)
        self.coordinator = coordinator
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }
}
