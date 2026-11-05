// SPDX-License-Identifier: GPL-3.0-or-later
//
// PDF operations that need no external tool: non-destructive crop (setting each page's crop box),
// uncrop, and exporting pages as images. They run through PDFKit, so they work before the bundled
// ghostscript exists and never re-encode the document's content.

import CoreGraphics
import EsclopCore
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public struct PDFPageTools: Sendable {
    public init() {}

    /// Sets every page's crop box to `spec`'s aspect ratio, centred. Returns the page count.
    @discardableResult
    public func crop(_ source: URL, spec: PDFCropSpec, to output: URL) throws -> Int {
        guard spec.aspectRatio > 0, spec.aspectRatio.isFinite else {
            throw EsclopError.invalidArgument("The aspect ratio must be a positive number")
        }
        let document = try open(source)
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let media = page.bounds(for: .mediaBox)
            let box = Self.cropRect(media: media, rotation: page.rotation, spec: spec)
            if spec.extend {
                page.setBounds(box.union(media), for: .mediaBox)
            }
            page.setBounds(box, for: .cropBox)
        }
        try write(document, to: output, replacing: source)
        return document.pageCount
    }

    /// Resets every page's crop box to its media box. Returns the page count.
    @discardableResult
    public func uncrop(_ source: URL, to output: URL) throws -> Int {
        let document = try open(source)
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            page.setBounds(page.bounds(for: .mediaBox), for: .cropBox)
        }
        try write(document, to: output, replacing: source)
        return document.pageCount
    }

    /// Renders pages (1-based numbers, all when nil) as PNG or JPEG files in `folder`.
    public func exportPages(_ source: URL, pages: [Int]?, format: OutputFormat, dpi: Double, into folder: URL) throws -> [URL] {
        guard format == .png || format == .jpeg else {
            throw EsclopError.invalidArgument("Pages export as png or jpeg")
        }
        guard dpi >= 18, dpi <= 1200 else { throw EsclopError.invalidArgument("DPI must be between 18 and 1200") }
        let document = try open(source)
        let wanted = pages ?? Array(1 ... max(1, document.pageCount))
        if let bad = wanted.first(where: { $0 < 1 || $0 > document.pageCount }) {
            throw EsclopError.invalidArgument("Page \(bad) is outside 1...\(document.pageCount)")
        }
        try Paths.ensure(folder)
        let base = source.deletingPathExtension().lastPathComponent
        let digits = String(document.pageCount).count
        let type: UTType = format == .png ? .png : .jpeg
        var written: [URL] = []
        for number in wanted {
            guard let page = document.page(at: number - 1) else { continue }
            let image = try render(page, scale: dpi / 72, opaque: format == .jpeg)
            let name = "\(base)-\(String(repeating: "0", count: max(0, digits - String(number).count)))\(number).\(format.rawValue)"
            let url = folder.appendingPathComponent(name)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
                throw EsclopError.other("Cannot write \(url.path)")
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw EsclopError.other("Cannot write \(url.path)") }
            written.append(url)
        }
        return written
    }

    /// The crop box for one page. `rotation` swaps the ratio for pages displayed sideways.
    static func cropRect(media: CGRect, rotation: Int, spec: PDFCropSpec) -> CGRect {
        let sideways = (rotation % 180) != 0
        var ratio = sideways ? 1 / spec.aspectRatio : spec.aspectRatio
        if spec.matchOrientation {
            let pageIsLandscape = media.width > media.height
            let ratioIsLandscape = ratio > 1
            if pageIsLandscape != ratioIsLandscape, abs(ratio - 1) > 0.0001 { ratio = 1 / ratio }
        }
        var rect = media
        let pageIsWider = media.width / media.height > ratio
        if spec.extend == pageIsWider {
            // Keep the width: a taller page loses height, a wider one (extending) gains it.
            rect.size.height = media.width / ratio
            rect.origin.y = media.minY + (media.height - rect.height) / 2
        } else {
            rect.size.width = media.height * ratio
            rect.origin.x = media.minX + (media.width - rect.width) / 2
        }
        return rect
    }

    private func open(_ source: URL) throws -> PDFDocument {
        guard FileManager.default.fileExists(atPath: source.path) else { throw EsclopError.fileNotFound(source.path) }
        guard let document = PDFDocument(url: source) else { throw EsclopError.unsupportedFile(source.path) }
        guard !document.isLocked else { throw EsclopError.notPermitted("\(source.lastPathComponent) is password protected") }
        return document
    }

    private func write(_ document: PDFDocument, to output: URL, replacing source: URL) throws {
        try Paths.ensure(output.deletingLastPathComponent())
        let staging = output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.lastPathComponent).esclop-\(UUID().uuidString.prefix(8))")
        guard document.write(to: staging) else {
            try? FileManager.default.removeItem(at: staging)
            throw EsclopError.other("Cannot write \(output.path)")
        }
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: output)
        }
    }

    private func render(_ page: PDFPage, scale: Double, opaque: Bool) throws -> CGImage {
        let bounds = page.bounds(for: .cropBox)
        let sideways = (page.rotation % 180) != 0
        let width = Int(((sideways ? bounds.height : bounds.width) * scale).rounded())
        let height = Int(((sideways ? bounds.width : bounds.height) * scale).rounded())
        guard width > 0, height > 0, width * height < 400_000_000,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { throw EsclopError.other("Cannot render a \(width)x\(height) page") }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { throw EsclopError.other("Cannot render page") }
        return image
    }
}
