// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shortcuts actions that take files and give the results back as files, so they chain:
// optimise, convert, downscale, crop, crop PDF pages, change playback speed, optimise from a web
// address and run a pipeline. Parameters carry the step catalog's choices and limits (formats the
// engine writes, a factor above 0 and at most 1, whole pixels of at least 1, a ratio such as
// 16:9), and the choices every file action shares: where results go (the summary says it),
// compression, removing a video's audio, hiding the floating result, copying the results. They
// run in the app, opening nothing.

import AppIntents
import EsclopCore
import EsclopIPC
import EsclopPipelines
import Foundation
import UniformTypeIdentifiers

/// Files from Shortcuts as files on disk: a file that comes as data is written to a temporary one.
func diskFiles(_ files: [IntentFile]) throws -> [URL] {
    try files.map { file in
        if let url = file.fileURL { return url }
        return try ShortcutActions.temporaryFile(named: file.filename, data: file.data)
    }
}

func intentFiles(_ urls: [URL]) -> [IntentFile] {
    urls.map { IntentFile(fileURL: $0, filename: $0.lastPathComponent, type: UTType(filenameExtension: $0.pathExtension)) }
}

// ponytail: the six shared parameters are repeated in each intent: App Intents has no parameter
// mixin on macOS 14. Move them into one type if a later macOS target offers one.

/// The shared choices as `ShortcutActions` takes them; "in a folder" needs the folder.
@MainActor
func shortcutOptions(
    place: ResultPlace, folder: IntentFile?, hideResult: Bool, copy: Bool,
    compression: CompressionLevel? = nil, removeAudio: Bool = false
) throws -> ShortcutActions.Options {
    let where_: ShortcutActions.Place
    switch place {
    case .settings: where_ = .settings
    case .inPlace: where_ = .inPlace
    case .besideOriginal: where_ = .besideOriginal
    case .folder:
        // A folder passed from another action can still be a file: check it.
        var isFolder: ObjCBool = false
        guard let url = folder?.fileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw ShortcutActions.Failure(message: Strings.text("Choose the folder the results go to."))
        }
        where_ = .folder(url)
    }
    return ShortcutActions.Options(hideResult: hideResult, place: where_, compression: compression?.choice, removeAudio: removeAudio, copy: copy)
}

public struct OptimiseFilesIntent: AppIntent {
    public static let title: LocalizedStringResource = "Optimise Files"
    public static let description = IntentDescription("Optimise images, videos, PDFs and audio files with L’Esclop’s settings, keeping a backup of each original.")
    public static let openAppWhenRun = false

    @Parameter(title: "Files")
    public var files: [IntentFile]

    @Parameter(title: "Optimise harder", default: false)
    public var harder: Bool

    @Parameter(title: "Save", default: .settings)
    public var place: ResultPlace

    @Parameter(title: "Folder", supportedTypeIdentifiers: ["public.folder"])
    public var folder: IntentFile?

    @Parameter(title: "Compression")
    public var compression: CompressionLevel?

    @Parameter(title: "Remove audio from videos", default: false)
    public var removeAudio: Bool

    @Parameter(title: "Hide the floating result", default: false)
    public var hideResult: Bool

    @Parameter(title: "Copy the results", default: false)
    public var copy: Bool

    public static var parameterSummary: some ParameterSummary {
        Summary("Optimise \(\.$files) and save \(\.$place)") {
            \.$harder
            \.$folder
            \.$compression
            \.$removeAudio
            \.$hideResult
            \.$copy
        }
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let options = try shortcutOptions(place: place, folder: folder, hideResult: hideResult, copy: copy, compression: compression, removeAudio: removeAudio)
        return .result(value: intentFiles(try await ShortcutActions.run(.optimise(harder: harder), on: try diskFiles(files), options: options)))
    }
}

public struct OptimiseURLIntent: AppIntent {
    public static let title: LocalizedStringResource = "Optimise from URL"
    public static let description = IntentDescription("Download images, videos, PDFs or audio files from the web and optimise them. The downloads go to L’Esclop’s temporary folder unless you choose where to save them.")
    public static let openAppWhenRun = false

