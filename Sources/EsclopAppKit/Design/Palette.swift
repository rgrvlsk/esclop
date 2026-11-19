// SPDX-License-Identifier: GPL-3.0-or-later
//
// The design tokens from DESIGN.md: the caution colour, the panel geometry and the
// three durations. Views use these names, never raw values.

import AppKit
import SwiftUI

extension View {
    /// The default action of a window or sheet: prominent, in charcoal like the switches.
    func primaryButton() -> some View {
        buttonStyle(.borderedProminent).tint(Ink.charcoal)
    }

    /// Every root that can hold a control (a window, a panel, a popover, a sheet) pins the tint:
    /// macOS applies the bundle's accent colour only under the Multicolour system accent, so with
    /// Blue chosen a default button, a switch or a checkbox would be system blue. Charcoal as ink,
    /// since SwiftUI also sets bordered buttons' and menus' labels in the tint, and dark charcoal is
    /// a fill (3.1:1 as text). A switch or slider that should show the charcoal fill in dark sets
    /// `Ink.charcoal` itself.
    public func designTint() -> some View {
        tint(Ink.charcoalText)
    }
}

public enum Palette {
    /// A folder L'Esclop cannot watch: 3:1 or more on a Settings row, marked or not (4.1:1 light, 4.6:1 dark).
    public static let caution = Color(nsColor: dynamic(light: 0x9A5B0E, dark: 0xE0A040))
    /// Error text on a Settings or editor row; `Ink.error` owns it.
    public static var error: Color { Ink.error }

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return color(isDark ? dark : light)
        }
    }

    static func color(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1
        )
    }
}

public enum Metrics {
    // The floating result's card, measured off docs/design/targets: pr2-result-card-states: 208 pt
    // wide, a 14 pt picture inset 9 pt in the 20 pt card. The target's corners are not concentric
    // (20 − 9 = 11), and the picture reads as a photo in a mount because of it.
    public static let thumbnailWidth: CGFloat = 208
    public static let thumbnailPadding: CGFloat = 9
    public static let thumbnailRadius: CGFloat = 20
    public static let pictureRadius: CGFloat = 14
    public static let detailWidth: CGFloat = 320
    public static let detailPadding: CGFloat = 12
    public static let detailRadius: CGFloat = 24
    public static let detailPictureRadius: CGFloat = 12
    /// A round button on a floating surface: the smallest pointer target.
    public static let toolSize: CGFloat = 28
    /// Between two results: clear air, and room for the hovered one's glow.
    public static let stackGap: CGFloat = 12
    /// Space between the results and the screen edge; also room for the glass shadow.
    public static let screenMargin: CGFloat = 16

    /// The drop zone's panel: the options popover's radius, so the two read as one family.
    public static let dropZoneRadius: CGFloat = 22
    public static let panelRadius: CGFloat = 12
    public static let controlRadius: CGFloat = 6
}

public enum Motion {
    /// Thumbnail enters: slide from the screen edge, 220 ms.
    public static let enter = Animation.timingCurve(0.2, 0.75, 0.25, 1, duration: 0.22)
    /// The result: one deflate spring, 450 ms.
    public static let deflateDuration: TimeInterval = 0.45
    public static let hover = Animation.easeOut(duration: 0.18)
    /// Detail opens from the anchor, 400 ms spring; its bar contracts in 450 ms.
    public static let detail = Animation.spring(duration: 0.4, bounce: 0.15)
    public static let bar = Animation.spring(duration: 0.45, bounce: 0.1)
    /// What reduce motion turns slides, deflate, morphs and the sheen into.
    public static let crossfade = Animation.easeInOut(duration: 0.18)
    public static let leave = Animation.easeOut(duration: 0.22)
}
