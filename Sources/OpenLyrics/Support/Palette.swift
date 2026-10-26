import AppKit
import SwiftUI

/// An sRGB color with 0...1 components. A plain value (unlike `NSColor`/`CGColor`) so palettes can
/// be compared and handed between threads.
struct PaletteColor: Hashable, Sendable, Codable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }

    static let white = PaletteColor(red: 1, green: 1, blue: 1)
}

/// The two colors `ColorExtractor` reads from album artwork. `primary` fills the words as they're
/// sung; `secondary` tints the soft glow around the active word.
struct ArtworkPalette: Hashable, Sendable, Codable {
    var primary: PaletteColor
    var secondary: PaletteColor
    /// The primary's share of the artwork's color, 0...1. Unused by the lyrics; kept so
    /// `ColorExtractor` stays as it is in Open Glow.
    var balance: Double

    /// Plain white, for artwork that can't be read and for the "White" color setting.
    static let fallback = ArtworkPalette(primary: .white, secondary: PaletteColor(red: 0.85, green: 0.88, blue: 1), balance: 0.5)
}
