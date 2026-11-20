import AppKit

/// Shows the system color panel for one of the lyric colors and reports each change as the user
/// drags through it.
@MainActor
final class ColorPicker: NSObject {
    static let shared = ColorPicker()
    private var onChange: ((PaletteColor) -> Void)?
    /// The color the panel opened with. The panel can report it back without the user touching
    /// anything (setting its color sends the action), which isn't a change and mustn't turn Auto
    /// Sync off.
    private var starting: PaletteColor?

    func pick(_ title: String, starting color: PaletteColor, onChange: @escaping (PaletteColor) -> Void) {
        self.onChange = nil
        let panel = NSColorPanel.shared
        panel.title = title
        panel.showsAlpha = false
        panel.color = color.nsColor
        starting = PaletteColor(panel.color)
        self.onChange = onChange
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(panelClosed(_:)), name: NSWindow.willCloseNotification, object: panel)
        // A menu-bar app isn't active on its own; the panel needs it to come forward.
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard let color = PaletteColor(sender.color), !color.isClose(to: starting) else { return }
        starting = nil
        onChange?(color)
    }

    /// A closed panel reports nothing more.
    @objc private func panelClosed(_ notification: Notification) {
        onChange = nil
        starting = nil
    }
}

extension PaletteColor {
    /// Within a rounding error of `other` in every channel.
    func isClose(to other: PaletteColor?) -> Bool {
        guard let other else { return false }
        return abs(red - other.red) < 0.004 && abs(green - other.green) < 0.004 && abs(blue - other.blue) < 0.004
    }

    /// Any color with an sRGB equivalent; nil for pattern colors and the like.
    init?(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(red: Double(srgb.redComponent), green: Double(srgb.greenComponent), blue: Double(srgb.blueComponent))
    }
}

extension NSScreen {
    /// The display's CoreGraphics ID.
    var displayID: UInt32? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }
}
