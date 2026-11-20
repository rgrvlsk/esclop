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
    /// Formats written with ImageIO. JPEG XL only where the system writes it (not macOS 26);
    /// elsewhere `imageIO` says this Mac cannot.
    static let imageIOFormats: Set<OutputFormat> = [.heic, .tiff, .bmp, .jxl]

    struct Geometry {
        var crop: CGRect?
        var width: Int
        var height: Int
        var changed: Bool
        /// The step line when a crop asked for more pixels than the picture has.
        var notEnlarged: String?
    }

    // MARK: Optimise, convert, downscale, crop

    func process(_ source: URL, plan: Plan, work: WorkFolder, progress: ProgressSink) async throws -> Produced {
        guard let info = ImageInfo.probe(source), let sourceFormat = info.format else {
            throw Self.unreadableOrUnsupported(source)
        }
        guard halvesRetina(info, plan: plan) else {
            return try await produce(source, info: info, sourceFormat: sourceFormat, plan: plan, work: work, progress: progress)
        }
        var halved = plan
        halved.downscale = 0.5
        // Written at 72 dpi from the start: HEIC's density cannot be rewritten afterwards.
        var oneX = info
        oneX.dpi = 72
        var produced = try await produce(source, info: oneX, sourceFormat: sourceFormat, plan: halved, work: work, progress: progress)
        // Half the pixels at 72 dpi: the screenshot shows at the size it had.
        ImageIOCodec.setDensity(produced.url, dpi: 72)
        produced.steps.insert("Downscaled the 2x screenshot to 1x", at: 0)
        return produced
    }

    private func produce(
        _ source: URL, info: ImageInfo, sourceFormat: OutputFormat, plan: Plan, work: WorkFolder, progress: ProgressSink
    ) async throws -> Produced {
        let target = targetFormat(for: sourceFormat, source: source, info: info, plan: plan)
        if target == .pdf {
            return try imageToPDF(source, info: info, work: work)
        }
        guard target.kind == .image else {
            throw EsclopError.invalidArgument("Images convert to image formats or PDF, not \(target.rawValue)")
        }
        let factor = plan.factor(for: .image, format: target, env: env)
        let curves = Curves(factor)
        let geometry = try geometry(for: source, info: info, plan: plan)
        try Self.checkKeepsFrames(info, from: sourceFormat, to: target, geometryChanged: geometry.changed)
        let formatChanged = target != sourceFormat
        var steps: [String] = []
        if formatChanged { steps.append("Converted \(sourceFormat.rawValue.uppercased()) to \(target.rawValue.uppercased())") }
        if let note = geometry.notEnlarged { steps.append(note) }
        let allowLarger = plan.allowsLarger(formatChanged: formatChanged)

        if sourceFormat == .gif, target == .gif {
            return try await gifsicle(source, info: info, geometry: geometry, curves: curves, strip: plan.strip, work: work, steps: steps, allowLarger: allowLarger)
        }

        if plan.keepHDR, info.hasGainMap {
            if target == .jpeg || target == .heic {
                if let produced = try hdr(source, info: info, target: target, geometry: geometry, curves: curves, strip: plan.strip, work: work, steps: steps, allowLarger: allowLarger) {
                    return produced
                }
                steps.append("HDR dropped: resizing gain maps needs macOS 15")
            } else {
                steps.append("HDR dropped: \(target.rawValue.uppercased()) cannot hold the gain map")
            }
        }

        if Self.imageIOFormats.contains(target) {
            return try imageIO(source, info: info, target: target, geometry: geometry, curves: curves, strip: plan.strip, work: work, steps: steps, allowLarger: allowLarger)
        }

        return try await viaEngine(
            source, info: info, sourceFormat: sourceFormat, target: target, geometry: geometry, curves: curves,
            strip: plan.strip, work: work, progress: progress, steps: steps, allowLarger: allowLarger,
            alternative: adaptiveAlternative(to: target, source: source, info: info, plan: plan)
        )
    }

    /// With "adaptive image format" on (or a request asking for it) and no explicit format: JPEG
    /// for a PNG without transparent pixels, PNG for a flat JPEG (entropy under 5 over more than
    /// a megapixel, as Clop judges it). Any JPEG target counts, also one the automatic lists
    /// chose (a flat HEIC may end as PNG), as in Clop, where the test sits in `optimiseJPEG`.
    /// nil when the output path names another extension, so an explicit `-o shot.png` stays
    /// PNG instead of failing after the work.
    func adaptiveAlternative(to target: OutputFormat, source: URL, info: ImageInfo, plan: Plan) -> OutputFormat? {
        guard plan.request.adaptiveImageFormat ?? env.value(EsclopSettings.adaptiveImageSize), plan.format == nil, !info.isAnimated else { return nil }
        let alternative: OutputFormat
        switch target {
        case .png where !Self.hasTransparentPixels(source, info: info): alternative = .jpeg
        case .jpeg where info.width * info.height > 1_000_000 && (ImageIOCodec.entropy(source) ?? 0) < 5: alternative = .png
        default: return nil
        }
        if case .path = plan.request.location {
            let destination = plan.request.location.destination(
                for: source, extension: alternative.fileExtension,
                sameFolderTemplate: env.value(EsclopSettings.sameFolderNameTemplate), temporaryRoot: Paths.temporary
            )
            guard (try? OutputLocation.checkExtension(of: destination, matches: alternative.fileExtension)) != nil else { return nil }
        }
        return alternative
    }

    /// Whether the picture has a pixel that is not fully opaque: an alpha channel alone does not
    /// count (opaque RGBA screenshots, HEIC and WebP files that carry one).
    static func hasTransparentPixels(_ source: URL, info: ImageInfo) -> Bool {
        info.hasAlpha && ImageIOCodec.hasTransparentPixels(source)
    }

    /// "Downscale Retina screenshots": an automatic optimisation of a still 2x (144 dpi) screenshot
    /// with no size of its own halves its width and height, as a 1x screenshot of the same screen.
    /// Only a screenshot: a 144 dpi photo or drawing keeps its pixels.
    func halvesRetina(_ info: ImageInfo, plan: Plan) -> Bool {
        plan.automatic && plan.operation == .optimise && plan.downscale == nil && plan.crop == nil
            && info.isScreenshot && !info.isAnimated && abs(info.dpi - 144) < 1
            && env.value(EsclopSettings.downscaleRetinaImages)
    }

    /// The explicit format, else the automatic conversion lists, else the source's own format.
    /// Animations and multi-page files are never converted automatically: the lists' targets
    /// hold one picture.
    func targetFormat(for sourceFormat: OutputFormat, source: URL, info: ImageInfo, plan: Plan) -> OutputFormat {
        if let format = plan.format { return format == .gifVideo ? .gif : format }
        if plan.automatic, !info.isAnimated {
            let ext = sourceFormat.rawValue
            if env.value(EsclopSettings.formatsToConvertToJPEG).map({ $0.lowercased() }).contains(ext) {
                // JPEG has no alpha: keep transparency in PNG instead.
                return Self.hasTransparentPixels(source, info: info) ? .png : .jpeg
            }
            if env.value(EsclopSettings.formatsToConvertToPNG).map({ $0.lowercased() }).contains(ext) {
                return .png
            }
        }
        return sourceFormat
    }

    static let keepsOnlyOneFrame = EsclopError.leftAsIs(
        "Files with several pages or frames are left as they are when the result would keep only one."
    )

    /// Throws unless every frame or page of `info` reaches `target`: GIF and WebP animations
    /// between those two formats (resized or cropped too), and APNGs or multi-page TIFFs
    /// optimised in their own format at their own size.
    /// ponytail: frames are ImageIO's image count, so a TIFF with a thumbnail IFD may count as
    /// two pages and be left as it is; conservative, nothing is lost.
    static func checkKeepsFrames(_ info: ImageInfo, from source: OutputFormat, to target: OutputFormat, geometryChanged: Bool) throws {
        guard info.isAnimated else { return }
        let animations: Set<OutputFormat> = [.gif, .webp]
        if animations.contains(source), animations.contains(target) { return }
        if source == target, source == .png || source == .tiff, !geometryChanged { return }
        throw keepsOnlyOneFrame
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
        var note: String?
        if let size = plan.crop {
            let target = size.targetSize(fromWidth: width, height: height)
            var available = (width: width, height: height)
            if size.cropsAspect(fromWidth: width, height: height) {
                let aspect = Double(target.width) / Double(target.height)
                let rect = size.region(inWidth: width, height: height)
                    ?? ImageIOCodec.cropRect(for: source, width: width, height: height, aspect: aspect, smart: size.smart)
                crop = rect
                available = (Int(rect.width), Int(rect.height))
            }
            let fitted = notEnlarged(target, within: available)
            width = fitted.width
            height = fitted.height
            if fitted.note { note = notEnlargedStep(target, kept: (width, height)) }
        }
        if let factor = plan.downscale {
            width = max(1, Int((Double(width) * factor).rounded()))
            height = max(1, Int((Double(height) * factor).rounded()))
        }
        return Geometry(
            crop: crop, width: width, height: height, changed: crop != nil || width != info.width || height != info.height,
            notEnlarged: note
        )
    }

    // MARK: esclop-engine

    private func viaEngine(
        _ source: URL, info: ImageInfo, sourceFormat: OutputFormat, target: OutputFormat, geometry: Geometry,
        curves: Curves, strip: Bool, work: WorkFolder, progress: ProgressSink, steps: [String], allowLarger: Bool,
        alternative: OutputFormat?
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

        if !Self.engineReadable.contains(sourceFormat) || info.orientation != 1 && geometry.changed && !info.isAnimated {
            // The engine reads PNG, JPEG, WebP and GIF; ImageIO decodes everything else (and
            // applies the orientation so crop rectangles mean the same thing on both sides).
            let decoded = work.file("decoded.png")
            try ImageIOCodec.decodeToPNG(source, to: decoded, strip: strip, dpi: info.dpi)
            input = decoded
            inputFormat = .png
        }
        // Lossless intermediates: the final encode is the only lossy step. Animations go
        // through WebP, which keeps their frames.
        let between: (format: OutputFormat, params: [String: JSONValue]) = info.isAnimated
            ? (.webp, ["format": "webp", "lossless": true])
            : (.png, ["format": "png", "lossy": false])
        if let crop = geometry.crop {
            let cropped = work.file(stem: "cropped", ext: between.format.fileExtension)
            try await engine.call("crop", input: input, output: cropped, params: between.params.merging([
                "x": .int(Int(crop.minX)), "y": .int(Int(crop.minY)),
                "width": .int(Int(crop.width)), "height": .int(Int(crop.height)),
            ]) { $1 })
            input = cropped
            inputFormat = between.format
            steps.append("Cropped to \(Int(crop.width))x\(Int(crop.height))")
        }
        let current = geometry.crop.map { (Int($0.width), Int($0.height)) } ?? (info.width, info.height)
        if current.0 != geometry.width || current.1 != geometry.height {
            let resized = work.file(stem: "resized", ext: between.format.fileExtension)
            try await engine.call("resize", input: input, output: resized, params: between.params.merging([
                "width": .int(geometry.width), "height": .int(geometry.height),
            ]) { $1 })
            input = resized
            inputFormat = between.format
            steps.append("Resized to \(geometry.width)x\(geometry.height)")
        }

        let output = work.file(stem: "optimised", ext: target.fileExtension)
        var reply: EngineReply?
        var primaryIsSource = false
        do {
            reply = try await encode(input, inputFormat: inputFormat, to: output, target: target, curves: curves, strip: strip, work: work, report: report)
            steps.append(reply?.raw["lossy"] == .bool(false) ? "Optimised without loss" : encodeStep(target, curves: curves))
        } catch EsclopError.alreadySmaller where input != source && inputFormat == target {
            // The optimiser could not beat the resized intermediate; that file is the answer.
            try FileManager.default.copyItem(at: input, to: output)
        } catch EsclopError.alreadySmaller where input == source && alternative != nil {
            // The source stays the answer in its format; the alternative may still beat it.
            primaryIsSource = true
        }

        if !strip, input != source, target == .jpeg || target == .png {
            ImageIOCodec.copyMetadata(from: source, to: output)
        }
        var produced = Produced(
            url: output, width: reply?.width ?? geometry.width, height: reply?.height ?? geometry.height,
            duration: nil, steps: steps, allowLarger: allowLarger, lossless: !geometry.changed && reply?.raw["lossy"] == .bool(false)
        )
        if let alternative {
            // From the same lossless input as `output`: encoding the quantised result again
            // would apply the loss twice.
            let candidate = work.file(stem: "adaptive", ext: alternative.fileExtension)
            if (try? await encode(input, inputFormat: inputFormat, to: candidate, target: alternative, curves: curves, strip: strip, work: work, report: { _ in })) != nil,
               fileSize(primaryIsSource ? source : output) - fileSize(candidate) > 100_000
            {
                if !strip, input != source { ImageIOCodec.copyMetadata(from: source, to: candidate) }
                let names = (alternative.rawValue.uppercased(), target.rawValue.uppercased())
                produced.url = candidate
                produced.allowLarger = true
                produced.steps.append("\(names.0) was smaller than \(names.1), kept \(names.0)")
            }
        }
        if primaryIsSource, produced.url == output { throw EsclopError.alreadySmaller }
        // Crops, resizes and conversions lose the density: a 144 dpi screenshot or a 300 dpi
        // print keeps the size it shows and prints at.
        if [.png, .jpeg].contains(OutputFormat.of(url: produced.url)), let dpi = ImageInfo.probe(produced.url)?.dpi, abs(dpi - info.dpi) >= 0.5 {
            ImageIOCodec.setDensity(produced.url, dpi: info.dpi)
        }
        // Last: every ImageIO rewrite above leaves the APP13 block out.
        if !strip, input != source, sourceFormat == .jpeg, OutputFormat.of(url: produced.url) == .jpeg {
            ImageIOCodec.copyIPTC(from: source, to: produced.url)
        }
        return produced
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
                try await engine.call("convert", input: input, output: png, params: ["format": "png", "lossy": false, "strip": stripValue])
                input = png
            }
            var params: [String: JSONValue] = [
                "lossy": .bool(curves.factor > 0), "quality": [0, .int(curves.pngQualityMax)],
                "speed": .int(curves.pngSpeed), "strip": stripValue,
            ]
            if let colors = curves.pngColors { params["colors"] = .int(colors) }
            return try await engine.call("png.optimise", input: input, output: output, params: params, progress: report)
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
        args += ["--output", output.path]
        if let everyNth = curves.gifFrameDropEveryNth, info.isAnimated,
           let selection = Curves.gifFrameDropArgs(delays: Self.gifDelays(source), everyNth: everyNth)
        {
            // Frame selections follow the input; unoptimised first, so no kept frame depends on a dropped one.
            args += ["--unoptimize", source.path] + selection
            steps.append("Dropped every \(Self.ordinal(everyNth)) frame, kept the duration")
        } else {
            args.append(source.path)
        }
        try await ProcessRunner.run(.gifsicle, args, options: ProcessOptions(timeout: 600), locator: env.tools)
        // Never hand back a still in place of an animation.
        if info.isAnimated, (ImageInfo.probe(output)?.frameCount ?? 0) < 2 {
            throw EsclopError.other("gifsicle flattened the animation of \(source.lastPathComponent); keeping the original")
        }
        steps.append("Optimised GIF (\(curves.gifsicleArgs.joined(separator: " ")))")
        // At --lossy=0 (compression 9 and under) gifsicle keeps every pixel, so any saving counts.
        let lossless = !geometry.changed && curves.gifsicleArgs.contains("--lossy=0")
        return Produced(url: output, width: geometry.width, height: geometry.height, duration: nil, steps: steps, allowLarger: allowLarger, lossless: lossless)
    }

    /// Each frame's delay in centiseconds, unclamped (0.02 s stays 2, not ImageIO's 10).
    static func gifDelays(_ url: URL) -> [Int] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        return (0 ..< CGImageSourceGetCount(source)).map { index in
            let gif = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let seconds = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0
            return Int((seconds * 100).rounded())
        }
    }

    private static func ordinal(_ n: Int) -> String { n == 2 ? "2nd" : n == 3 ? "3rd" : "\(n)th" }

    // MARK: ImageIO

    private func imageIO(
        _ source: URL, info: ImageInfo, target: OutputFormat, geometry: Geometry, curves: Curves, strip: Bool,
        work: WorkFolder, steps: [String], allowLarger: Bool
    ) throws -> Produced {
        guard let type = target.utType, ImageIOCodec.canWrite(type) else {
            throw EsclopError.unsupportedFile("This Mac cannot write \(target == .jxl ? "JPEG XL" : target.rawValue.uppercased())")
        }
        var steps = steps
        let output = work.file(stem: "optimised", ext: target.fileExtension)
        let quality: Double? = target == .heic ? curves.imageIOHEICQuality : nil
        if target == info.format, target == .heic || info.isAnimated, !geometry.changed {
            // Every page of a multi-page TIFF; a HEIC's gain map only through `hdr` (Keep HDR).
            try ImageIOCodec.reencode(source, to: output, type: type, quality: quality ?? 0.8, strip: strip, keepGainMap: false)
        } else {
            let image = try ImageIOCodec.render(ImageIOCodec.uprightImage(source), crop: geometry.crop, width: geometry.width, height: geometry.height)
            try ImageIOCodec.write(image, to: output, type: type, quality: quality, metadataFrom: source, strip: strip, dpi: info.dpi)
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
            try ImageIOCodec.reencode(source, to: output, type: type, quality: quality, strip: strip, keepGainMap: true)
        } else if #available(macOS 15, *) {
            try ImageIOCodec.renderHDR(source, crop: geometry.crop, width: geometry.width, height: geometry.height, to: output, type: type, quality: quality, strip: strip)
            steps.append("Resized to \(geometry.width)x\(geometry.height)")
        } else {
            return nil
        }
        steps.append("Kept the HDR gain map")
        return Produced(url: output, width: geometry.width, height: geometry.height, duration: nil, steps: steps, allowLarger: allowLarger)
    }

    /// One PDF page per picture: every page of a multi-page TIFF. An animation's frames are
    /// not pages, so animations are left as they are.
    private func imageToPDF(_ source: URL, info: ImageInfo, work: WorkFolder) throws -> Produced {
        var images: [NSImage] = []
        if info.isAnimated {
            let reps = info.format == .tiff ? NSBitmapImageRep.imageReps(withContentsOf: source) ?? [] : []
            guard reps.count == info.frameCount else { throw Self.keepsOnlyOneFrame }
            images = reps.map { rep in
                let image = NSImage(size: rep.size)
                image.addRepresentation(rep)
                return image
            }
        } else if let image = NSImage(contentsOf: source) {
            images = [image]
        }
        let document = PDFDocument()
        for image in images {
            guard let page = PDFPage(image: image) else { throw Self.unreadableOrUnsupported(source) }
            document.insert(page, at: document.pageCount)
        }
        guard document.pageCount > 0 else { throw Self.unreadableOrUnsupported(source) }
        let output = work.file(stem: "converted", ext: "pdf")
        guard document.write(to: output) else { throw EsclopError.other("Could not write the PDF") }
        let step = images.count > 1 ? "Placed the \(images.count) pages on PDF pages" : "Placed the image on a PDF page"
        return Produced(url: output, width: info.width, height: info.height, duration: nil, steps: [step], allowLarger: true)
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
        try ImageIOCodec.write(composed, to: intermediate, type: .png, quality: nil, metadataFrom: source, strip: plan.strip, dpi: info.dpi)

        var next = plan
        next.format = plan.format ?? targetFormat(for: sourceFormat, source: source, info: info, plan: plan)
        next.crop = nil
        let folder = try WorkFolder(root: work.url)
        var produced = try await process(intermediate, plan: next, work: folder, progress: progress)
        produced.allowLarger = true
        produced.steps.insert("Added a watermark (\(watermark.position.rawValue))", at: 0)
        if plan.keepHDR, info.hasGainMap { produced.steps.append("HDR dropped: the watermark is drawn on the SDR picture") }
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
        let format = targetFormat(for: sourceFormat, source: source, info: info, plan: plan)
        let base = plan.factor(for: .image, format: format, env: env)
        // Fitting may scale.
        try Self.checkKeepsFrames(info, from: sourceFormat, to: format, geometryChanged: true)

        // The engine searches in one call when it can read the file and write the format. It
        // writes no gain map, so HDR photos kept as HDR go through `process`.
        if plan.crop == nil, plan.downscale == nil, format != .gif, !Self.imageIOFormats.contains(format),
           !(plan.keepHDR && info.hasGainMap && format == .jpeg),
           let caps = await env.images.capabilitiesIfAvailable(), caps.supports("fit"), caps.canEncode(format.rawValue)
        {
            var input = source
            if !Self.engineReadable.contains(sourceFormat) {
                input = work.file("decoded.png")
                try ImageIOCodec.decodeToPNG(source, to: input, strip: plan.strip, dpi: info.dpi)
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
    /// Whether any pixel of the first frame is less than fully opaque. Stops at the first one;
    /// an image it cannot read counts as transparent, which keeps it in a format with alpha.
    static func hasTransparentPixels(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return true }
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ), let data = context.data else { return true }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let rowBytes = context.bytesPerRow
        let alpha = data.bindMemory(to: UInt8.self, capacity: rowBytes * image.height)
        for row in 0 ..< image.height {
            let line = UnsafeBufferPointer(start: alpha + row * rowBytes, count: image.width)
            if line.contains(where: { $0 < 255 }) { return true }
        }
        return false
    }

    /// Shannon entropy over the red, green and blue histograms side by side (768 bins, 0 to
    /// log2(768) bits), as Clop's `calculateShannonEntropy` measures it to spot flat graphics
    /// saved as JPEG. Sampled on at most about two megapixels, nearest neighbour, so no new
    /// values appear. nil when the image cannot be read.
    static func entropy(_ url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0, image.height > 0
        else { return nil }
        let scale = min(1, (2_000_000 / Double(image.width * image.height)).squareRoot())
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let data = context.data else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: width * height * 4), count: width * height * 4)
        var histogram = [Int](repeating: 0, count: 768)
        for (index, value) in pixels.enumerated() where index % 4 != 3 { histogram[(index % 4) * 256 + Int(value)] += 1 }
        let total = Double(width * height * 3)
        return histogram.reduce(0.0) { sum, count in
            guard count > 0 else { return sum }
            let p = Double(count) / total
            return sum - p * log2(p)
        }
    }

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

    /// Copies the IPTC record (keywords, captions, credits) of a JPEG's Photoshop APP13 segments,
    /// which `copyMetadata` leaves out, into another JPEG that has none, after its leading APP
    /// segments. Only that resource goes: APP13 can also hold a thumbnail of the uncropped picture.
    /// ponytail: IPTC split across two APP13 segments (over about 64 KB) or after a non-8BIM
    /// resource is left out, and an unpadded odd last record is copied as it is; pad and join
    /// segments if such files turn up.
    static func copyIPTC(from source: URL, to target: URL) {
        guard let original = try? Data(contentsOf: source), var output = try? Data(contentsOf: target) else { return }
        let prefix = [UInt8]("Photoshop 3.0\0".utf8)
        let bytes = [UInt8](original)
        var records: [UInt8] = []
        for segment in jpegHeaderSegments(original) where segment.marker == 0xED {
            var at = segment.range.lowerBound + 4
            guard bytes[at...].starts(with: prefix) else { continue }
            at += prefix.count
            // 8BIM, resource id, a Pascal name padded to even, a size, the data padded to even.
            while at + 7 <= segment.range.upperBound, bytes[at ..< at + 4] == [0x38, 0x42, 0x49, 0x4D] {
                let id = Int(bytes[at + 4]) << 8 | Int(bytes[at + 5])
                let sizeAt = at + 6 + (Int(bytes[at + 6]) + 2) / 2 * 2
                guard sizeAt + 4 <= segment.range.upperBound else { break }
                let size = bytes[sizeAt ..< sizeAt + 4].reduce(0) { $0 << 8 | Int($1) }
                let end = sizeAt + 4 + (size + 1) / 2 * 2
                guard end <= segment.range.upperBound || sizeAt + 4 + size == segment.range.upperBound else { break }
                if id == 0x0404 { records += bytes[at ..< min(end, segment.range.upperBound)] }
                at = end
            }
        }
        let header = jpegHeaderSegments(output)
        let length = 2 + prefix.count + records.count
        guard !records.isEmpty, length <= 0xFFFF, !header.contains(where: { $0.marker == 0xED }) else { return }
        let at = header.prefix { (0xE0 ... 0xEC).contains($0.marker) }.last?.range.upperBound ?? 2
        output.insert(contentsOf: [0xFF, 0xED, UInt8(length >> 8), UInt8(length & 0xFF)] + prefix + records, at: at)
        try? output.write(to: target, options: .atomic)
    }

    /// The marker segments before the image data (start of scan), each with its marker and
    /// length bytes; empty for a file that is not a JPEG.
    static func jpegHeaderSegments(_ data: Data) -> [(marker: UInt8, range: Range<Int>)] {
        let bytes = [UInt8](data)
        guard bytes.starts(with: [0xFF, 0xD8]) else { return [] }
        var segments: [(marker: UInt8, range: Range<Int>)] = []
        var offset = 2
        while offset + 4 <= bytes.count, bytes[offset] == 0xFF, bytes[offset + 1] != 0xDA {
            let end = offset + 2 + (Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3]))
            guard end <= bytes.count else { break }
            segments.append((bytes[offset + 1], offset ..< end))
            offset = end
        }
        return segments
    }
}

/// The one rule for crops of images and videos: never enlarge. A size larger than the picture
/// (or than the region cropped from it) shrinks to fit inside it, keeping its shape; `note`
/// says it did, for a step line.
func notEnlarged(_ target: (width: Int, height: Int), within available: (width: Int, height: Int)) -> (width: Int, height: Int, note: Bool) {
    let shrink = min(1, Double(available.width) / Double(max(1, target.width)), Double(available.height) / Double(max(1, target.height)))
    guard shrink < 1 else { return (target.width, target.height, false) }
    return (max(1, Int((Double(target.width) * shrink).rounded())), max(1, Int((Double(target.height) * shrink).rounded())), true)
}

func notEnlargedStep(_ target: (width: Int, height: Int), kept: (width: Int, height: Int)) -> String {
    "Not enlarged to \(target.width)x\(target.height); kept \(kept.width)x\(kept.height)"
}

enum ByteFormat {
    static func string(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
