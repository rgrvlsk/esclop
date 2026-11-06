// SPDX-License-Identifier: GPL-3.0-or-later
//
// The menu bar glyph: the clog from assets/menubar.svg, as a template PDF in this module's
// resources, so macOS tints it for light and dark menu bars. Paused dims it.

import AppKit
import SwiftUI

public struct MenuBarLabel: View {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    /// 28 × 18 pt, the size the artwork was drawn for. nil only if the resource went missing.
    static let customGlyph: NSImage? = {
        guard let url = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "pdf"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18 * image.size.width / max(image.size.height, 1), height: 18)
        return image
    }()

    public var body: some View {
        Group {
            if let glyph = Self.customGlyph {
                Image(nsImage: glyph).renderingMode(.template).opacity(model.paused ? 0.45 : 1)
            } else {
                Image(systemName: model.paused ? "pause.circle" : "arrow.down.right.and.arrow.up.left")
            }
        }
        .accessibilityLabel(model.paused ? "L'Esclop, paused" : "L'Esclop")
    }
}
