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
        try await engine(input, to: output, dpi: dpi, factor: plan.factor(for: .pdf, format: .pdf, env: env), strip: plan.strip, progress: progress)
        if let sourceMax, dpi < sourceMax {
            steps.append("Downsampled images from \(sourceMax) to \(dpi) dpi")
        } else if dpi < PDFResolution.noDownsampleDPI {
            steps.append("Images at most \(dpi) dpi")
        } else {
            steps.append("Recompressed without downsampling")
        }
        return Produced(url: output, width: nil, height: nil, duration: nil, steps: steps, allowLarger: plan.crop != nil)
    }

    /// How long one `pdf.optimise` may take (what Ghostscript was given).
    static let timeout: TimeInterval = 1800

    /// `pdf.optimise`: 300 dpi means no downsampling. A result that is not smaller comes back
    /// as the engine's `already_smaller`, which the caller treats like any other optimiser's.
    func engine(_ input: URL, to output: URL, dpi: Int, factor: Int, strip: Bool, progress: ProgressSink) async throws {
        _ = try await env.images.call("pdf.optimise", input: input, output: output, params: [
            "dpi": .int(dpi < PDFResolution.noDownsampleDPI ? dpi : 0),
            "compression": .int(factor),
            "strip": .bool(strip),
            "allow_larger": true,
        ], timeout: Self.timeout, progress: { progress($0) })
        guard PDFDocument(url: output) != nil else {
            throw EsclopError.toolFailed(tool: Tool.esclopEngine.rawValue, exitCode: 0, stderr: "esclop-engine wrote an unreadable PDF")
        }
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
        throw EsclopError.other("Could not fit under \(ByteFormat.string(target)); the smallest attempt was \(ByteFormat.string(smallest)) at \(stops.last ?? PDFResolution.minDPI) dpi")
    }

    /// `pdf.optimise` without downsampling, at the lightest compression, drops the document
    /// info, the XMP, thumbnails and application data.
    func stripMetadata(_ source: URL, work: WorkFolder) async throws -> Produced {
        _ = try document(source)
        let output = work.file(stem: "stripped", ext: "pdf")
        try await engine(source, to: output, dpi: PDFResolution.noDownsampleDPI, factor: 0, strip: true, progress: .none)
        return Produced(url: output, width: nil, height: nil, duration: nil, steps: ["Removed document metadata"], allowLarger: true)
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
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            page.setBounds(page.bounds(for: .mediaBox), for: .cropBox)
        }
        let output = work.file(stem: "uncropped", ext: "pdf")
        guard document.write(to: output) else { throw EsclopError.other("Could not write the PDF") }
        return Produced(url: output, width: nil, height: nil, duration: nil, steps: ["Restored the full pages"], allowLarger: true)
    }

    /// Renders pages to PNG or JPEG files in `folder` (`<name>-<page>.<ext>`).
    func extractPages(_ source: URL, format: OutputFormat, dpi: Int, to folder: URL) throws -> [URL] {
        let document = try document(source)
        guard format == .png || format == .jpeg else {
            throw EsclopError.invalidArgument("Pages render to PNG or JPEG")
        }
        try Paths.ensure(folder)
        let stem = source.deletingPathExtension().lastPathComponent
        let scale = Double(max(18, min(dpi, 1200))) / 72
        var urls: [URL] = []
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .cropBox)
            let rotated = page.rotation % 180 != 0
            let width = Int((rotated ? bounds.height : bounds.width) * scale)
            let height = Int((rotated ? bounds.width : bounds.height) * scale)
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .cropBox, to: context)
            guard let image = context.makeImage() else { continue }
            let url = folder.appendingPathComponent("\(stem)-\(index + 1)").appendingPathExtension(format.fileExtension)
            try ImageIOCodec.write(image, to: url, type: format == .png ? .png : .jpeg, quality: format == .jpeg ? 0.85 : nil, strip: true)
            urls.append(url)
        }
        return urls
    }
}