    @Parameter(title: "Addresses")
    public var addresses: [URL]

    @Parameter(title: "Optimise harder", default: false)
    public var harder: Bool

    @Parameter(title: "Save", default: .settings)
    public var place: ResultPlace

    @Parameter(title: "Folder", supportedTypeIdentifiers: ["public.folder"])
    public var folder: IntentFile?

    @Parameter(title: "Compression")
    public var compression: CompressionLevel?

    @Parameter(title: "Remove audio from videos", default: false)
    public var removeAudio: Bool

    @Parameter(title: "Hide the floating result", default: false)
    public var hideResult: Bool

    @Parameter(title: "Copy the results", default: false)
    public var copy: Bool

    public static var parameterSummary: some ParameterSummary {
        Summary("Download and optimise \(\.$addresses), and save \(\.$place)") {
            \.$harder
            \.$folder
            \.$compression
            \.$removeAudio
            \.$hideResult
            \.$copy
        }
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let options = try shortcutOptions(place: place, folder: folder, hideResult: hideResult, copy: copy, compression: compression, removeAudio: removeAudio)
        return .result(value: intentFiles(try await ShortcutActions.optimise(addresses: addresses, harder: harder, options: options)))
    }
}

public struct ConvertFilesIntent: AppIntent {
    public static let title: LocalizedStringResource = "Convert Files"
    public static let description = IntentDescription("Convert images, videos or audio files to another format, compressing in the same pass.")
    public static let openAppWhenRun = false

    @Parameter(title: "Files")
    public var files: [IntentFile]

    @Parameter(title: "Format", default: .webp)
    public var format: ConvertFormat

    @Parameter(title: "Save", default: .settings)
    public var place: ResultPlace

    @Parameter(title: "Folder", supportedTypeIdentifiers: ["public.folder"])
    public var folder: IntentFile?

    @Parameter(title: "Compression")
    public var compression: CompressionLevel?

    @Parameter(title: "Remove audio from videos", default: false)
    public var removeAudio: Bool

    @Parameter(title: "Hide the floating result", default: false)
    public var hideResult: Bool

    @Parameter(title: "Copy the results", default: false)
    public var copy: Bool

    public static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$files) to \(\.$format) and save \(\.$place)") {
            \.$folder
            \.$compression
            \.$removeAudio
            \.$hideResult
            \.$copy
        }
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let options = try shortcutOptions(place: place, folder: folder, hideResult: hideResult, copy: copy, compression: compression, removeAudio: removeAudio)
        return .result(value: intentFiles(try await ShortcutActions.run(.convert(format.output), on: try diskFiles(files), options: options)))
    }
}

public struct DownscaleFilesIntent: AppIntent {
    public static let title: LocalizedStringResource = "Downscale Files"
    public static let description = IntentDescription("Scale images and videos down by a factor, keeping their proportions. For audio, lowers the bitrate.")
    public static let openAppWhenRun = false

    @Parameter(title: "Files")
    public var files: [IntentFile]

    @Parameter(title: "Factor", default: 0.5, inclusiveRange: (0.01, 1))
    public var factor: Double

    @Parameter(title: "Save", default: .settings)
    public var place: ResultPlace

    @Parameter(title: "Folder", supportedTypeIdentifiers: ["public.folder"])
    public var folder: IntentFile?

    @Parameter(title: "Compression")
    public var compression: CompressionLevel?

    @Parameter(title: "Remove audio from videos", default: false)
    public var removeAudio: Bool

    @Parameter(title: "Hide the floating result", default: false)
    public var hideResult: Bool

    @Parameter(title: "Copy the results", default: false)
    public var copy: Bool

