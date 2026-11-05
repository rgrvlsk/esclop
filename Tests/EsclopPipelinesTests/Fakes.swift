// SPDX-License-Identifier: GPL-3.0-or-later
import EsclopCore
import Foundation
@testable import EsclopPipelines

/// Collects what fakes were asked to do, in order.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []

    var calls: [String] { lock.withLock { _calls } }
    func record(_ s: String) { lock.withLock { _calls.append(s) } }
}

/// A temporary folder that removes itself.
final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("esclop-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ name: String, bytes: Int = 1000) throws -> URL {
        let f = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: f)
        return f
    }

    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: url.appendingPathComponent(relative).path) }
}

/// An engine that copies files where the request says and halves their size, recording each call
/// as `operation(file name, location[, details])`.
struct FakeEngine: OptimisationEngine, PipelineMediaOperations {
    let recorder: Recorder
    var failOn: String?
    var alreadySmallerOn: String?
    var pages = 3

    func output(for source: URL, ext: String? = nil, request: OptimisationRequest) -> URL {
        let ext = ext ?? source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent
        switch request.location {
        case .inPlace: return source.deletingLastPathComponent().appendingPathComponent(stem).appendingPathExtension(ext)
        case .sameFolder: return source.deletingLastPathComponent().appendingPathComponent("\(stem)-esclop").appendingPathExtension(ext)
        case .temporary: return FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString.prefix(6))-\(stem)").appendingPathExtension(ext)
        case let .path(p): return URL(fileURLWithPath: p)
        }
    }

    func describe(_ l: OutputLocation) -> String {
        switch l {
        case .inPlace: "inPlace"
        case .sameFolder: "sameFolder"
        case .temporary: "temporary"
        case let .path(p): "path:" + p
        }
    }

    func process(_ op: String, _ source: URL, ext: String? = nil, request: OptimisationRequest, detail: String = "") throws -> OptimisationResult {
        recorder.record("\(op)(\(source.lastPathComponent), \(describe(request.location))\(detail.isEmpty ? "" : ", " + detail))")
        if op == failOn { throw EsclopError.toolFailed(tool: op, exitCode: 1, stderr: "boom") }
        if op == alreadySmallerOn { throw EsclopError.alreadySmaller }
        let out = output(for: source, ext: ext, request: request)
        let data = try Data(contentsOf: source)
        let smaller = data.prefix(max(1, data.count / 2))
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try smaller.write(to: out)
        if case .inPlace = request.location, out != source { try FileManager.default.removeItem(at: source) }
        return OptimisationResult(source: source, output: out, kind: MediaKind.of(out) ?? .image, bytesBefore: data.count, bytesAfter: smaller.count, startedAt: Date(), finishedAt: Date())
    }

    func optimise(_ source: URL, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult {
        progress(OptimisationProgress(requestID: request.id, source: source, fraction: 0.5))
        var detail = "q\(request.quality.factor)"
        if let e = request.videoEncoder { detail += ", \(e.rawValue)" }
        if let d = request.pdfDPI { detail += ", \(d)dpi" }
        if request.removeAudio { detail += ", mute" }
        if let s = request.playbackSpeed { detail += ", speed \(s)" }
        return try process("optimise", source, request: request, detail: detail)
    }

    func convert(_ source: URL, to format: OutputFormat, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult {
        let ext = ConvertTarget(format.rawValue, kind: MediaKind.of(source) ?? .image)?.fileExtension ?? format.rawValue
        return try process("convert", source, ext: format == .gifVideo ? "gif" : ext, request: request, detail: format.rawValue)
    }

    func downscale(_ source: URL, factor: Double, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult {
        try process("downscale", source, request: request, detail: "\(factor)")
    }

    func crop(_ source: URL, to size: CropSize, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult {
        try process("crop", source, request: request, detail: "w\(size.width ?? 0) h\(size.height ?? 0) l\(size.longEdge ?? 0)\(size.aspectRatio.map { " " + $0 } ?? "")\(size.smart ? " smart" : "")")
    }

    func fit(_ source: URL, underBytes: Int, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult {
        try process("fit", source, request: request, detail: "\(underBytes)")
    }

    func stripMetadata(_ source: URL, request: OptimisationRequest) async throws -> OptimisationResult {
        try process("strip", source, request: request)
    }

    func supports(_ url: URL) -> Bool { MediaKind.of(url) != nil }

    func lowerBitrate(_ source: URL, kbps: Int, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult {
        try process("lowerBitrate", source, request: request, detail: "\(kbps)")
    }

    func capFrameRate(_ source: URL, fps: Int, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult {
        try process("capFps", source, request: request, detail: "\(fps)")
    }

    func normalizeLoudness(_ source: URL, lufs: Double, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult {
        try process("normalize", source, request: request, detail: "\(lufs)")
    }

    func changeSpeed(_ source: URL, factor: Double, keepFrames: Bool?, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult {
        try process("speed", source, request: request, detail: "\(factor)\(keepFrames.map { $0 ? " keep" : " drop" } ?? "")")
    }

    func removeAudio(_ source: URL, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult {
        try process("mute", source, request: request)
    }

    func watermark(_ source: URL, image: URL, position: WatermarkPosition, opacity: Double, scale: Double, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult {
        try process("watermark", source, request: request, detail: "\(image.lastPathComponent) \(position.rawValue) \(opacity) \(scale)")
    }

    func extractPages(_ source: URL, format: PageImageFormat, scale: Double, into directory: URL, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> [URL] {
        recorder.record("pages(\(source.lastPathComponent), \(format.rawValue), \(scale)x)")
        let stem = source.deletingPathExtension().lastPathComponent
        return try (1 ... pages).map { n in
            let url = directory.appendingPathComponent("\(stem)-page\(n)").appendingPathExtension(format == .png ? "png" : "jpg")
            try Data([1, 2, 3]).write(to: url)
            return url
        }
    }
}

/// Only the contract's methods, to check the fallbacks for engines without `PipelineMediaOperations`.
struct ContractOnlyEngine: OptimisationEngine {
    let inner: FakeEngine

    func optimise(_ source: URL, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult { try await inner.optimise(source, request: request, progress: progress) }
    func convert(_ source: URL, to format: OutputFormat, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult { try await inner.convert(source, to: format, request: request, progress: progress) }
    func downscale(_ source: URL, factor: Double, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult { try await inner.downscale(source, factor: factor, request: request, progress: progress) }
    func crop(_ source: URL, to size: CropSize, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult { try await inner.crop(source, to: size, request: request, progress: progress) }
    func fit(_ source: URL, underBytes: Int, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult { try await inner.fit(source, underBytes: underBytes, request: request, progress: progress) }
    func stripMetadata(_ source: URL, request: OptimisationRequest) async throws -> OptimisationResult { try await inner.stripMetadata(source, request: request) }
    func supports(_ url: URL) -> Bool { inner.supports(url) }
}

struct RecordingHost: PipelineHost {
    let recorder: Recorder

    func perform(_ action: PipelineHostAction, file: URL, options: PipelineRunOptions) async throws -> PipelineHostOutcome {
        recorder.record("host \(action) \(file.lastPathComponent)")
        return .handled(nil)
    }
}

struct FakeInspector: MediaInspector {
    var size: (Int, Int)?
    var seconds: Double?
    func fileSize(_ url: URL) -> Int? { (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize }
    func pixelSize(_ url: URL) async -> (width: Int, height: Int)? { size.map { ($0.0, $0.1) } }
    func dpi(_ url: URL) -> Int? { 144 }
    func duration(_ url: URL) async -> Double? { seconds }
}

/// Answers `shortcuts run` by writing the output file; records every command.
struct FakeCommands: CommandRunner {
    let recorder: Recorder

    func run(_ executable: URL, _ arguments: [String], environment: [String: String]?, input: Data?) async throws -> CommandOutput {
        recorder.record(([executable.lastPathComponent] + arguments.map { ($0 as NSString).lastPathComponent }).joined(separator: " "))
        if let i = arguments.firstIndex(of: "--output-path") {
            try Data([9, 9]).write(to: URL(fileURLWithPath: arguments[i + 1]))
        }
        return CommandOutput(status: 0, stdout: "", stderr: "")
    }
}

let fixedDate: Date = {
    var c = DateComponents()
    c.year = 2026
    c.month = 3
    c.day = 7
    c.hour = 14
    c.minute = 5
    c.second = 9
    return Calendar.current.date(from: c)!
}()
