// SPDX-License-Identifier: GPL-3.0-or-later
//
// The design overhaul's tokens (docs/design/proposal.md › Tokens, and the owner's visual
// grammar in docs/design/targets/README.md, which wins over it): one green with one job, an
// opaque cream material, charcoal for what is selected or on, aqua for work in progress, amber
// for what needs a decision, brick red for the original size, six radii, a 4 pt grid and the type
// scale. There is no system blue. Surfaces move onto these one pull request at a time; until a
// surface has moved it keeps `Palette` and `Metrics`.

import AppKit
import SwiftUI

/// Inks. Each signal has one meaning on every surface.
public enum Ink {
    /// The saving: the figure, and the arc or ring of a finished result. Nothing else.
    public static let saving = Color(nsColor: Palette.dynamic(light: 0x176B59, dark: 0x63D6B8))
    /// The original size, beside the new one in grey.
    public static let original = Color(nsColor: Palette.dynamic(light: 0xB83A2B, dark: 0xE0705E))
    /// Needs a decision (a suggestion, a failure, a missing permission), and the aggressive mark: 3:1.
    public static let warm = Color(nsColor: Palette.dynamic(light: 0x8F5510, dark: 0xE0A040))
    /// The failure triangle; the sentence beside it is set in `text`.
    public static let error = Color(nsColor: Palette.dynamic(light: 0xC4281C, dark: 0xFF6961))
    /// The straight bar of work in progress, on `Surface.progress`. Progress is never a ring.
    public static let progress = Color(nsColor: Palette.dynamic(light: 0x1F8A80, dark: 0x5FD0C2))
    /// Text: black at 88 % or white at 92 %.
    public static let text = PinnedInk(light: 0.88, dark: 0.92)
    /// Secondary text, and the new size; darker (lighter in dark) under Increase Contrast.
    public static let secondary = ToneInk(light: 0x625C56, dark: 0xB9AFA5, increasedLight: 0x48433E, increasedDark: 0xD6CDC3)
    /// Selected or on: a selected tile or chip, a switch that is on, the most likely action.
    /// The app's accent colour (`assets/Accent.xcassets`, `NSAccentColorName`) is the same.
    public static let charcoal = Color(nsColor: Palette.dynamic(light: 0x36322E, dark: 0x7A7068))
    /// Text and symbols on `charcoal`.
    public static let onCharcoal = Color.white
    /// Charcoal as ink: a text button, a word or symbol marked done or on. In dark it is the
    /// text ink, since dark charcoal is a fill and holds only 3.1:1 as text on the surface.
    public static let charcoalText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.92)
            : Palette.color(0x36322E)
    })
}

/// Fills.
public enum Surface {
    /// The one material every floating object shares, and the content of every window: opaque,
    /// so the ground under the ink is the same over any desktop.
    public static let cream = Color(nsColor: Palette.dynamic(light: 0xF6F0E8, dark: 0x2B2521))
    /// Resting content inside a surface. In dark it is inset, darker than the surface: brick red
    /// on anything lighter than the surface falls under 4.5:1.
    public static let tile = Color(nsColor: Palette.dynamic(light: 0xFBF8F3, dark: 0x241F1B))
    /// Work in progress.
    public static let progress = Color(nsColor: Palette.dynamic(light: 0xDCF2EE, dark: 0x1F3D3A))
    /// Needs a decision.
    public static let decision = Color(nsColor: Palette.dynamic(light: 0xFBE6BF, dark: 0x4A3517))
}

/// A colour for each appearance, and another for each under Increase Contrast.
public struct ToneInk: ShapeStyle, Sendable {
    public var light: UInt32
    public var dark: UInt32
    public var increasedLight: UInt32
    public var increasedDark: UInt32

    public func hex(dark isDark: Bool, increasedContrast: Bool = false) -> UInt32 {
        switch (isDark, increasedContrast) {
        case (false, false): light
        case (true, false): dark
        case (false, true): increasedLight
        case (true, true): increasedDark
        }
    }

    public func resolve(in environment: EnvironmentValues) -> Color {
        Color(nsColor: Palette.color(hex(dark: environment.colorScheme == .dark, increasedContrast: environment.colorSchemeContrast == .increased)))
    }
}

