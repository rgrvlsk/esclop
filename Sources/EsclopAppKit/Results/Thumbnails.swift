// SPDX-License-Identifier: GPL-3.0-or-later
//
// Quick Look thumbnails for the cards: images, the first frame of a video, a PDF's first page.

import AppKit
import QuickLookThumbnailing

enum Thumbnails {
    static func load(_ url: URL, side: CGFloat = Metrics.detailWidth, scale: CGFloat = 2) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side), scale: scale, representationTypes: .thumbnail
        )
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }
}
