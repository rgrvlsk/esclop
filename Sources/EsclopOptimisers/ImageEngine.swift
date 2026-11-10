// SPDX-License-Identifier: GPL-3.0-or-later
//
// Images. The pixel work goes to `esclop-engine` (PNG, JPEG, WebP, AVIF, resize, crop, fit,
// metadata); GIFs to gifsicle; HEIC, TIFF, BMP, HDR gain maps and decoding of formats the engine
// does not read (HEIC, JPEG XL, AVIF, TIFF, BMP) to ImageIO. What runs where is decided per
// file from the engine's `hello` capabilities.

import AppKit
import EsclopCore
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

struct ImageEngine: Sendable {
    let env: EngineEnvironment

    /// Formats handed to the engine as they are; anything else is decoded to PNG first.
    static let engineReadable: Set<OutputFormat> = [.png, .jpeg, .webp, .gif]
    /// Formats written with ImageIO.
    static let imageIOFormats: Set<OutputFormat> = [.heic, .tiff, .bmp]

    struct Geometry {
        var crop: CGRect?
        var width: Int
        var height: Int
        var changed: Bool
    }

    // MARK: Optimise, convert, downscale, crop

    func process(_ source: URL, plan: Plan, work: WorkFolder, progress: ProgressSink) async throws -> Produced {
        guard let info = ImageInfo.probe(source), let sourceFormat = info.format else {
            throw Self.unreadableOrUnsupported(source)
        }
        let target = targetFormat(for: sourceFormat, info: info, plan: plan)
        if target == .pdf {
            return try imageToPDF(source, info: info, work: work)
        }
        guard target.kind == .image else {
            throw EsclopError.invalidArgument("Images convert to image formats or PDF, not \(target.rawValue)")
        }
        let factor = plan.factor(for: .image, format: target, env: env)
        let curves = Curves(factor)
        let geometry = try geometry(for: source, info: info, plan: plan)
        let formatChanged = target != sourceFormat
        var steps: [String] = []
        if formatChanged { steps.append("Converted \(sourceFormat.rawValue.uppercased()) to \(target.rawValue.uppercased())") }
        let allowLarger = plan.allowsLarger(formatChanged: formatChanged)

        if sourceFormat == .gif, target == .gif {
            return try await gifsicle(source, info: info, geometry: geometry, curves: curves, strip: plan.strip, work: work, steps: steps, allowLarger: allowLarger)
        }

        if plan.keepHDR, info.hasGainMap, target == .jpeg || target == .heic {
            if let produced = try hdr(source, info: info, target: target, geometry: geometry, curves: curves, strip: plan.strip, work: work, steps: steps, allowLarger: allowLarger) {
                return produced
            }
            steps.append("HDR dropped: resizing gain maps needs macOS 15")
        }

        if Self.imageIOFormats.contains(target) {
            return try imageIO(source, info: info, target: target, geometry: geometry, curves: curves, strip: plan.strip, work: work, steps: steps, allowLarger: allowLarger)
        }

        var produced = try await viaEngine(
            source, info: info, sourceFormat: sourceFormat, target: target, geometry: geometry, curves: curves,
            strip: plan.strip, work: work, progress: progress, steps: steps, allowLarger: allowLarger
        )
        if env.value(EsclopSettings.adaptiveImageSize), plan.format == nil, target == .png, !info.hasAlpha {
            produced = await adaptiveJPEG(instead: produced, curves: curves, strip: plan.strip, work: work)
        }
        return produced
    }

    /// The explicit format, else the automatic conversion lists, else the source's own format.
    func targetFormat(for sourceFormat: OutputFormat, info: ImageInfo, plan: Plan) -> OutputFormat {
        if let format = plan.format { return format == .gifVideo ? .gif : format }
        if plan.automatic {
            let ext = sourceFormat.rawValue
            if env.value(EsclopSettings.formatsToConvertToJPEG).map({ $0.lowercased() }).contains(ext) {
                // JPEG has no alpha: keep transparency in PNG instead.
                return info.hasAlpha ? .png : .jpeg
            }
            if env.value(EsclopSettings.formatsToConvertToPNG).map({ $0.lowercased() }).contains(ext) {
                return .png
            }
        }
        return sourceFormat
    }

