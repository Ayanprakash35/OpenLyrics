import AppKit

/// Shows the system color panel for one of the lyric colors and reports each change as the user
/// drags through it.
@MainActor
final class ColorPicker: NSObject {
    static let shared = ColorPicker()
    private var onChange: ((PaletteColor) -> Void)?

    func pick(_ title: String, starting color: PaletteColor, onChange: @escaping (PaletteColor) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.title = title
        panel.showsAlpha = false
        panel.color = color.nsColor
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        // A menu-bar app isn't active on its own; the panel needs it to come forward.
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard let color = PaletteColor(sender.color) else { return }
        onChange?(color)
    }
}

extension PaletteColor {
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
