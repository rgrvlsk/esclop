// SPDX-License-Identifier: GPL-3.0-or-later
//
// `EsclopEngine` is the one `OptimisationEngine` the app, the CLI, the MCP server and pipelines
// use. It resolves the request against the settings, sends the file to the engine for its kind
// (image, video, PDF, audio) and places the result where the request says. See docs/engines.md.

import EsclopCore
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Where a watermark sits.
public enum WatermarkCorner: String, Codable, CaseIterable, Sendable {
    case bottomRight, bottomLeft, topRight, topLeft, center
}

public struct EsclopEngine: OptimisationEngine {
    let env: EngineEnvironment

    public init() {
        self.init(settings: .shared)
    }

    /// Everything injectable, for tests and for the app (which may share one `EngineClient`).
    public init(
        settings: SettingsStore, tools: ToolLocator = .shared, backups: BackupStore = .shared,
        imageEngine: EngineClient = .shared, workRoot: URL = Paths.temporary.appendingPathComponent("work", isDirectory: true)
    ) {
        env = EngineEnvironment(settings: settings, tools: tools, backups: backups, images: imageEngine, workRoot: workRoot)
    }

    // MARK: OptimisationEngine

    /// Applies everything the request asks for: format, crop, downscale, speed, frame rate,
    /// audio removal, bitrates, target size, compression.
    public func optimise(_ source: URL, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult {
        try await run(.optimise, source, request: request, progress: progress)
    }

    public func convert(_ source: URL, to format: OutputFormat, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult {
        var request = request
        request.format = format
        return try await run(.convert, source, request: request, progress: progress)
    }

    public func downscale(_ source: URL, factor: Double, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult {
        guard factor > 0, factor <= 1 else {
            throw EsclopError.invalidArgument("The downscale factor must be above 0 and at most 1, got \(factor)")
        }
        var request = request
        request.downscale = factor
        return try await run(.downscale, source, request: request, progress: progress)
    }

    public func crop(_ source: URL, to size: CropSize, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult {
        var request = request
        request.crop = size
        return try await run(.crop, source, request: request, progress: progress)
    }

    public func fit(_ source: URL, underBytes: Int, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult {
        guard underBytes > 0 else { throw EsclopError.invalidArgument("The target size must be above zero") }
        var request = request
        request.targetBytes = underBytes
        return try await run(.fit, source, request: request, progress: progress)
    }

    public func stripMetadata(_ source: URL, request: OptimisationRequest) async throws -> OptimisationResult {
        try await run(.strip, source, request: request, progress: { _ in })
    }

    public func supports(_ url: URL) -> Bool {
        guard let kind = MediaKind.of(url) else { return false }
        switch kind {
        case .image: return OutputFormat.of(url: url).map { $0.kind == .image } ?? false
        case .video, .audio, .pdf: return true
        }
    }

    // MARK: More operations

    /// Drops every audio track without re-encoding the video.
    public func removeAudio(_ source: URL, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void = { _ in }) async throws -> OptimisationResult {
        try await perform(source, request: request, progress: progress) { plan, work, sink in
            guard try kind(of: source) == .video else { throw EsclopError.unsupportedFile("\(source.lastPathComponent) is not a video") }
            return try await VideoEngine(env: env).removeAudio(source, plan: plan, work: work, progress: sink)
        }
    }

    /// Resets the crop box of every page of a PDF.
    public func uncropPDF(_ source: URL, request: OptimisationRequest) async throws -> OptimisationResult {
        try await perform(source, request: request, progress: { _ in }) { _, work, _ in
            try PDFEngine(env: env).uncrop(source, work: work)
        }
    }

    /// Crops every page of a PDF to `aspectRatio` ("16:9", "4:3", "1.414") without recompressing.
    public func cropPDF(_ source: URL, aspectRatio: String, request: OptimisationRequest) async throws -> OptimisationResult {
        var request = request
        request.crop = CropSize(aspectRatio: aspectRatio)
        return try await run(.crop, source, request: request, progress: { _ in })
    }

    /// Renders every page to PNG or JPEG into `folder`. Returns the files in page order.
    public func extractPDFPages(_ source: URL, format: OutputFormat = .png, dpi: Int = 144, to folder: URL) async throws -> [URL] {
        try PDFEngine(env: env).extractPages(source, format: format, dpi: dpi, to: folder)
    }

    /// Re-encodes a video (or audio file) at `kbps` kbit/s.
    public func lowerBitrate(_ source: URL, kbps: Int, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult {
        guard kbps > 0 else { throw EsclopError.invalidArgument("The bitrate must be above zero") }
        var request = request
        if try kind(of: source) == .audio {
            request.audioBitrateKbps = kbps
        } else {
            request.videoBitrateKbps = kbps
        }
        return try await run(.optimise, source, request: request, progress: progress)
    }

    /// Drops frames above `fps`.
    public func capFrameRate(_ source: URL, fps: Int, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult {
        guard fps > 0 else { throw EsclopError.invalidArgument("The frame rate must be above zero") }
        var request = request
        request.fpsCap = Double(fps)
        return try await run(.optimise, source, request: request, progress: progress)
    }

    /// Normalises the loudness of an audio file or a video's soundtrack to `lufs` (e.g. -16).
    public func normalizeLoudness(_ source: URL, lufs: Double, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult {
        guard (-70 ... -5).contains(lufs) else { throw EsclopError.invalidArgument("Loudness must be between -70 and -5 LUFS") }
        var request = request
        request.loudnessLUFS = lufs
        return try await run(.optimise, source, request: request, progress: progress)
    }

    /// Plays a video or audio file `factor` times faster. `keepFrames` nil follows the setting.
    public func changeSpeed(_ source: URL, factor: Double, keepFrames: Bool? = nil, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult {
        guard factor > 0, factor <= 100 else { throw EsclopError.invalidArgument("The speed factor must be above 0 and at most 100") }
        var request = request
        request.playbackSpeed = factor
        return try await run(.optimise, source, request: request, progress: progress) { $0.keepFrames = keepFrames }
    }

    /// Lays `image` over a picture or video, `scale` of its width, 20 px from the chosen edge.
    public func watermark(
        _ source: URL, image: URL, position: WatermarkCorner = .bottomRight, opacity: Double = 1, scale: Double = 0.15,
        request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void
    ) async throws -> OptimisationResult {
        guard fileExists(image) else { throw EsclopError.fileNotFound(image.path) }
        guard scale > 0, scale <= 1 else { throw EsclopError.invalidArgument("The watermark scale must be above 0 and at most 1") }
        let mark = Watermark(image: image, position: position, opacity: opacity, scale: scale)
        let kind = try kind(of: source)
        guard kind == .image || kind == .video else {
            throw EsclopError.unsupportedFile("Watermarks go on images and videos")
        }
        return try await perform(source, request: request, progress: progress) { plan, work, sink in
            var plan = plan
            plan.watermark = mark
            return kind == .image
                ? try await ImageEngine(env: env).watermark(source, plan: plan, watermark: mark, work: work, progress: sink)
                : try await VideoEngine(env: env).process(source, plan: plan, work: work, progress: sink)
        }
    }

    /// The DPI stops PDF optimisation snaps to, high to low.
    public static var pdfDPIStops: [Int] { PDFEngine.dpiStops }

    /// What the image engine says it can do, or nil when it is missing.
    public func imageEngineCapabilities() async -> EngineCapabilities? {
        await env.images.capabilitiesIfAvailable()
    }

    // MARK: Dispatch

    func kind(of source: URL) throws -> MediaKind {
        if let kind = MediaKind.of(source) { return kind }
        // No or wrong extension: look at the content.
        if ImageInfo.probe(source) != nil { return .image }
        if PDFDocument(url: source) != nil { return .pdf }
        throw EsclopError.unsupportedFile(source.lastPathComponent)
    }

    private func run(
        _ operation: Operation, _ source: URL, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void,
        adjust: @escaping @Sendable (inout Plan) -> Void = { _ in }
    ) async throws -> OptimisationResult {
        let kind = try kind(of: source)
        let operation = operation == .optimise && request.targetBytes != nil ? .fit : operation

        if operation == .fit, let target = request.targetBytes, request.format == nil, request.crop == nil,
           request.downscale == nil, fileSize(source) <= target
        {
            try checkPermission(request, source: source)
            return try alreadyUnder(source, target: target, kind: kind, request: request)
        }

        return try await perform(source, request: request, operation: operation, progress: progress) { plan, work, sink in
            var plan = plan
            adjust(&plan)
            let target = plan.format
            switch (kind, operation) {
            case (_, .strip):
                switch kind {
                case .image: return try await ImageEngine(env: env).stripMetadata(source, work: work)
                case .video: return try await VideoEngine(env: env).stripMetadata(source, work: work)
                case .audio: return try await AudioEngine(env: env).stripMetadata(source, work: work)
                case .pdf: return try await PDFEngine(env: env).stripMetadata(source, work: work)
                }
            case (.image, _) where target?.kind == .video:
                // Animated GIF to MP4/WebM/MOV goes through ffmpeg.
                let video = VideoEngine(env: env)
                return operation == .fit
                    ? try await video.fit(source, under: request.targetBytes ?? 0, plan: plan, work: work, progress: sink)
                    : try await video.process(source, plan: plan, work: work, progress: sink)
            case (.image, .fit):
                return try await ImageEngine(env: env).fit(source, under: request.targetBytes ?? 0, plan: plan, work: work, progress: sink)
            case (.image, _):
                return try await ImageEngine(env: env).process(source, plan: plan, work: work, progress: sink)
            case (.video, .fit):
                return try await VideoEngine(env: env).fit(source, under: request.targetBytes ?? 0, plan: plan, work: work, progress: sink)
            case (.video, _):
                return try await VideoEngine(env: env).process(source, plan: plan, work: work, progress: sink)
            case (.audio, .fit):
                return try await AudioEngine(env: env).fit(source, under: request.targetBytes ?? 0, plan: plan, work: work, progress: sink)
            case (.audio, _):
                return try await AudioEngine(env: env).process(source, plan: plan, work: work, progress: sink)
            case (.pdf, .fit):
                return try await PDFEngine(env: env).fit(source, under: request.targetBytes ?? 0, plan: plan, work: work, progress: sink)
            case (.pdf, _):
                return try await PDFEngine(env: env).process(source, plan: plan, work: work, progress: sink)
            }
        }
    }

    private func perform(
        _ source: URL, request: OptimisationRequest, operation: Operation = .optimise,
        progress: @Sendable (OptimisationProgress) -> Void,
        body: @escaping @Sendable (Plan, WorkFolder, ProgressSink) async throws -> Produced
    ) async throws -> OptimisationResult {
        guard fileExists(source) else { throw EsclopError.fileNotFound(source.path) }
        try checkPermission(request, source: source)
        let kind = try kind(of: source)
        let started = Date()
        let plan = Plan(operation: operation, request: request, env: env)
        let work = try WorkFolder(root: env.workRoot)
        defer { work.remove() }
        // The caller's progress closure is not escaping, and engines report from pipe handlers
        // on other threads. Events go through a stream and are delivered from this task only.
        let (events, continuation) = AsyncStream<OptimisationProgress>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let sink = ProgressSink(requestID: request.id, source: source) { continuation.yield($0) }
        let env = self.env
        async let outcome: OptimisationResult = {
            defer { continuation.finish() }
            sink(0)
            let produced = try await body(plan, work, sink)
            try Task.checkCancellation()
            let result = try ResultWriter.place(produced, source: source, kind: kind, request: request, started: started, env: env)
            sink(1)
            return result
        }()
        for await event in events {
            progress(event)
        }
        return try await outcome
    }

    /// The file already fits: nothing to encode. In place it stays untouched; elsewhere a copy
    /// lands where asked.
    private func alreadyUnder(_ source: URL, target: Int, kind: MediaKind, request: OptimisationRequest) throws -> OptimisationResult {
        let started = Date()
        let bytes = fileSize(source)
        var output = source
        if request.location != .inPlace {
            let destination = request.location.destination(
                for: source, extension: source.pathExtension,
                sameFolderTemplate: env.value(EsclopSettings.sameFolderNameTemplate)
            )
            // A template naming the source itself leaves it as it is.
            if destination.standardizedFileURL.path != source.standardizedFileURL.path {
                let fm = FileManager.default
                try Paths.ensure(destination.deletingLastPathComponent())
                if fm.fileExists(atPath: destination.path) {
                    try env.backups.backUp(destination, requestID: request.id)
                }
                let staging = destination.deletingLastPathComponent()
                    .appendingPathComponent(".\(destination.lastPathComponent).esclop-\(UUID().uuidString.prefix(8))")
                try fm.copyItem(at: source, to: staging)
                if fm.fileExists(atPath: destination.path) {
                    _ = try fm.replaceItemAt(destination, withItemAt: staging)
                } else {
                    try fm.moveItem(at: staging, to: destination)
                }
                output = destination
            }
        }
        return OptimisationResult(
            id: request.id, source: source, output: output, kind: kind, bytesBefore: bytes, bytesAfter: bytes,
            startedAt: started, finishedAt: Date(), steps: ["Already under \(ByteFormat.string(target))"]
        )
    }

    /// Agents (MCP) only overwrite originals when the person allowed it. Checked here to fail
    /// early, and again when the result is placed (a template can resolve to the source).
    private func checkPermission(_ request: OptimisationRequest, source: URL) throws {
        guard request.origin == .mcp, !env.value(EsclopSettings.allowOverwriteOriginals) else { return }
        let overwrites: Bool
        switch request.location {
        case .inPlace: overwrites = true
        case .path:
            overwrites = request.location.destination(for: source, extension: source.pathExtension)
                .standardizedFileURL.path == source.standardizedFileURL.path
        default: overwrites = false
        }
        if overwrites { throw EsclopError.notPermitted(ResultWriter.agentOverwriteMessage) }
    }
}