    /// An image L'Esclop knows by its name but cannot decode is damaged; anything else is a kind
    /// it does not handle.
    static func unreadableOrUnsupported(_ source: URL) -> EsclopError {
        MediaKind.of(source) == .image ? .unreadable(kind: .image) : .unsupportedFile(source.lastPathComponent)
    }

    func geometry(for source: URL, info: ImageInfo, plan: Plan) throws -> Geometry {
        var crop: CGRect?
        var width = info.width
        var height = info.height
        if let size = plan.crop {
            let target = size.targetSize(fromWidth: width, height: height)
            if size.cropsAspect(fromWidth: width, height: height) {
                let aspect = Double(target.width) / Double(target.height)
                crop = size.region(inWidth: width, height: height)
                    ?? ImageIOCodec.cropRect(for: source, width: width, height: height, aspect: aspect, smart: size.smart)
            }
            width = target.width
            height = target.height
        }
        if let factor = plan.downscale {
            width = max(1, Int((Double(width) * factor).rounded()))
            height = max(1, Int((Double(height) * factor).rounded()))
        }
        guard width <= info.width * 4, height <= info.height * 4 else {
            throw EsclopError.invalidArgument("\(width)x\(height) is more than four times the original size")
        }
        return Geometry(crop: crop, width: width, height: height, changed: crop != nil || width != info.width || height != info.height)
    }

    // MARK: esclop-engine

    private func viaEngine(
        _ source: URL, info: ImageInfo, sourceFormat: OutputFormat, target: OutputFormat, geometry: Geometry,
        curves: Curves, strip: Bool, work: WorkFolder, progress: ProgressSink, steps: [String], allowLarger: Bool
    ) async throws -> Produced {
        let engine = env.images
        let caps: EngineCapabilities
        do {
            caps = try await engine.capabilities()
        } catch EsclopError.toolMissing {
            throw EsclopError.toolMissing(Tool.esclopEngine.rawValue)
        }
        guard caps.canEncode(target.rawValue) else {
            throw EsclopError.unsupportedFile("esclop-engine \(caps.version) cannot write \(target.rawValue.uppercased()) yet")
        }
        var steps = steps
        var input = source
        var inputFormat = sourceFormat
        let report: @Sendable (Double) -> Void = { progress($0) }

        if !Self.engineReadable.contains(sourceFormat) || info.orientation != 1 && geometry.changed {
            // The engine reads PNG, JPEG, WebP and GIF; ImageIO decodes everything else (and
            // applies the orientation so crop rectangles mean the same thing on both sides).
            let decoded = work.file("decoded.png")
            try ImageIOCodec.decodeToPNG(source, to: decoded)
            input = decoded
            inputFormat = .png
        }
        if let crop = geometry.crop {
            let cropped = work.file("cropped.png")
            try await engine.call("crop", input: input, output: cropped, params: [
                "x": .int(Int(crop.minX)), "y": .int(Int(crop.minY)),
                "width": .int(Int(crop.width)), "height": .int(Int(crop.height)), "format": "png",
            ])
            input = cropped
            inputFormat = .png
            steps.append("Cropped to \(Int(crop.width))x\(Int(crop.height))")
        }
        let current = geometry.crop.map { (Int($0.width), Int($0.height)) } ?? (info.width, info.height)
        if current.0 != geometry.width || current.1 != geometry.height {
            let resized = work.file("resized.png")
            try await engine.call("resize", input: input, output: resized, params: [
                "width": .int(geometry.width), "height": .int(geometry.height), "format": "png",
            ])
            input = resized
            inputFormat = .png
            steps.append("Resized to \(geometry.width)x\(geometry.height)")
        }

        let output = work.file(stem: "optimised", ext: target.fileExtension)
        var reply: EngineReply?
        do {
            reply = try await encode(input, inputFormat: inputFormat, to: output, target: target, curves: curves, strip: strip, work: work, report: report)
            steps.append(encodeStep(target, curves: curves))
        } catch EsclopError.alreadySmaller where input != source && inputFormat == target {
            // The optimiser could not beat the resized intermediate; that file is the answer.
            try FileManager.default.copyItem(at: input, to: output)
        }

        if !strip, input != source, target == .jpeg || target == .png {
            ImageIOCodec.copyMetadata(from: source, to: output)
        }
        return Produced(
            url: output, width: reply?.width ?? geometry.width, height: reply?.height ?? geometry.height,
            duration: nil, steps: steps, allowLarger: allowLarger
        )
    }

