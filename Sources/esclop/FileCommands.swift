// SPDX-License-Identifier: GPL-3.0-or-later
//
// optimise, convert, downscale, crop, fit, strip, and the pdf subcommands.

import ArgumentParser
import EsclopCore
import EsclopIPC
import EsclopMCP
import Foundation

struct Optimise: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "optimise", abstract: "Optimise images, videos, PDFs and audio files.",
        aliases: ["optimize"]
    )

    @OptionGroup var files: FileOptions
    @OptionGroup var quality: QualityOptions
    @OptionGroup var global: GlobalOptions

    @Option(name: .customLong("downscale-factor"), help: "Also scale down: 0.5 is half the width and height.")
    var downscaleFactor: Double?

    @Option(help: "Also crop to WxH, a ratio such as 16:9, or a width.")
    var crop: String?

    @Option(name: .customLong("pdf-dpi"), help: "PDFs: resolution of images inside, e.g. 150.")
    var pdfDPI: Int?

    @Flag(name: .customLong("remove-audio"), help: "Videos: drop the audio track.")
    var removeAudio = false

    @Option(name: .customLong("playback-speed-factor"), help: "Videos: speed factor, 2 is twice as fast.")
    var playbackSpeedFactor: Double?

    func validate() throws {
        if let downscaleFactor, !(0.05 ... 1).contains(downscaleFactor) { throw ValidationError("--downscale-factor is between 0.05 and 1.") }
        if let crop { _ = try parseCrop(crop) }
        if let playbackSpeedFactor, playbackSpeedFactor <= 0 { throw ValidationError("--playback-speed-factor must be positive.") }
    }

    func run() async throws {
        let crop = try self.crop.map(parseCrop)
        try await runFileJob(.optimise, files: files, global: global) { request in
            request.quality = quality.quality
            request.stripMetadata = quality.stripMetadata
            request.downscale = downscaleFactor
            request.crop = crop
            request.pdfDPI = pdfDPI
            request.removeAudio = removeAudio
            request.playbackSpeed = playbackSpeedFactor
        }
    }
}

struct Convert: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Convert images, videos and audio files to another format.")

    @Option(name: [.customShort("t"), .long], help: "Target format: \(OutputFormat.allCases.map(\.rawValue).joined(separator: ", ")).")
    var to: OutputFormat

    @OptionGroup var files: FileOptions
    @OptionGroup var quality: QualityOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runFileJob(.convert(to), files: files, global: global) { request in
            request.format = to
            request.quality = quality.quality
            request.stripMetadata = quality.stripMetadata
        }
    }
}

extension OutputFormat: ExpressibleByArgument {
    public init?(argument: String) {
        let value = argument.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let aliases: [String: OutputFormat] = ["jpg": .jpeg, "tif": .tiff, "h265": .hevc, "x265": .hevc, "gifvideo": .gifVideo]
        guard let format = OutputFormat(rawValue: value) ?? aliases[value] else { return nil }
        self = format
    }

    public static var allValueStrings: [String] { allCases.map(\.rawValue) }
}

extension MediaKind: ExpressibleByArgument {}

struct Downscale: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Downscale and optimise images and videos by a factor. For audio, the factor applies to the bitrate."
    )

    @Option(help: "1.0 is no change, 0.5 half the width and height.")
    var factor: Double = 0.5

    @OptionGroup var files: FileOptions
    @OptionGroup var quality: QualityOptions
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        guard (0.05 ... 1).contains(factor) else { throw ValidationError("--factor is between 0.05 and 1.") }
    }

    func run() async throws {
        try await runFileJob(.downscale(factor), files: files, global: global) { request in
            request.downscale = factor
            request.quality = quality.quality
            request.stripMetadata = quality.stripMetadata
        }
    }
}

struct Crop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Crop and optimise images and videos to a size or aspect ratio.")

    @Option(name: .shortAndLong, help: "WxH (1920x1080, 1600x for width only), a ratio (16:9), or one number.")
    var size: String

    @Flag(name: .shortAndLong, help: "A single number caps the longer edge instead of setting the width.")
    var longEdge = false

    @Flag(name: .customLong("smart-crop"), help: "Centre the crop on the subject instead of the middle.")
    var smartCrop = false

    @OptionGroup var files: FileOptions
    @OptionGroup var quality: QualityOptions
    @OptionGroup var global: GlobalOptions

    func validate() throws { _ = try cropSize() }

    func cropSize() throws -> CropSize {
        do { return try AspectRatio.cropSize(size, longEdge: longEdge, smart: smartCrop) } catch { throw ValidationError("\(error)") }
    }

    func run() async throws {
        let size = try cropSize()
        try await runFileJob(.crop(size), files: files, global: global) { request in
            request.crop = size
            request.quality = quality.quality
            request.stripMetadata = quality.stripMetadata
        }
    }
}

struct Fit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Shrink files until each is under a size.")

    @Option(name: [.customLong("under"), .customLong("max-size")], help: "The limit: 2MB, 500KB, 1.5MiB or bytes.")
    var under: String

    @OptionGroup var files: FileOptions
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        do { _ = try ByteSize.parse(under) } catch { throw ValidationError("\(error)") }
    }

    func run() async throws {
        let bytes = try ByteSize.parse(under)
        try await runFileJob(.fit(underBytes: bytes), files: files, global: global) { $0.targetBytes = bytes }
    }
}

