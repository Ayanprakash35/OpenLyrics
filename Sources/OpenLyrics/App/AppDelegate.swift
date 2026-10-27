import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: LyricsCoordinator?
    private var statusMenu: StatusMenuController?
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu-bar app: no Dock icon, no main menu, never the active app on its own.
        NSApp.setActivationPolicy(.accessory)
        let coordinator = LyricsCoordinator(settings: .shared)
        statusMenu = StatusMenuController(coordinator: coordinator)
        self.coordinator = coordinator
        coordinator.start()
        quitCleanlyOnTerminationSignal()
    }

    /// SIGTERM (logout, `kill`, a system update) would otherwise end the process on the spot,
    /// skipping `applicationWillTerminate` and leaving the audio tap registered.
    private func quitCleanlyOnTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        source.resume()
        terminationSignal = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }
}