    /// One encode or optimise call for `target`.
    @discardableResult
    private func encode(
        _ input: URL, inputFormat: OutputFormat, to output: URL, target: OutputFormat, curves: Curves, strip: Bool,
        work: WorkFolder, report: @escaping @Sendable (Double) -> Void
    ) async throws -> EngineReply {
        let engine = env.images
        let stripValue = JSONValue.bool(strip)
        switch target {
        case .png:
            var input = input
            if inputFormat != .png {
                let png = work.file("as-png.png")
                try await engine.call("convert", input: input, output: png, params: ["format": "png", "strip": stripValue])
                input = png
            }
            return try await engine.call("png.optimise", input: input, output: output, params: [
                "lossy": .bool(curves.factor > 0), "quality": [0, .int(curves.pngQualityMax)],
                "speed": .int(curves.pngSpeed), "strip": stripValue,
            ], progress: report)
        case .jpeg:
            if inputFormat == .jpeg {
                return try await engine.call("jpeg.optimise", input: input, output: output, params: [
                    "quality": .int(curves.jpegQuality), "progressive": true, "strip": stripValue,
                ], progress: report)
            }
            return try await engine.call("convert", input: input, output: output, params: [
                "format": "jpeg", "quality": .int(curves.jpegQuality), "progressive": true, "strip": stripValue,
            ], progress: report)
        case .webp:
            return try await engine.call("webp.encode", input: input, output: output, params: [
                "quality": .int(curves.conversionQuality), "lossless": false, "strip": stripValue,
            ], progress: report)
        case .avif:
            return try await engine.call("avif.encode", input: input, output: output, params: [
                "quality": .int(curves.conversionQuality), "speed": .int(curves.factor >= 60 ? 4 : 6), "strip": stripValue,
            ], progress: report)
        default:
            return try await engine.call("convert", input: input, output: output, params: [
                "format": .string(target.rawValue), "quality": .int(curves.conversionQuality), "strip": stripValue,
            ], progress: report)
        }
    }

    private func encodeStep(_ target: OutputFormat, curves: Curves) -> String {
        switch target {
        case .png: return "Quantised PNG (quality up to \(curves.pngQualityMax))"
        case .jpeg: return "Encoded JPEG at quality \(curves.jpegQuality)"
        case .webp, .avif, .jxl: return "Encoded \(target.rawValue.uppercased()) at quality \(curves.conversionQuality)"
        default: return "Encoded \(target.rawValue.uppercased())"
        }
    }

    /// With "adaptive image format" on, a PNG without transparency is also tried as JPEG and the
    /// JPEG wins when it is smaller by more than 100 KB.
    private func adaptiveJPEG(instead produced: Produced, curves: Curves, strip: Bool, work: WorkFolder) async -> Produced {
        let jpeg = work.file(stem: "adaptive", ext: "jpeg")
        guard (try? await encode(produced.url, inputFormat: .png, to: jpeg, target: .jpeg, curves: curves, strip: strip, work: work, report: { _ in })) != nil,
              fileSize(produced.url) - fileSize(jpeg) > 100_000
        else { return produced }
        var result = produced
        result.url = jpeg
        result.allowLarger = true
        result.steps.append("JPEG was smaller than PNG, kept JPEG")
        return result
    }

    // MARK: GIF

