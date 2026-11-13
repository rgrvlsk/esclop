// SPDX-License-Identifier: GPL-3.0-or-later
//
// The design tokens from DESIGN.md: one warning colour, the panel geometry and the
// three durations. Views use these names, never raw values.

import AppKit
import SwiftUI

extension View {
    /// The default action of a window or sheet: prominent, in the app's accent colour
    /// (`Ink.charcoal`, from the asset catalog), like the switches.
    func primaryButton() -> some View {
        buttonStyle(.borderedProminent)
    }
}

public enum Palette {
    /// Aggressive mode, "fit under size".
    public static let warm = Color(nsColor: dynamic(light: 0xB8741C, dark: 0xE0A040))
    /// A folder L'Esclop cannot watch: 3:1 or more on a Settings row, marked or not (4.1:1 light, 4.6:1 dark).
    public static let caution = Color(nsColor: dynamic(light: 0x9A5B0E, dark: 0xE0A040))
    /// Error text on a Settings or editor row: 5.3:1 light, 5.0:1 dark (system red is 3.4:1 in light).
    public static let error = Color(nsColor: dynamic(light: 0xC4281C, dark: 0xFF6961))

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
    // The floating result (DESIGN.md › Layout): concentric radii, 12 pt shell around a 9 pt
    // picture as a thumbnail, 24 pt card around a 12 pt picture as the detail.
    public static let thumbnailWidth: CGFloat = 200
    public static let thumbnailPadding: CGFloat = 3
    public static let thumbnailRadius: CGFloat = 12
    public static let pictureRadius: CGFloat = 9
    public static let detailWidth: CGFloat = 320
    public static let detailPadding: CGFloat = 12
    public static let detailRadius: CGFloat = 24
    public static let detailPictureRadius: CGFloat = 12
    /// The capsule hangs this far below the thumbnail's bottom edge.
    public static let capsuleOverhang: CGFloat = 16
    /// Between the thumbnail's bottom edge and an error capsule hanging below it.
    public static let errorCapsuleGap: CGFloat = 6
    public static let toolSize: CGFloat = 28
    public static let toolGap: CGFloat = 7
    /// Space between the thumbnail and its row of buttons.
    public static let toolLift: CGFloat = 10
    public static let activityWidth: CGFloat = 204
    public static let activityHeight: CGFloat = 76
    /// How far the activity capsule tucks under the thumbnail.
    public static let activityTuck: CGFloat = 14
    /// Between one result's capsule and the next thumbnail: clear air, not touching.
    public static let stackGap: CGFloat = 12
    /// Space between the results and the screen edge; also room for the glass shadow.
    public static let screenMargin: CGFloat = 16

    // The drop zone keeps the earlier card geometry.
    public static let dropZoneWidth: CGFloat = 300
    public static let panelRadius: CGFloat = 12
    public static let controlRadius: CGFloat = 6
    public static let dropZoneIcon: CGFloat = 44
}

public enum Motion {
    /// Thumbnail enters: slide from the screen edge, 220 ms.
    public static let enter = Animation.timingCurve(0.2, 0.75, 0.25, 1, duration: 0.22)
    /// The result: one deflate spring, 450 ms, the capsule counting down over the same time.
    public static let deflateDuration: TimeInterval = 0.45
    public static let count = Animation.easeOut(duration: 0.45)
    public static let hover = Animation.easeOut(duration: 0.18)
    /// Detail opens from the anchor, 400 ms spring; its bar contracts in 450 ms.
    public static let detail = Animation.spring(duration: 0.4, bounce: 0.15)
    public static let bar = Animation.spring(duration: 0.45, bounce: 0.1)
    /// The activity capsule grows from the left edge, 350 ms.
    public static let activity = Animation.spring(duration: 0.35, bounce: 0.1)
    /// What reduce motion turns slides, deflate, morphs and the sheen into.
    public static let crossfade = Animation.easeInOut(duration: 0.18)
    public static let leave = Animation.easeOut(duration: 0.22)
}
