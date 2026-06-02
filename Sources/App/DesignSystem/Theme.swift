import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

/// Warm cream and espresso theme tokens used by the redesigned settings UI.
enum Theme {
    // MARK: Surfaces
    static let background = Color(light: 0xF4EEE5, dark: 0x1C1612)
    static let surface = Color(light: 0xFBF7F0, dark: 0x251E18)
    static let card = Color(light: 0xFFFFFF, dark: 0x2C241D)
    static let sidebar = Color(light: 0xECE4D6, dark: 0x18130F)
    static let rowHover = Color(light: 0xF6EFE1, dark: 0x312820)

    // MARK: Lines
    static let line = Color(light: 0x3C2814, dark: 0xFFDCB4, lightAlpha: 0.10, darkAlpha: 0.08)
    static let lineStrong = Color(light: 0x3C2814, dark: 0xFFDCB4, lightAlpha: 0.16, darkAlpha: 0.14)

    // MARK: Text
    static let text = Color(light: 0x2A1F12, dark: 0xF5ECDF)
    static let text2 = Color(light: 0x5A4A36, dark: 0xC8B89E)
    static let text3 = Color(light: 0x8A7A64, dark: 0x968670)
    static let textMuted = Color(light: 0xA99A82, dark: 0x6C5E4A)

    // MARK: Accents
    static let accent = Color(light: 0xD97757, dark: 0xE9876B)
    static let accentSoft = Color(light: 0xD97757, dark: 0xE9876B, lightAlpha: 0.13, darkAlpha: 0.18)
    static let accentLine = Color(light: 0xD97757, dark: 0xE9876B, lightAlpha: 0.35, darkAlpha: 0.38)

    static let green = Color(light: 0x1A8B6E, dark: 0x1A8B6E)
    static let greenSoft = Color(light: 0x1A8B6E, dark: 0x1A8B6E, lightAlpha: 0.13, darkAlpha: 0.18)
    static let orange = Color(light: 0xC87A2E, dark: 0xC87A2E)
    static let red = Color(light: 0xC8453D, dark: 0xC8453D)
    static let blue = Color(light: 0x2A6FDB, dark: 0x2A6FDB)
    static let blueSoft = Color(light: 0x2A6FDB, dark: 0x2A6FDB, lightAlpha: 0.13, darkAlpha: 0.18)

    // MARK: Geometry
    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 18
    }
}

// MARK: - Color convenience

extension Color {
    /// Opaque RGB literal, written as 0xRRGGBB.
    init(_ hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b, opacity: alpha)
    }

    /// Light and dark pair with optional per-mode alphas.
    init(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        #if canImport(AppKit)
        self = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            let hex = isDark ? dark : light
            let alpha = isDark ? darkAlpha : lightAlpha
            let r = CGFloat((hex >> 16) & 0xFF) / 255
            let g = CGFloat((hex >> 8) & 0xFF) / 255
            let b = CGFloat(hex & 0xFF) / 255
            return NSColor(red: r, green: g, blue: b, alpha: CGFloat(alpha))
        })
        #else
        self.init(light, alpha: lightAlpha)
        #endif
    }
}