    private func gifsicle(
        _ source: URL, info: ImageInfo, geometry: Geometry, curves: Curves, strip: Bool, work: WorkFolder,
        steps: [String], allowLarger: Bool
    ) async throws -> Produced {
        var steps = steps
        let output = work.file(stem: "optimised", ext: "gif")
        var args = curves.gifsicleArgs + ["--threads=\(ProcessInfo.processInfo.activeProcessorCount)"]
        if let crop = geometry.crop {
            args += ["--crop", "\(Int(crop.minX)),\(Int(crop.minY))+\(Int(crop.width))x\(Int(crop.height))"]
            steps.append("Cropped to \(Int(crop.width))x\(Int(crop.height))")
        }
        let current = geometry.crop.map { (Int($0.width), Int($0.height)) } ?? (info.width, info.height)
        if current.0 != geometry.width || current.1 != geometry.height {
            args += ["--resize", "\(geometry.width)x\(geometry.height)", "--resize-colors=256"]
            steps.append("Resized to \(geometry.width)x\(geometry.height)")
        }
        if strip { args += ["--no-comments", "--no-names", "--no-extensions"] }
        args += ["--output", output.path, source.path]
        try await ProcessRunner.run(.gifsicle, args, options: ProcessOptions(timeout: 600), locator: env.tools)
        // Never hand back a still in place of an animation.
        if info.isAnimated, (ImageInfo.probe(output)?.frameCount ?? 0) < 2 {
            throw EsclopError.other("gifsicle flattened the animation of \(source.lastPathComponent); keeping the original")
        }
        steps.append("Optimised GIF (\(curves.gifsicleArgs.joined(separator: " ")))")
        return Produced(url: output, width: geometry.width, height: geometry.height, duration: nil, steps: steps, allowLarger: allowLarger)
    }

    // MARK: ImageIO

    private func imageIO(
        _ source: URL, info: ImageInfo, target: OutputFormat, geometry: Geometry, curves: Curves, strip: Bool,
        work: WorkFolder, steps: [String], allowLarger: Bool
    ) throws -> Produced {
        guard let type = target.utType, ImageIOCodec.canWrite(type) else {
            throw EsclopError.unsupportedFile("This Mac cannot write \(target.rawValue.uppercased())")
        }
        var steps = steps
        let output = work.file(stem: "optimised", ext: target.fileExtension)
        let quality: Double? = target == .heic ? curves.imageIOHEICQuality : nil
        if target == .heic, info.format == .heic, !geometry.changed {
            try ImageIOCodec.reencodeKeepingGainMap(source, to: output, type: type, quality: quality ?? 0.8, strip: strip)
        } else {
            let image = try ImageIOCodec.render(ImageIOCodec.uprightImage(source), crop: geometry.crop, width: geometry.width, height: geometry.height)
            try ImageIOCodec.write(image, to: output, type: type, quality: quality, metadataFrom: source, strip: strip)
            if geometry.changed { steps.append("Resized to \(geometry.width)x\(geometry.height)") }
        }
        steps.append(quality.map { "Encoded \(target.rawValue.uppercased()) at quality \(Int($0 * 100))" } ?? "Encoded \(target.rawValue.uppercased())")
        return Produced(url: output, width: geometry.width, height: geometry.height, duration: nil, steps: steps, allowLarger: allowLarger)
    }

