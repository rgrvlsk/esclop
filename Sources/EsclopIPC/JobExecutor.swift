// SPDX-License-Identifier: GPL-3.0-or-later
//
// Runs an `OptimisationJob` in this process: one engine call per file, events as it goes. The CLI
// and the MCP server use it when the app is not running; the app can use it as the body of its
// `AppRequestHandler.perform`.

import EsclopCore
import Foundation

/// Runs a pipeline (a saved name, a built-in preset or inline steps) on one file. EsclopMCP adapts
/// `PipelineRunner`; the app can pass the same adapter to `JobExecutor`.
public protocol PipelineRunning: Sendable {
    /// Whether the pipeline has steps that run the person's code (`runScript`, `runShortcut`).
    func usesScripts(_ pipeline: String) throws -> Bool

    func run(
        pipeline: String, on source: URL, request: OptimisationRequest, engine: any OptimisationEngine,
        progress: @escaping @Sendable (OptimisationProgress) -> Void
    ) async throws -> OptimisationResult
}

public struct JobExecutor: Sendable {
    public var engine: any OptimisationEngine
    public var pipelineRunner: (any PipelineRunning)?
    public var pdf: PDFPageTools
    public var backups: URL

    public init(engine: any OptimisationEngine, pipelineRunner: (any PipelineRunning)? = nil, backups: URL = Paths.backups) {
        self.engine = engine
        self.pipelineRunner = pipelineRunner
        self.pdf = PDFPageTools()
        self.backups = backups
    }

    public func run(_ job: OptimisationJob, events: @escaping @Sendable (JobEvent) -> Void = { _ in }) async -> JobReport {
        var report = JobReport(route: "in-process")
        for source in job.request.sources {
            if Task.isCancelled {
                let failure = FileFailure(source: source, error: .cancelled)
                report.failures.append(failure)
                events(.failure(failure))
                continue
            }
            do {
                let result = try await process(source, job: job) { events(.progress($0)) }
                report.results.append(result)
                events(.result(result))
            } catch {
                let failure = FileFailure(source: source, error: .wrap(error))
                report.failures.append(failure)
                events(.failure(failure))
            }
        }
        return report
    }

    public func process(
        _ source: URL, job: OptimisationJob,
        progress: @escaping @Sendable (OptimisationProgress) -> Void
    ) async throws -> OptimisationResult {
        guard FileManager.default.fileExists(atPath: source.path) else { throw EsclopError.fileNotFound(source.path) }
        let request = job.request
        switch job.operation {
        case .optimise:
            return try await engine.optimise(source, request: request, progress: progress)
        case let .convert(format):
            return try await engine.convert(source, to: format, request: request, progress: progress)
        case let .downscale(factor):
            guard factor > 0, factor <= 1 else { throw EsclopError.invalidArgument("The downscale factor is between 0 and 1, 0.5 is half the width and height") }
            return try await engine.downscale(source, factor: factor, request: request, progress: progress)
        case let .crop(size):
            return try await engine.crop(source, to: size, request: request, progress: progress)
        case let .fit(bytes):
            guard bytes > 0 else { throw EsclopError.invalidArgument("The target size must be positive") }
            return try await engine.fit(source, underBytes: bytes, request: request, progress: progress)
        case .stripMetadata:
            return try await engine.stripMetadata(source, request: request)
        case let .pipeline(pipeline):
            guard let pipelineRunner else {
                throw EsclopError.toolMissing("pipeline runner")
            }
            return try await pipelineRunner.run(pipeline: pipeline, on: source, request: request, engine: engine, progress: progress)
        case let .cropPDF(spec):
            return try await pdfOperation(source, request: request, suffix: "cropped", step: "crop-pdf \(spec.aspectRatio)") { output in
                try pdf.crop(source, spec: spec, to: output)
            }
        case .uncropPDF:
            return try await pdfOperation(source, request: request, suffix: "uncropped", step: "uncrop-pdf") { output in
                try pdf.uncrop(source, to: output)
            }
        }
    }