/// Neutral fills on a floating surface, in the appearance's own ink: resting, a button or a
/// selected tile, pressed.
public enum NeutralFill {
    public static let resting = PinnedInk(light: 0.06, dark: 0.06)
    public static let button = PinnedInk(light: 0.14, dark: 0.14)
    public static let pressed = PinnedInk(light: 0.20, dark: 0.20)
}

/// Black in light, white in dark, at a fixed strength. The glass sits under the content, so the
/// system never swaps this for a vibrant colour chosen from the desktop.
public struct PinnedInk: ShapeStyle, Sendable {
    public var light: Double
    public var dark: Double
    /// The strength under Increase Contrast, when it differs.
    public var increased: Double?

    public init(light: Double, dark: Double, increased: Double? = nil) {
        self.light = light
        self.dark = dark
        self.increased = increased
    }

    public func opacity(dark isDark: Bool, increasedContrast: Bool = false) -> Double {
        let base = isDark ? dark : light
        guard increasedContrast, let increased else { return base }
        return max(base, increased)
    }

    public func resolve(in environment: EnvironmentValues) -> Color {
        let isDark = environment.colorScheme == .dark
        return Color(white: isDark ? 1 : 0, opacity: opacity(dark: isDark, increasedContrast: environment.colorSchemeContrast == .increased))
    }
}

/// Radii. The result card's own are in `Metrics`. Controls on a floating surface are capsules or circles.
public enum Radius {
    /// Key caps, 40 pt thumbnails in lists.
    public static let key: CGFloat = 6
    /// Drop tiles.
    public static let tile: CGFloat = 18
    /// The detail, the menu panel, the popover.
    public static let panel: CGFloat = 22
}

/// The 4 pt grid, and the distances between things.
public enum Spacing {
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    /// Every pointer target is at least this wide and tall.
    public static let hit: CGFloat = 28
    /// Between floating objects.
    public static let floating: CGFloat = 8
    /// Between drop tiles.
    public static let tiles: CGFloat = 12
}

/// SF Pro at 13, 12 or 11 pt; the compressed figure is `Figure`'s alone.
public enum Typeface {
    public static let title = Font.system(size: 13, weight: .semibold)
    /// A document's title.
    public static let documentTitle = Font.system(size: 22, weight: .semibold)
    /// A panel state ("Paused").
    public static let stateTitle = Font.system(size: 24, weight: .semibold)
    public static let firstRunTitle = Font.system(size: 28, weight: .semibold)
    public static let body = Font.system(size: 13)
    /// A label on a floating surface.
    public static let label = Font.system(size: 12, weight: .medium)
    /// Secondary. Nothing is smaller, anywhere.
    public static let caption = Font.system(size: 11)
    /// The one heading of a surface, in New York: a window or the panel ("Today").
    public static let heading = Font.system(size: 28, weight: .medium, design: .serif)
    /// The one heading of a popover or a card.
    public static let smallHeading = Font.system(size: 20, weight: .medium, design: .serif)
    /// One section label per tile ("SAVED"), in small caps; never data. Use `sectionLabel()`.
    public static let section = Font.system(size: 11, weight: .semibold)
}

extension View {
    /// A tile's section label: small caps, tracked, in secondary ink.
    public func sectionLabel() -> some View {
        font(Typeface.section).textCase(.uppercase).tracking(1.6).foregroundStyle(Ink.secondary)
    }
}

/// The one elevation every floating object shares.
public enum Elevation {
    // Measured off docs/design/targets: pr2-result-card-states, where the shadow is gone 15 pt
    // below the card.
    public static let shadowY: CGFloat = 5
    public static let shadowBlur: CGFloat = 16
    public static func shadowOpacity(dark: Bool) -> Double { dark ? 0.45 : 0.14 }
    /// The inner rim, white.
    public static func rimOpacity(dark: Bool) -> Double { dark ? 0.14 : 0.35 }
    /// The outer hairline, black.
    public static func hairlineOpacity(dark: Bool) -> Double { dark ? 0.30 : 0.10 }
}