    /// Keeps the gain map. nil when the size changes and Core Image cannot rebuild it here.
    private func hdr(
        _ source: URL, info: ImageInfo, target: OutputFormat, geometry: Geometry, curves: Curves, strip: Bool,
        work: WorkFolder, steps: [String], allowLarger: Bool
    ) throws -> Produced? {
        guard let type = target.utType else { return nil }
        let output = work.file(stem: "optimised", ext: target.fileExtension)
        let quality = target == .heic ? curves.imageIOHEICQuality : curves.imageIOJPEGQuality
        var steps = steps
        if !geometry.changed {
            try ImageIOCodec.reencodeKeepingGainMap(source, to: output, type: type, quality: quality, strip: strip)
        } else if #available(macOS 15, *) {
            try ImageIOCodec.renderHDR(source, crop: geometry.crop, width: geometry.width, height: geometry.height, to: output, type: type, quality: quality)
            steps.append("Resized to \(geometry.width)x\(geometry.height)")
        } else {
            return nil
        }
        steps.append("Kept the HDR gain map")
        return Produced(url: output, width: geometry.width, height: geometry.height, duration: nil, steps: steps, allowLarger: allowLarger)
    }

    private func imageToPDF(_ source: URL, info: ImageInfo, work: WorkFolder) throws -> Produced {
        guard let image = NSImage(contentsOf: source), let page = PDFPage(image: image) else {
            throw Self.unreadableOrUnsupported(source)
        }
        let document = PDFDocument()
        document.insert(page, at: 0)
        let output = work.file(stem: "converted", ext: "pdf")
        guard document.write(to: output) else { throw EsclopError.other("Could not write the PDF") }
        return Produced(url: output, width: info.width, height: info.height, duration: nil, steps: ["Placed the image on a PDF page"], allowLarger: true)
    }

    // MARK: Watermark

    /// Lays `watermark` over the picture (20 px from the chosen edge, width a fraction of the
    /// picture's), then encodes in the source's format like any other optimisation.
    func watermark(_ source: URL, plan: Plan, watermark: Watermark, work: WorkFolder, progress: ProgressSink) async throws -> Produced {
        guard let info = ImageInfo.probe(source), let sourceFormat = info.format else {
            throw Self.unreadableOrUnsupported(source)
        }
        if info.isAnimated {
            throw EsclopError.unsupportedFile("Watermarking animated images is not supported yet")
        }
        let base = try ImageIOCodec.uprightImage(source)
        guard let mark = CGImageSourceCreateWithURL(watermark.image as CFURL, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }),
              mark.width > 0
        else { throw EsclopError.fileNotFound(watermark.image.path) }
        let composed = try Self.compose(base, mark: mark, watermark: watermark)
        let intermediate = work.file("watermarked.png")
        try ImageIOCodec.write(composed, to: intermediate, type: .png, quality: nil, metadataFrom: source, strip: plan.strip)

        var next = plan
        next.format = plan.format ?? targetFormat(for: sourceFormat, info: info, plan: plan)
        next.crop = nil
        let folder = try WorkFolder(root: work.url)
        var produced = try await process(intermediate, plan: next, work: folder, progress: progress)
        produced.allowLarger = true
        produced.steps.insert("Added a watermark (\(watermark.position.rawValue))", at: 0)
        if !plan.strip { ImageIOCodec.copyMetadata(from: source, to: produced.url) }
        return produced
    }

    static func compose(_ base: CGImage, mark: CGImage, watermark: Watermark) throws -> CGImage {
        let width = base.width
        let height = base.height
        let markWidth = max(16, Int((Double(width) * watermark.scale).rounded()))
        let markHeight = max(1, Int((Double(markWidth) * Double(mark.height) / Double(mark.width)).rounded()))
        let pad = 20
        // Core Graphics counts y from the bottom.
        let origin: (Int, Int)
        switch watermark.position {
        case .topLeft: origin = (pad, height - markHeight - pad)
        case .topRight: origin = (width - markWidth - pad, height - markHeight - pad)
        case .bottomLeft: origin = (pad, pad)
        case .center: origin = ((width - markWidth) / 2, (height - markHeight) / 2)
        case .bottomRight: origin = (width - markWidth - pad, pad)
        }
        let space = base.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw EsclopError.other("Could not create a \(width)x\(height) canvas") }
        context.interpolationQuality = .high
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setAlpha(min(1, max(0, watermark.opacity)))
        context.draw(mark, in: CGRect(x: origin.0, y: origin.1, width: markWidth, height: markHeight))
        guard let image = context.makeImage() else { throw EsclopError.other("Could not draw the watermark") }
        return image
    }

    // MARK: Fit under size

    func fit(_ source: URL, under target: Int, plan: Plan, work: WorkFolder, progress: ProgressSink) async throws -> Produced {
        guard let info = ImageInfo.probe(source), let sourceFormat = info.format else {
            throw Self.unreadableOrUnsupported(source)
        }
        let format = targetFormat(for: sourceFormat, info: info, plan: plan)
        let base = plan.factor(for: .image, format: format, env: env)

        // The engine searches in one call when it can read the file and write the format.
        if plan.crop == nil, plan.downscale == nil, format != .gif, !Self.imageIOFormats.contains(format),
           let caps = await env.images.capabilitiesIfAvailable(), caps.supports("fit"), caps.canEncode(format.rawValue)
        {
            var input = source
            if !Self.engineReadable.contains(sourceFormat) {
                input = work.file("decoded.png")
                try ImageIOCodec.decodeToPNG(source, to: input)
            }
            let output = work.file(stem: "fit", ext: format.fileExtension)
            let reply = try await env.images.call("fit", input: input, output: output, params: [
                "target_bytes": .int(target), "min_quality": 10, "allow_resize": true,
                "format": .string(format.rawValue), "strip": .bool(plan.strip),
            ], progress: { progress($0) })
            let chosen = [reply.raw["quality"].map { "quality \($0)" }, reply.raw["scale"].map { "scale \($0)" }].compactMap { $0 }
            return Produced(
                url: output, width: reply.width, height: reply.height, duration: nil,
                steps: ["Fit under \(ByteFormat.string(target))" + (chosen.isEmpty ? "" : " (\(chosen.joined(separator: ", ")))")],
                allowLarger: true
            )
        }

        let outcome = try await FitSearch.run(target: target, baseFactor: base, progress: progress) { factor, scale in
            var attempt = plan
            attempt.format = format
            attempt.request.quality = CompressionQuality(tier: .custom, factor: factor)
            attempt.downscale = scale < 0.999 ? scale * (plan.downscale ?? 1) : plan.downscale
            let folder = try WorkFolder(root: work.url)
            return try await process(source, plan: attempt, work: folder, progress: .none)
        }
        var produced = outcome.produced
        produced.allowLarger = true
        produced.steps.append("Fit under \(ByteFormat.string(target)) (compression \(outcome.factor), scale \(String(format: "%.2f", outcome.scale)))")
        return produced
    }

    // MARK: Metadata

    func stripMetadata(_ source: URL, work: WorkFolder) async throws -> Produced {
        guard let info = ImageInfo.probe(source), let format = info.format else {
            throw Self.unreadableOrUnsupported(source)
        }
        let output = work.file(stem: "stripped", ext: source.pathExtension.isEmpty ? format.fileExtension : source.pathExtension)
        if format == .gif {
            try await ProcessRunner.run(.gifsicle, ["--no-comments", "--no-names", "--no-extensions", "--output", output.path, source.path], locator: env.tools)
        } else if Self.engineReadable.contains(format), let caps = await env.images.capabilitiesIfAvailable(), caps.supports("metadata.strip") {
            try await env.images.call("metadata.strip", input: source, output: output, params: ["keep": ["icc", "orientation"]])
        } else {
            try ImageIOCodec.stripMetadata(source, to: output)
        }
        return Produced(url: output, width: info.width, height: info.height, duration: nil, steps: ["Removed metadata"], allowLarger: true)
    }
}

