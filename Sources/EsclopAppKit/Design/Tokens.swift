// SPDX-License-Identifier: GPL-3.0-or-later
//
// The design overhaul's tokens (docs/design/proposal.md › Tokens, direction A): one green with
// one job, pinned inks for the floating surfaces, six radii, a 4 pt grid and the type scale.
// Surfaces move onto these one pull request at a time; until a surface has moved it keeps
// `Palette` and `Metrics`.

import AppKit
import SwiftUI

/// Colours. `saving` marks the saving and nothing else: the figure and the saved part of a bar,
/// at most one green figure per surface.
public enum Ink {
    /// The saving figure and the saved part of a bar.
    public static let saving = Color(nsColor: Palette.dynamic(light: 0x176B59, dark: 0x63D6B8))
    /// Aggressive compression, as a mark (the bolt): 3:1 on a floating surface.
    public static let warm = Color(nsColor: Palette.dynamic(light: 0x8F5510, dark: 0xE0A040))
    /// The failure triangle; the sentence beside it is set in `text`.
    public static let error = Color(nsColor: Palette.dynamic(light: 0xC4281C, dark: 0xFF6961))
    /// Text on a floating surface: black at 88 % or white at 92 %, never the system's vibrant label.
    public static let text = PinnedInk(light: 0.88, dark: 0.92)
    /// Secondary text on a floating surface: 62 %, and 80 % under Increase Contrast.
    public static let secondary = PinnedInk(light: 0.62, dark: 0.62, increased: 0.80)
    /// A lit drop tile: one fill in both appearances, so its white text always holds 4.5:1.
    public static let lit = Color(nsColor: Palette.color(0x0A60D8))
    /// A lit tile in aggressive mode.
    public static let litWarm = Color(nsColor: Palette.color(0x8F5510))
    /// Text and symbols on a lit tile.
    public static let onLit = Color.white
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

/// Concentric radii, outer = inner + padding. Controls on a floating surface are capsules or circles.
public enum Radius {
    /// Key caps, 40 pt thumbnails in lists.
    public static let key: CGFloat = 6
    /// The card's picture; anything inside a panel or popover (22 − 12).
    public static let inner: CGFloat = 10
    /// The card, the detail's picture.
    public static let card: CGFloat = 14
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
    /// Between pointer targets.
    public static let hitGap: CGFloat = 4
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
}

/// The one elevation every floating object shares.
public enum Elevation {
    public static let shadowY: CGFloat = 8
    public static let shadowBlur: CGFloat = 24
    public static func shadowOpacity(dark: Bool) -> Double { dark ? 0.45 : 0.20 }
    /// The inner rim, white.
    public static func rimOpacity(dark: Bool) -> Double { dark ? 0.14 : 0.35 }
    /// The outer hairline, black.
    public static func hairlineOpacity(dark: Bool) -> Double { dark ? 0.30 : 0.10 }
}
