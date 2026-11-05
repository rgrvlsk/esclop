// SPDX-License-Identifier: GPL-3.0-or-later
//
// The menu bar glyph. A template image named `MenuBarIcon` in the app bundle's resources wins
// (the bundle step puts the final clog glyph there); until then a system symbol stands in.

import AppKit
import SwiftUI

public struct MenuBarLabel: View {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    static let customGlyph: NSImage? = {
        guard let url = ["pdf", "png", "svg"].lazy.compactMap({ Bundle.main.url(forResource: "MenuBarIcon", withExtension: $0) }).first,
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18 * image.size.width / max(image.size.height, 1), height: 18)
        return image
    }()

    public var body: some View {
        Group {
            if let glyph = Self.customGlyph {
                Image(nsImage: glyph).opacity(model.paused ? 0.45 : 1)
            } else {
                Image(systemName: model.paused ? "pause.circle" : "arrow.down.right.and.arrow.up.left")
            }
        }
        .accessibilityLabel(model.paused ? "L'Esclop, paused" : "L'Esclop")
    }
}
