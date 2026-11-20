// SPDX-License-Identifier: GPL-3.0-or-later
//
// PDF operations that need no external tool: non-destructive crop (setting each page's crop box)
// and uncrop. They run through PDFKit, so they need no engine and never re-encode the document's
// content. Pages export as images through `EsclopEngine.extractPDFPages`.

import CoreGraphics
import EsclopCore
import Foundation
import PDFKit

public struct PDFPageTools: Sendable {
    public init() {}

    /// Sets every page's crop box to `spec`'s aspect ratio, centred. Returns the page count.
    @discardableResult
    public func crop(_ source: URL, spec: PDFCropSpec, to output: URL) throws -> Int {
        guard spec.aspectRatio > 0, spec.aspectRatio.isFinite else {
            throw EsclopError.invalidArgument("The aspect ratio must be a positive number")
        }
        let document = try open(source)
        try PDFSignature.refuseSigned(source)
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
        try PDFSignature.refuseSigned(source)
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            page.setBounds(page.bounds(for: .mediaBox), for: .cropBox)
        }
        try write(document, to: output, replacing: source)
        return document.pageCount
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
}