    private func pdfOperation(
        _ source: URL, request: OptimisationRequest, suffix: String, step: String,
        _ body: (URL) throws -> Int
    ) async throws -> OptimisationResult {
        guard MediaKind.of(source) == .pdf else { throw EsclopError.unsupportedFile("\(source.path) is not a PDF") }
        let started = Date()
        let before = Self.size(of: source)
        let output = try OutputPlanner.destination(for: source, location: request.location, suffix: suffix)
        var backup: URL?
        if output.standardizedFileURL == source.standardizedFileURL {
            backup = try OutputPlanner.backup(source, into: backups)
        }
        let pages = try body(output)
        return OptimisationResult(
            id: UUID(), source: source, output: output, backup: backup, kind: .pdf,
            bytesBefore: before, bytesAfter: Self.size(of: output),
            startedAt: started, finishedAt: Date(), steps: ["\(step) (\(pages) pages)"]
        )
    }

    static func size(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }
}

/// Where an operation writes, following `OutputLocation`.
public enum OutputPlanner {
    /// `%f` file name without extension, `%e` extension, `%d` source folder, `~` home.
    public static func destination(for source: URL, location: OutputLocation, suffix: String, extension ext: String? = nil) throws -> URL {
        let ext = ext ?? source.pathExtension
        let name = source.deletingPathExtension().lastPathComponent
        let folder = source.deletingLastPathComponent()
        switch location {
        case .inPlace:
            return folder.appendingPathComponent(name).appendingPathExtension(ext)
        case .sameFolder:
            return uniqueURL(folder.appendingPathComponent("\(name)-\(suffix)").appendingPathExtension(ext))
        case .temporary:
            let temp = try Paths.ensure(Paths.temporary.appendingPathComponent(UUID().uuidString.prefix(8).description, isDirectory: true))
            return temp.appendingPathComponent(name).appendingPathExtension(ext)
        case let .path(template):
            let (target, isFolder) = resolve(template, for: source, extension: ext)
            try Paths.ensure(isFolder ? target : target.deletingLastPathComponent())
            return isFolder ? target.appendingPathComponent(name).appendingPathExtension(ext) : target
        }
    }

    /// Where a path template points for `source`, without touching the disk. `isFolder` when it
    /// names a folder (ends in `/` or is an existing folder) the file goes into.
    public static func resolve(_ template: String, for source: URL, extension ext: String? = nil) -> (url: URL, isFolder: Bool) {
        let ext = ext ?? source.pathExtension
        let expanded = (template
            .replacingOccurrences(of: "%f", with: source.deletingPathExtension().lastPathComponent)
            .replacingOccurrences(of: "%e", with: ext)
            .replacingOccurrences(of: "%d", with: source.deletingLastPathComponent().path) as NSString).expandingTildeInPath
        let target = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded).standardizedFileURL
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded).standardizedFileURL
        var isDirectory: ObjCBool = false
        let isFolder = template.hasSuffix("/") || (FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        return (target, isFolder)
    }

    /// The file a job would write for `source` when `location` is a path, for the permission gate.
    public static func plannedFile(for source: URL, location: OutputLocation, operation: JobOperation) -> URL? {
        guard case let .path(template) = location else { return nil }
        var ext = source.pathExtension
        if case let .convert(format) = operation { ext = format == .gifVideo ? "gif" : format.rawValue }
        let (target, isFolder) = resolve(template, for: source, extension: ext)
        return isFolder
            ? target.appendingPathComponent(source.deletingPathExtension().lastPathComponent).appendingPathExtension(ext)
            : target
    }

    /// Copies `source` into the backups folder and returns the copy.
    public static func backup(_ source: URL, into folder: URL) throws -> URL {
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let target = try Paths.ensure(folder.appendingPathComponent(day, isDirectory: true))
            .appendingPathComponent("\(UUID().uuidString.prefix(8))-\(source.lastPathComponent)")
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    static func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let folder = url.deletingLastPathComponent()
        for n in 2 ... 9999 {
            let candidate = folder.appendingPathComponent("\(base)-\(n)").appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return folder.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(6))").appendingPathExtension(ext)
    }
}
