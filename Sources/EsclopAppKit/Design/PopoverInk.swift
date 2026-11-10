// SPDX-License-Identifier: GPL-3.0-or-later
//
// The options popover's colours, as explicit values. The system's vibrant secondary and
// tertiary styles take their contrast from whatever is behind the popover's glass, and in dark
// mode over a light desktop they nearly vanished (UI check, N1). The popover now lays its own
// near-opaque surface over the glass and draws every text and icon in a colour whose contrast
// is computed here: at least 4.5:1 for text and 3:1 for icons, light and dark, with the surface
// over a white and over a black desktop. `PopoverInkTests` checks every pair.

import AppKit
import SwiftUI

/// A colour with straight (not premultiplied) alpha, 0...1.
public struct RGBA: Equatable, Sendable {
    public var r, g, b, a: Double

    public init(_ hex: UInt32, alpha: Double = 1) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
        a = alpha
    }

    init(r: Double, g: Double, b: Double, a: Double) {
        (self.r, self.g, self.b, self.a) = (r, g, b, a)
    }

    public static let white = RGBA(0xFFFFFF)
    public static let black = RGBA(0x000000)

    /// This colour drawn over an opaque one.
    public func over(_ below: RGBA) -> RGBA {
        RGBA(r: r * a + below.r * (1 - a), g: g * a + below.g * (1 - a), b: b * a + below.b * (1 - a), a: 1)
    }

    /// WCAG 2 relative luminance.
    public var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// WCAG 2 contrast ratio between two opaque colours.
    public static func contrast(_ a: RGBA, _ b: RGBA) -> Double {
        let (l1, l2) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (l1 + 0.05) / (l2 + 0.05)
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

public enum PopoverInk {
    public struct Token: Sendable {
        public var name: String
        public var light: RGBA
        public var dark: RGBA
        /// Icons need 3:1, text 4.5:1.
        public var isIcon = false

        public var color: Color {
            let (light, dark) = (light.nsColor, dark.nsColor)
            return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? dark : light })
        }
    }

    /// Laid over the popover's glass: nearly opaque, so the desktop behind barely shows.
    public static let surface = Token(name: "Surface", light: RGBA(0xF7F7F7, alpha: 0.94), dark: RGBA(0x2A2C2E, alpha: 0.94))
    public static let primary = Token(name: "Text", light: RGBA(0x1D1F20), dark: RGBA(0xF2F3F4))
    /// Labels, section names, estimates, sizes, shortcuts, footers.
    public static let secondary = Token(name: "Secondary text", light: RGBA(0x575C61), dark: RGBA(0xB3B8BD))
    /// Row icons, chevrons, the restore arrow.
    public static let icon = Token(name: "Icons", light: RGBA(0x6B7076), dark: RGBA(0x9DA3A9), isIcon: true)
    /// Accent as text: savings, "Applied", the selected tile and chip, links.
    public static let accent = Token(name: "Accent text", light: RGBA(0x135E4E), dark: RGBA(0x4CC9A9))
    /// "Aggressive".
    public static let warm = Token(name: "Aggressive", light: RGBA(0x8F560E), dark: RGBA(0xE6A94C))
    /// The selected tile and chip fill behind accent text: the accent at 12 %.
    public static let selectedFill = Token(name: "Selected fill", light: RGBA(0x1E7F6A, alpha: 0.12), dark: RGBA(0x3DBF9F, alpha: 0.12))

    /// Every foreground the popover draws, checked against the surface.
    public static let foregrounds = [primary, secondary, icon, accent, warm]

    /// The surface as it lands on screen over `desktop`, in one appearance.
    public static func ground(dark: Bool, desktop: RGBA, selected: Bool = false) -> RGBA {
        var ground = (dark ? surface.dark : surface.light).over(desktop)
        if selected { ground = (dark ? selectedFill.dark : selectedFill.light).over(ground) }
        return ground
    }

    /// The contrast of `token` on the popover over `desktop`.
    public static func contrast(_ token: Token, dark: Bool, desktop: RGBA, selected: Bool = false) -> Double {
        let ground = ground(dark: dark, desktop: desktop, selected: selected)
        let ink = (dark ? token.dark : token.light).over(ground)
        return RGBA.contrast(ink, ground)
    }
}