extension ImageIOCodec {
    /// Copies EXIF, GPS, IPTC and XMP from `source` onto `target` without re-encoding, with the
    /// orientation reset (the pixels are upright). Best effort: failures leave `target` as is.
    static func copyMetadata(from source: URL, to target: URL) {
        guard let original = CGImageSourceCreateWithURL(source as CFURL, nil),
              let metadata = CGImageSourceCopyMetadataAtIndex(original, 0, nil),
              let mutable = CGImageMetadataCreateMutableCopy(metadata),
              let input = CGImageSourceCreateWithURL(target as CFURL, nil),
              let typeID = CGImageSourceGetType(input)
        else { return }
        CGImageMetadataSetValueMatchingImageProperty(mutable, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, 1 as CFNumber)
        let staging = target.deletingLastPathComponent().appendingPathComponent(".meta-\(target.lastPathComponent)")
        guard let destination = CGImageDestinationCreateWithURL(staging as CFURL, typeID, 1, nil) else { return }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: mutable, kCGImageDestinationMergeMetadata: true]
        guard CGImageDestinationCopyImageSource(destination, input, options as CFDictionary, nil) else {
            try? FileManager.default.removeItem(at: staging)
            return
        }
        _ = try? FileManager.default.replaceItemAt(target, withItemAt: staging)
    }
}

enum ByteFormat {
    static func string(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