    public static var parameterSummary: some ParameterSummary {
        Summary("Downscale \(\.$files) by \(\.$factor) and save \(\.$place)") {
            \.$folder
            \.$compression
            \.$removeAudio
            \.$hideResult
            \.$copy
        }
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let options = try shortcutOptions(place: place, folder: folder, hideResult: hideResult, copy: copy, compression: compression, removeAudio: removeAudio)
        return .result(value: intentFiles(try await ShortcutActions.run(.downscale(factor), on: try diskFiles(files), options: options)))
    }
}

public struct ChangeSpeedIntent: AppIntent {
    public static let title: LocalizedStringResource = "Change Playback Speed"
    public static let description = IntentDescription("Speed videos and audio files up or slow them down: 2 plays twice as fast, 0.5 at half speed.")
    public static let openAppWhenRun = false

    @Parameter(title: "Files")
    public var files: [IntentFile]

    @Parameter(title: "Speed", default: 1.5, inclusiveRange: (0.1, 100))
    public var factor: Double

    @Parameter(title: "Save", default: .settings)
    public var place: ResultPlace

    @Parameter(title: "Folder", supportedTypeIdentifiers: ["public.folder"])
    public var folder: IntentFile?

    @Parameter(title: "Compression")
    public var compression: CompressionLevel?

    @Parameter(title: "Remove audio from videos", default: false)
    public var removeAudio: Bool

    @Parameter(title: "Hide the floating result", default: false)
    public var hideResult: Bool

    @Parameter(title: "Copy the results", default: false)
    public var copy: Bool

    public static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$files) at \(\.$factor)× speed and save \(\.$place)") {
            \.$folder
            \.$compression
            \.$removeAudio
            \.$hideResult
            \.$copy
        }
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let options = try shortcutOptions(place: place, folder: folder, hideResult: hideResult, copy: copy, compression: compression, removeAudio: removeAudio)
        return .result(value: intentFiles(try await ShortcutActions.run(.playbackSpeed(factor), on: try diskFiles(files), options: options)))
    }
}

public struct CropFilesIntent: AppIntent {
    public static let title: LocalizedStringResource = "Crop Files"
    public static let description = IntentDescription("Resize to exact pixels or crop to a shape. Give a width, a height, a long edge or an aspect ratio such as 16:9.")
    public static let openAppWhenRun = false

    @Parameter(title: "Files")
    public var files: [IntentFile]

    @Parameter(title: "Width", inclusiveRange: (1, 100_000))
    public var width: Int?

    @Parameter(title: "Height", inclusiveRange: (1, 100_000))
    public var height: Int?

    @Parameter(title: "Long edge", inclusiveRange: (1, 100_000))
    public var longEdge: Int?

    @Parameter(title: "Aspect ratio")
    public var aspectRatio: String?

    @Parameter(title: "Smart crop", default: false)
    public var smart: Bool

    @Parameter(title: "Save", default: .settings)
    public var place: ResultPlace

    @Parameter(title: "Folder", supportedTypeIdentifiers: ["public.folder"])
    public var folder: IntentFile?

    @Parameter(title: "Compression")
    public var compression: CompressionLevel?

    @Parameter(title: "Remove audio from videos", default: false)
    public var removeAudio: Bool

    @Parameter(title: "Hide the floating result", default: false)
    public var hideResult: Bool

    @Parameter(title: "Copy the results", default: false)
    public var copy: Bool

    public static var parameterSummary: some ParameterSummary {
        Summary("Crop \(\.$files) and save \(\.$place)") {
            \.$width
            \.$height
            \.$longEdge
            \.$aspectRatio
            \.$smart
            \.$folder
            \.$compression
            \.$removeAudio
            \.$hideResult
            \.$copy
        }
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let size = try Self.size(width: width, height: height, longEdge: longEdge, aspectRatio: aspectRatio, smart: smart)
        let options = try shortcutOptions(place: place, folder: folder, hideResult: hideResult, copy: copy, compression: compression, removeAudio: removeAudio)
        return .result(value: intentFiles(try await ShortcutActions.run(.crop(size), on: try diskFiles(files), options: options)))
    }

