// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shortcuts actions that take files and give the results back as files, so they chain:
// optimise, convert, downscale, crop and run a pipeline. Parameters carry the step catalog's
// choices and limits (formats the engine writes, a factor above 0 and at most 1, whole pixels of
// at least 1, a ratio such as 16:9). They run in the app, opening nothing.

import AppIntents
import EsclopCore
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

public struct OptimiseFilesIntent: AppIntent {
    public static let title: LocalizedStringResource = "Optimise Files"
    public static let description = IntentDescription("Optimise images, videos, PDFs and audio files with L’Esclop’s settings, keeping a backup of each original.")
    public static let openAppWhenRun = false

    @Parameter(title: "Files")
    public var files: [IntentFile]

    @Parameter(title: "Optimise harder", default: false)
    public var harder: Bool

    public static var parameterSummary: some ParameterSummary {
        Summary("Optimise \(\.$files)") { \.$harder }
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: intentFiles(try await ShortcutActions.run(.optimise(harder: harder), on: try diskFiles(files))))
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

    public static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$files) to \(\.$format)")
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: intentFiles(try await ShortcutActions.run(.convert(format.output), on: try diskFiles(files))))
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

    public static var parameterSummary: some ParameterSummary {
        Summary("Downscale \(\.$files) by \(\.$factor)")
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: intentFiles(try await ShortcutActions.run(.downscale(factor), on: try diskFiles(files))))
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

    public static var parameterSummary: some ParameterSummary {
        Summary("Crop \(\.$files)") {
            \.$width
            \.$height
            \.$longEdge
            \.$aspectRatio
            \.$smart
        }
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let size = try Self.size(width: width, height: height, longEdge: longEdge, aspectRatio: aspectRatio, smart: smart)
        return .result(value: intentFiles(try await ShortcutActions.run(.crop(size), on: try diskFiles(files))))
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

public struct RunPipelineIntent: AppIntent {
    public static let title: LocalizedStringResource = "Run a Pipeline"
    public static let description = IntentDescription("Run one of your L’Esclop pipelines on files.")
    public static let openAppWhenRun = false

    @Parameter(title: "Files")
    public var files: [IntentFile]

    @Parameter(title: "Pipeline")
    public var pipeline: PipelineChoice

    public static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$pipeline) on \(\.$files)")
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: intentFiles(try await ShortcutActions.run(.pipeline(pipeline.id), on: try diskFiles(files))))
    }
}
