// SPDX-License-Identifier: GPL-3.0-or-later
//
// The design tokens from DESIGN.md: one accent, one warning colour, the panel geometry and the
// three durations. Views use these names, never raw values.

import AppKit
import SwiftUI

public enum Palette {
    /// Savings, progress, primary actions.
    public static let accent = Color(nsColor: dynamic(light: 0x1E7F6A, dark: 0x3DBF9F))
    /// Aggressive mode, "fit under size".
    public static let warm = Color(nsColor: dynamic(light: 0xB8741C, dark: 0xE0A040))

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
    public static let cardWidth: CGFloat = 300
    public static let panelRadius: CGFloat = 10
    public static let controlRadius: CGFloat = 6
    public static let stackGap: CGFloat = 8
    /// Space between the stack and the screen edge; also room for the panel shadow.
    public static let screenMargin: CGFloat = 16
    public static let thumbnail: CGFloat = 44
}

public enum Motion {
    /// The deflate: one spring, 450 ms.
    public static let deflate = Animation.spring(duration: 0.45, bounce: 0.12)
    public static let hover = Animation.easeOut(duration: 0.18)
    public static let cards = Animation.easeOut(duration: 0.22)
    /// What reduce motion turns the deflate into.
    public static let crossfade = Animation.easeInOut(duration: 0.22)
}