    /// The crop, checked as the step catalog checks `crop(...)`: at least one size, a ratio that reads.
    @MainActor
    static func size(width: Int?, height: Int?, longEdge: Int?, aspectRatio: String?, smart: Bool) throws -> CropSize {
        let ratio = aspectRatio?.trimmingCharacters(in: .whitespaces)
        if let ratio, !ratio.isEmpty, AspectRatio(ratio) == nil {
            throw ShortcutActions.Failure(message: Strings.format("“%@” is not an aspect ratio. Write it like 16:9 or 4:5.", ratio))
        }
        guard width != nil || height != nil || longEdge != nil || !(ratio ?? "").isEmpty else {
            throw ShortcutActions.Failure(message: Strings.text("Give a width, a height, a long edge or an aspect ratio."))
        }
        return CropSize(width: width, height: height, longEdge: longEdge, aspectRatio: (ratio ?? "").isEmpty ? nil : ratio, smart: smart)
    }
}

public struct CropPDFIntent: AppIntent {
    public static let title: LocalizedStringResource = "Crop PDF"
    public static let description = IntentDescription("Crop the pages of PDFs to a paper size, a device or a ratio such as 3:4. Nothing is cut away: the crop sets each page’s visible area, and `esclop pdf uncrop` takes it off again.")
    public static let openAppWhenRun = false

    @Parameter(title: "PDFs")
    public var files: [IntentFile]

    @Parameter(title: "Page shape", optionsProvider: PDFShapeOptions())
    public var shape: String

    @Parameter(title: "Pad with blank paper", default: false)
    public var extend: Bool

    @Parameter(title: "Save", default: .settings)
    public var place: ResultPlace

    @Parameter(title: "Folder", supportedTypeIdentifiers: ["public.folder"])
    public var folder: IntentFile?

    @Parameter(title: "Hide the floating result", default: false)
    public var hideResult: Bool

    @Parameter(title: "Copy the results", default: false)
    public var copy: Bool

    public static var parameterSummary: some ParameterSummary {
        Summary("Crop the pages of \(\.$files) to \(\.$shape) and save \(\.$place)") {
            \.$extend
            \.$folder
            \.$hideResult
            \.$copy
        }
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let options = try shortcutOptions(place: place, folder: folder, hideResult: hideResult, copy: copy)
        return .result(value: intentFiles(try await ShortcutActions.run(.cropPDF(try Self.spec(shape, extend: extend)), on: try diskFiles(files), options: options)))
    }

    /// The crop for `shape`: a paper size, a device or a ratio, as `esclop pdf crop` reads it.
    @MainActor
    static func spec(_ shape: String, extend: Bool) throws -> PDFCropSpec {
        guard let ratio = try? EsclopIPC.AspectRatio.parse(shape) else {
            throw ShortcutActions.Failure(message: Strings.format("“%@” is not a page shape. Choose a paper size or a device, or write a ratio like 3:4.", shape))
        }
        return PDFCropSpec(aspectRatio: ratio, extend: extend)
    }
}

public struct RunPipelineIntent: AppIntent {
    public static let title: LocalizedStringResource = "Run a Pipeline"
    public static let description = IntentDescription("Run one of your L’Esclop pipelines on files.")
    public static let openAppWhenRun = false

    @Parameter(title: "Files")
    public var files: [IntentFile]

    @Parameter(title: "Pipeline")
    public var pipeline: PipelineChoice

    @Parameter(title: "Hide the floating result", default: false)
    public var hideResult: Bool

    @Parameter(title: "Copy the results", default: false)
    public var copy: Bool

    public static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$pipeline) on \(\.$files)") {
            \.$hideResult
            \.$copy
        }
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        // The pipeline's steps say where its results go and how hard they compress.
        let options = ShortcutActions.Options(hideResult: hideResult, copy: copy)
        return .result(value: intentFiles(try await ShortcutActions.run(.pipeline(pipeline.id), on: try diskFiles(files), options: options)))
    }
}
