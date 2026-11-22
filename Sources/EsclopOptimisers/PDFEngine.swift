// SPDX-License-Identifier: GPL-3.0-or-later
//
// PDFs: esclop-engine's `pdf.optimise` recompresses and downsamples images at one of the DPI
// stops, subsets fonts and recompresses streams, refusing what it cannot rewrite faithfully;
// PDFKit crops pages to an aspect ratio, uncrops them and renders pages to images.

import AppKit
import EsclopCore
import Foundation
import PDFKit

struct PDFEngine: Sendable {
    let env: EngineEnvironment

    static var dpiStops: [Int] { PDFResolution.dpiStops }

    private func document(_ source: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: source), document.pageCount > 0 else {
            throw EsclopError.unreadable(kind: .pdf)
        }
        if document.isEncrypted, document.isLocked {
            throw EsclopError.notPermitted("\(source.lastPathComponent) is password protected")
        }
        return document
    }

    /// The resolution for this pass: the request, else the setting (0 = per document), one stop
    /// lower when aggressive, scaled by a downscale factor.
    func resolveDPI(for source: URL, plan: Plan) -> (dpi: Int, sourceMax: Int?) {
        var sourceMax: Int?
        var dpi: Int
        if let requested = plan.request.pdfDPI, requested > 0 {
            dpi = requested
        } else {
            let setting = env.value(EsclopSettings.pdfDPI)
            if setting == PDFResolution.adaptiveDPI {
                let analysis = PDFResolution.adaptiveDPI(for: source)
                dpi = analysis.dpi
                sourceMax = analysis.sourceMax
            } else {
                dpi = setting
            }
            let aggressive = plan.isAggressive || (plan.request.quality.tier == .normal && env.value(EsclopSettings.useAggressiveOptimisationPDF))
            if aggressive { dpi = PDFResolution.stepDown(from: dpi) }
        }
        if let factor = plan.downscale {
            dpi = PDFResolution.snap(Int(Double(dpi) * factor))
        }
        return (min(max(dpi, PDFResolution.minDPI), PDFResolution.maxDPI), sourceMax)
    }

    func process(_ source: URL, plan: Plan, work: WorkFolder, progress: ProgressSink) async throws -> Produced {
        if let format = plan.format, format != .pdf {
            throw EsclopError.invalidArgument("PDFs stay PDFs; use extractPDFPages to get images")
        }
        let document = try document(source)
        var input = source
        var steps: [String] = []
        if let crop = plan.crop, let aspect = crop.aspectRatioValue {
            try PDFSignature.refuseSigned(source)
            let cropped = work.file(stem: "cropped", ext: "pdf")
            try Self.crop(document, aspect: aspect, to: cropped)
            input = cropped
            steps.append("Cropped pages to \(crop.aspectRatio ?? String(aspect))")
            if plan.operation == .crop {
                return Produced(url: cropped, width: nil, height: nil, duration: nil, steps: steps, allowLarger: true)
            }
        }
        let (dpi, sourceMax) = resolveDPI(for: input, plan: plan)
        let output = work.file(stem: "optimised", ext: "pdf")
        let reply = try await engine(input, to: output, dpi: dpi, factor: plan.factor(for: .pdf, format: .pdf, env: env), strip: plan.strip, progress: progress)
        if let sourceMax, dpi < sourceMax, dpi < PDFResolution.noDownsampleDPI {
            steps.append("Downsampled images from \(sourceMax) to \(dpi) dpi")
        } else if dpi < PDFResolution.noDownsampleDPI {
            steps.append("Images at most \(dpi) dpi")
        } else {
            steps.append("Recompressed without downsampling")
        }
        return Produced(url: output, width: nil, height: nil, duration: nil, steps: steps, allowLarger: plan.crop != nil, lossless: reply.raw["lossy"] == .bool(false))
    }

    /// How long one `pdf.optimise` may take (what Ghostscript was given).
    static let timeout: TimeInterval = 1800

    /// `pdf.optimise`: 300 dpi means no downsampling. A result that is not smaller comes back
    /// as the engine's `already_smaller`, which the caller treats like any other optimiser's.
    /// A strip keeps the title (readers and screen readers show it) unless `keepTitle` is false:
    /// only Remove metadata itself drops it.
    @discardableResult
    func engine(
        _ input: URL, to output: URL, dpi: Int, factor: Int, strip: Bool, keepTitle: Bool = true, progress: ProgressSink
    ) async throws -> EngineReply {
        let reply = try await env.images.call("pdf.optimise", input: input, output: output, params: [
            "dpi": .int(dpi < PDFResolution.noDownsampleDPI ? dpi : 0),
            "compression": .int(factor),
            "strip": .bool(strip),
            "keep": .array(keepTitle ? [.string("title")] : []),
            "allow_larger": true,
        ], timeout: Self.timeout, progress: { progress($0) })
        guard PDFDocument(url: output) != nil else {
            throw EsclopError.toolFailed(tool: Tool.esclopEngine.rawValue, exitCode: 0, stderr: "esclop-engine wrote an unreadable PDF")
        }
        return reply
    }

    /// Walks down the DPI stops until the file fits.
    func fit(_ source: URL, under target: Int, plan: Plan, work: WorkFolder, progress: ProgressSink) async throws -> Produced {
        _ = try document(source)
        let start = resolveDPI(for: source, plan: plan).dpi
        var stops = PDFResolution.dpiStops.filter { $0 <= start }
        if stops.isEmpty { stops = [PDFResolution.minDPI] }
        var smallest = Int.max
        for (index, dpi) in stops.enumerated() {
            let output = work.file(stem: "fit-\(dpi)", ext: "pdf")
            try await engine(source, to: output, dpi: dpi, factor: plan.factor(for: .pdf, format: .pdf, env: env), strip: plan.strip,
                             progress: progress.scaled(Double(index) / Double(stops.count) ... Double(index + 1) / Double(stops.count)))
            let size = fileSize(output)
            smallest = min(smallest, size)
            if size <= target {
                return Produced(url: output, width: nil, height: nil, duration: nil, steps: ["Fit under \(ByteFormat.string(target)) at \(dpi) dpi"], allowLarger: true)
            }
        }
        throw EsclopError.cannotFit(underBytes: target, smallest: smallest == Int.max ? nil : smallest)
    }

    /// `pdf.optimise` without downsampling, at the lightest compression, drops the document
    /// info, the XMP, thumbnails and application data.
    /// Remove metadata drops the title too; an optimise that strips keeps it (`keepTitle`).
    func stripMetadata(_ source: URL, work: WorkFolder, keepTitle: Bool = false) async throws -> Produced {
        _ = try document(source)
        let output = work.file(stem: "stripped", ext: "pdf")
        try await engine(source, to: output, dpi: PDFResolution.noDownsampleDPI, factor: 0, strip: true, keepTitle: keepTitle, progress: .none)
        return Produced(url: output, width: nil, height: nil, duration: nil, steps: ["Removed document metadata"], allowLarger: true)
    }

    /// Whether the document information holds more than a title: an author, a creator or
    /// producer, a subject, keywords, dates.
    static func hasPersonalMetadata(_ url: URL) -> Bool {
        let attributes = PDFDocument(url: url)?.documentAttributes ?? [:]
        return [
            PDFDocumentAttribute.authorAttribute, .creatorAttribute, .producerAttribute, .subjectAttribute, .keywordsAttribute,
            .creationDateAttribute, .modificationDateAttribute,
        ].contains { attributes[$0] != nil }
    }

    // MARK: PDFKit

    /// Sets each page's crop box to the largest centred rectangle of `aspect` (width / height).
    static func crop(_ document: PDFDocument, aspect: Double, to output: URL) throws {
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let media = page.bounds(for: .mediaBox)
            // Rotated pages show their media box sideways.
            let rotated = page.rotation % 180 != 0
            let pageAspect = rotated ? 1 / aspect : aspect
            var width = media.width
            var height = width / pageAspect
            if height > media.height {
                height = media.height
                width = height * pageAspect
            }
            let rect = CGRect(x: media.midX - width / 2, y: media.midY - height / 2, width: width, height: height)
            page.setBounds(rect, for: .cropBox)
        }
        guard document.write(to: output) else { throw EsclopError.other("Could not write the cropped PDF") }
    }

    /// Resets every page's crop box to its media box.
    func uncrop(_ source: URL, work: WorkFolder) throws -> Produced {
        let document = try document(source)
        try PDFSignature.refuseSigned(source)
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            page.setBounds(page.bounds(for: .mediaBox), for: .cropBox)
        }
        let output = work.file(stem: "uncropped", ext: "pdf")
        guard document.write(to: output) else { throw EsclopError.other("Could not write the PDF") }
        return Produced(url: output, width: nil, height: nil, duration: nil, steps: ["Restored the full pages"], allowLarger: true)
    }

    /// Renders pages (1-based numbers, all when nil) as PNG or JPEG files in `folder`
    /// (`<name>-<page>`, zero-padded to the page count, JPEGs `.jpg`), all of them or none, under
    /// the next free name when one is taken: a page that cannot be rendered fails the export.
    /// Without a `format`, a page that is one photo becomes a JPEG and any other page a PNG. The
    /// one page exporter: `EsclopEngine.extractPDFPages` optimises what it writes.
    func extractPages(
        _ source: URL, pages: [Int]? = nil, format: OutputFormat?, dpi: Double, to folder: URL,
        render: (PDFPage, Double) -> CGImage? = Self.render
    ) throws -> [URL] {
        if let format, format != .png, format != .jpeg {
            throw EsclopError.invalidArgument("Pages export as png or jpeg")
        }
        guard dpi >= 18, dpi <= 1200 else { throw EsclopError.invalidArgument("DPI must be between 18 and 1200") }
        guard FileManager.default.fileExists(atPath: source.path) else { throw EsclopError.fileNotFound(source.path) }
        let document = try document(source)
        var seen = Set<Int>()
        let wanted = (pages ?? Array(1 ... document.pageCount)).filter { seen.insert($0).inserted }
        if let bad = wanted.first(where: { $0 < 1 || $0 > document.pageCount }) {
            throw EsclopError.invalidArgument("Page \(bad) is outside 1...\(document.pageCount)")
        }
        let base = source.deletingPathExtension().lastPathComponent
        let digits = String(document.pageCount).count
        let formats = wanted.map { number in
            format ?? (document.page(at: number - 1).map(Self.isOnePhoto) == true ? .jpeg : .png)
        }
        let names = wanted.indices.map { index in
            let number = String(wanted[index])
            return "\(base)-\(String(repeating: "0", count: max(0, digits - number.count)))\(number).\(formats[index] == .jpeg ? "jpg" : "png")"
        }
        return try StagedFiles.publish(names, into: folder) { index, url in
            guard let page = document.page(at: wanted[index] - 1), let image = render(page, dpi / 72) else {
                throw EsclopError.other("Could not render page \(wanted[index]) of \(source.lastPathComponent)")
            }
            let jpeg = formats[index] == .jpeg
            try ImageIOCodec.write(image, to: url, type: jpeg ? .jpeg : .png, quality: jpeg ? 0.9 : nil, strip: true, dpi: dpi)
        }
    }

    /// A page that only draws one picture, such as a scan or a photo: one image of 8 bits or more
    /// per component and no fonts or forms in its own resources. A 1-bit scan of text stays PNG,
    /// and so does a page whose resources are inherited (they read as none).
    static func isOnePhoto(_ page: PDFPage) -> Bool {
        guard let dictionary = page.pageRef?.dictionary else { return false }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return false }
        var fonts: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts, CGPDFDictionaryGetCount(fonts) > 0 { return false }
        var objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects, CGPDFDictionaryGetCount(objects) == 1 else {
            return false
        }
        var isImage = false
        CGPDFDictionaryApplyBlock(objects, { _, value, _ in
            var stream: CGPDFStreamRef?
            var subtype: UnsafePointer<CChar>?
            var bits: CGPDFInteger = 0
            if CGPDFObjectGetValue(value, .stream, &stream), let stream, let object = CGPDFStreamGetDictionary(stream),
               CGPDFDictionaryGetName(object, "Subtype", &subtype), let subtype
            {
                isImage = String(cString: subtype) == "Image" && CGPDFDictionaryGetInteger(object, "BitsPerComponent", &bits) && bits >= 8
            }
            return false
        }, nil)
        return isImage
    }

    /// One page on white at `scale` (1 = 72 dpi); nil when it cannot be drawn.
    static func render(_ page: PDFPage, scale: Double) -> CGImage? {
        let bounds = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let width = Int(((rotated ? bounds.height : bounds.width) * scale).rounded())
        let height = Int(((rotated ? bounds.width : bounds.height) * scale).rounded())
        guard width > 0, height > 0, width * height < 400_000_000, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }
}