struct Strip: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove EXIF, GPS and other metadata from images and videos.", aliases: ["strip-exif"]
    )

    @OptionGroup var files: FileOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runFileJob(.stripMetadata, files: files, global: global) { $0.stripMetadata = true }
    }
}

struct Upload: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Upload files to an upload target set up in the app and print their links.",
        discussion: "Targets (S3-compatible: AWS S3, Cloudflare R2, Backblaze B2, MinIO) are set up in L'Esclop Settings › Uploads, which keeps their keys in the Keychain. Only the app can read them, so the upload runs there; the app is started if it is not running. The last link is also put on the clipboard."
    )

    @Option(name: .customLong("to"), help: "The upload target's name. Left out: the default one.")
    var target: String?

    @OptionGroup var files: FileOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runFileJob(.upload(target: target), files: files, global: global)
    }
}

func parseCrop(_ text: String) throws -> CropSize {
    do { return try AspectRatio.cropSize(text) } catch { throw ValidationError("\(error)") }
}

// MARK: - PDF

struct PDF: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pdf", abstract: "Crop, uncrop and export pages of PDFs.",
        subcommands: [CropPDF.self, UncropPDF.self, Pages.self]
    )

    struct CropPDF: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "crop",
            abstract: "Crop pages to an aspect ratio by setting the crop box. Reversible with `esclop pdf uncrop`."
        )

        @Option(name: .customLong("aspect-ratio"), help: "A ratio such as 3:4 or 0.75.")
        var aspectRatio: String?

        @Option(name: .customLong("for-device"), help: "A device, e.g. \"Kindle Paperwhite\" (see --list-devices).")
        var forDevice: String?

        @Option(name: .customLong("paper-size"), help: "A paper size, e.g. A4 or Letter.")
        var paperSize: String?

        @Flag(name: .shortAndLong, help: "Pad with blank paper instead of cutting content.")
        var extend = false

        @Flag(name: .customLong("list-devices"), help: "List the known devices and paper sizes, then exit.")
        var listDevices = false

        @Flag(name: .customLong("list-paper-sizes"), help: "Same as --list-devices.")
        var listPaperSizes = false

        @OptionGroup var files: FileOptions
        @OptionGroup var global: GlobalOptions

        func validate() throws {
            if listDevices || listPaperSizes { return }
            let given = [aspectRatio, forDevice, paperSize].compactMap { $0 }
            guard given.count == 1 else { throw ValidationError("Give one of --aspect-ratio, --for-device or --paper-size.") }
            do { _ = try AspectRatio.parse(given[0]) } catch { throw ValidationError("\(error)") }
        }

        mutating func run() async throws {
            if listDevices || listPaperSizes {
                for preset in AspectRatio.presets {
                    print("\(preset.name)\t\(JSONValue.double(preset.width).plain)x\(JSONValue.double(preset.height).plain)")
                }
                return
            }
            let ratio = try AspectRatio.parse(aspectRatio ?? forDevice ?? paperSize ?? "")
            try await runFileJob(.cropPDF(PDFCropSpec(aspectRatio: ratio, extend: extend)), files: files, global: global)
        }
    }

    struct UncropPDF: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "uncrop", abstract: "Reset every page's crop box to the full page.")

        @OptionGroup var files: FileOptions
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await runFileJob(.uncropPDF, files: files, global: global)
        }
    }

    struct Pages: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Export PDF pages as PNG or JPEG images.")

        @Argument(help: "The PDF.")
        var pdf: String

        @Option(help: "Pages to export: 1,3-5. Default all.")
        var pages: String?

        @Option(help: "png or jpeg.")
        var format: OutputFormat = .png

        @Option(help: "Resolution, 72 is the page's point size.")
        var dpi: Double = 144

        @Option(name: .shortAndLong, help: "Folder for the images. Default: next to the PDF.")
        var output: String?

        @OptionGroup var global: GlobalOptions

        func validate() throws {
            guard format == .png || format == .jpeg else { throw ValidationError("--format is png or jpeg.") }
            if let pages { _ = try Self.parsePages(pages) }
        }

        static func parsePages(_ text: String) throws -> [Int] {
            var out: [Int] = []
            for part in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                let bounds = part.split(separator: "-").map { Int($0.trimmingCharacters(in: .whitespaces)) }
                if bounds.count == 1, let n = bounds[0], n > 0 { out.append(n) }
                else if bounds.count == 2, let a = bounds[0], let b = bounds[1], a > 0, b >= a { out += Array(a ... b) }
                else { throw ValidationError("--pages takes numbers and ranges such as 1,3-5, not \(part).") }
            }
            return out
        }

        func run() async throws {
            try await guarded(global) {
                let source = try PathInput.url(pdf)
                let folder = try output.map { try PathInput.url($0) }
                    ?? source.deletingLastPathComponent().appendingPathComponent(source.deletingPathExtension().lastPathComponent + " pages", isDirectory: true)
                let written = try PDFPageTools().exportPages(source, pages: try pages.map(Self.parsePages), format: format, dpi: dpi, into: folder)
                if global.json {
                    Output.json(PageExport(source: source.path, pages: written.map(\.path)))
                } else {
                    print("\(global.terminal.green("✓")) \(written.count) page\(written.count == 1 ? "" : "s") \(global.terminal.dim("→")) \(global.terminal.cyan(PathInput.abbreviate(folder)))")
                }
                return 0
            }
        }
    }
}

struct PageExport: Codable {
    var source: String
    var pages: [String]
}
