// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pictures for the compare canvas. Images are decoded with ImageIO; PDF pages are drawn from
// their media box (as Clop does: an optimised PDF's crop box can differ from the original's, and
// the two sides must line up), so pages zoom, split and show differences like images. The
// difference is a red mask where the two pictures differ, the optimised one first scaled to the
// original's size.

import AppKit
import CoreImage
import Foundation
import ImageIO
import PDFKit

enum CompareMedia {
    /// The first frame of an image file.
    static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceShouldCache: true, kCGImageSourceShouldAllowFloat: false]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    static func pageCount(of url: URL) -> Int {
        PDFDocument(url: url)?.pageCount ?? 0
    }

    /// Page `index` of a PDF, drawn from its media box with the long edge at `longEdge` pixels.
    static func page(_ index: Int, of url: URL, longEdge: CGFloat = 2400) -> CGImage? {
        guard let page = PDFDocument(url: url)?.page(at: index) else { return nil }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = longEdge / max(box.width, box.height)
        let size = CGSize(width: (box.width * scale).rounded(), height: (box.height * scale).rounded())
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    struct Difference: Sendable {
        /// Red where the pictures differ, clear elsewhere, at the original's proportions.
        var mask: CGImage
        /// The share of pixels that differ noticeably, 0 to 1.
        var changed: Double
    }

    /// Where `after` differs from `before`. Differences are amplified so that compression
    /// artefacts a few levels deep show; `threshold` (0 to 1) decides what counts as changed.
    static func difference(_ before: CGImage, _ after: CGImage, threshold: Double = 0.04) -> Difference? {
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        // At most 2048 pixels on the long edge: enough to see where artefacts are, cheap to count.
        let original = CIImage(cgImage: before)
        let reduce = min(1, 2048 / max(original.extent.width, original.extent.height))
        let a = original.transformed(by: CGAffineTransform(scaleX: reduce, y: reduce))
        var b = CIImage(cgImage: after)
        b = b.transformed(by: CGAffineTransform(scaleX: a.extent.width / b.extent.width, y: a.extent.height / b.extent.height))
        let target = CGRect(origin: .zero, size: CGSize(width: a.extent.width.rounded(), height: a.extent.height.rounded()))

        guard let blend = CIFilter(name: "CIDifferenceBlendMode") else { return nil }
        blend.setValue(b, forKey: kCIInputImageKey)
        blend.setValue(a, forKey: kCIInputBackgroundImageKey)
        guard let diff = blend.outputImage?.cropped(to: target) else { return nil }
        let width = Int(target.width), height = Int(target.height)
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(diff, toBitmap: &pixels, rowBytes: width * 4, bounds: target, format: .RGBA8, colorSpace: nil)
        // The mask: red, its opacity the largest channel difference, amplified 6 times.
        var mask = [UInt8](repeating: 0, count: width * height * 4)
        var changed = 0
        let cut = UInt8(min(255, max(1, threshold * 255)))
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let delta = max(pixels[i], pixels[i + 1], pixels[i + 2])
            if delta >= cut { changed += 1 }
            let alpha = UInt8(min(255, Int(delta) * 6))
            // Premultiplied red.
            mask[i] = alpha
            mask[i + 3] = alpha
        }
        guard let provider = CGDataProvider(data: Data(mask) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }
        return Difference(mask: image, changed: Double(changed) / Double(width * height))
    }

    /// "PNG", "JPEG", "MP4": the file's format as a person names it.
    static func formatName(_ url: URL) -> String {
        CardPresentation.formatName(of: url)
    }
}
