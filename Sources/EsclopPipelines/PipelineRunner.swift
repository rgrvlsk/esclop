// SPDX-License-Identifier: GPL-3.0-or-later
//
// Runs a pipeline over files. Each file carries a "current file" through the steps: processing
// steps replace it with their output, file operations move it, filters can stop it, `fork`
// branches a copy off without changing it. Every step leaves an entry in a structured log.

import EsclopCore
import Foundation

// MARK: - Options, progress, report

public struct PipelineRunOptions: Sendable {
    /// Who asked; passed on to the engine in every request.
    public var origin: RequestOrigin
    /// `runScript` steps only run when this is on (the app's setting, or the MCP permission).
    public var allowRunScripts: Bool
    /// `delete` steps only run when this is on.
    public var allowDelete: Bool
    /// Name or bundle id of the app the clipboard content came from, for `if(copiedBy:)`.
    public var sourceApp: String?
    /// Quality for steps that do not set their own.
    public var quality: CompressionQuality
    /// Folder of the bundled tools, exported to scripts as `$ESCLOP_BIN`.
    public var binDirectory: URL?
    /// Where forks, shortcut outputs and `temporaryFolder` page images go.
    public var temporaryDirectory: URL

    public init(
        origin: RequestOrigin = .cli, allowRunScripts: Bool = false, allowDelete: Bool = true, sourceApp: String? = nil,
        quality: CompressionQuality = .normal, binDirectory: URL? = nil, temporaryDirectory: URL = Paths.temporary
    ) {
        self.origin = origin
        self.allowRunScripts = allowRunScripts
        self.allowDelete = allowDelete
        self.sourceApp = sourceApp
        self.quality = quality
        self.binDirectory = binDirectory
        self.temporaryDirectory = temporaryDirectory
    }
}

public struct PipelineProgress: Sendable, Hashable {
    public var fileIndex: Int
    public var fileCount: Int
    public var file: URL
    public var stepIndex: Int
    public var stepCount: Int
    /// The step as pipeline text.
    public var step: String
    /// 0...1 within the step, -1 when unknown.
    public var stepFraction: Double
    public var message: String?

    /// 0...1 over the whole run.
    public var overallFraction: Double {
        guard fileCount > 0, stepCount > 0 else { return 0 }
        let step = (Double(stepIndex) + max(0, stepFraction)) / Double(stepCount)
        return (Double(fileIndex) + step) / Double(fileCount)
    }
}

public struct PipelineLogEntry: Hashable, Codable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// The step changed or produced something.
        case done
        /// The step ran and left the file as it was (already small enough, already that format).
        case unchanged
        /// The step does not apply here or needs something missing (the app, a permission).
        case skipped
        /// A filter stopped the file.
        case stopped
        case failed
    }

    public var stepIndex: Int
    public var step: String
    public var outcome: Outcome
    public var message: String?
    /// The current file after the step.
    public var file: URL?
    public var seconds: Double
}

public struct PipelineFileReport: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case completed
        /// A filter stopped it; not an error.
        case filtered
        case failed
        case cancelled
        /// Not a kind of file esclop handles, or the pipeline has no steps for its kind.
        case unsupported
    }

    public var source: URL
    public var kind: MediaKind?
    public var status: Status
    /// Where the file ended up. Nil when it was deleted or never processed.
    public var finalFile: URL?
    /// Other files the run produced for this source: forks and extracted pages.
    public var extraOutputs: [URL]
    /// Engine results, one per processing step that ran.
    public var results: [OptimisationResult]
    public var log: [PipelineLogEntry]
    public var error: String?
}

public struct PipelineRunReport: Codable, Sendable {
    public var pipeline: String
    public var startedAt: Date
    public var finishedAt: Date
    public var files: [PipelineFileReport]

    /// No file failed (filtered files count as fine).
    public var succeeded: Bool { !files.contains { $0.status == .failed } }
}

// MARK: - Runner

public struct PipelineRunner: Sendable {
    public let engine: any OptimisationEngine
    public let host: any PipelineHost
    public let inspector: any MediaInspector
    public let commands: any CommandRunner
    let now: @Sendable () -> Date

    public init(
        engine: any OptimisationEngine,
        host: any PipelineHost = NoopPipelineHost(),
        inspector: any MediaInspector = SystemMediaInspector(),
        commands: any CommandRunner = ProcessCommandRunner(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.engine = engine
        self.host = host
        self.inspector = inspector
        self.commands = commands
        self.now = now
    }

    /// Runs `pipeline` on each file in turn. Never throws: problems are in the report.
    public func run(
        _ pipeline: Pipeline, on files: [URL], options: PipelineRunOptions = PipelineRunOptions(),
        progress: @escaping @Sendable (PipelineProgress) -> Void = { _ in }
    ) async -> PipelineRunReport {
        let started = now()
        var reports: [PipelineFileReport] = []
        for (index, file) in files.enumerated() {
            var run = FileRun(runner: self, pipeline: pipeline, source: file, index: index, count: files.count, counter: index + 1, options: options, progress: progress)
            reports.append(await run.execute())
        }
        return PipelineRunReport(pipeline: pipeline.name, startedAt: started, finishedAt: now(), files: reports)
    }

    /// Runs inline steps, like `esclop pipeline run 'convert(to: webp)' a.png`.
    public func run(
        steps: [PipelineStep], on files: [URL], options: PipelineRunOptions = PipelineRunOptions(),
        progress: @escaping @Sendable (PipelineProgress) -> Void = { _ in }
    ) async -> PipelineRunReport {
        await run(Pipeline(steps: steps), on: files, options: options, progress: progress)
    }
}

// MARK: - One file

struct FileRun {
    let runner: PipelineRunner
    let pipeline: Pipeline
    let source: URL
    let index: Int
    let count: Int
    let options: PipelineRunOptions
    let progress: @Sendable (PipelineProgress) -> Void

    var current: URL
    var context: TemplateContext
    var report: PipelineFileReport
    var stopped = false
    let fm = FileManager.default

    init(runner: PipelineRunner, pipeline: Pipeline, source: URL, index: Int, count: Int, counter: Int, options: PipelineRunOptions, progress: @escaping @Sendable (PipelineProgress) -> Void) {
        self.runner = runner
        self.pipeline = pipeline
        self.source = source.standardizedFileURL
        self.index = index
        self.count = count
        self.options = options
        self.progress = progress
        current = self.source
        context = TemplateContext(file: self.source, date: runner.now(), counter: counter)
        report = PipelineFileReport(source: self.source, kind: MediaKind.of(source), status: .completed, finalFile: self.source, extraOutputs: [], results: [], log: [])
    }

    /// The steps for this file: its kind's section (or the "any" section), with an `optimise`
    /// after any leading filters when the pipeline asks for one first.
    func steps(for kind: MediaKind) -> [PipelineStep] {
        var steps = pipeline.steps(for: kind)
        if pipeline.optimiseFirst, !pipeline.leadsWithReencode(for: kind) {
            let at = steps.firstIndex { !$0.isFilter } ?? steps.count
            steps.insert(.optimise(), at: at)
        }
        return steps
    }

    mutating func execute() async -> PipelineFileReport {
        guard fm.fileExists(atPath: source.path) else {
            report.status = .failed
            report.error = EsclopError.fileNotFound(source.path).description
            report.finalFile = nil
            return report
        }
        guard let kind = MediaKind.of(source) else {
            report.status = .unsupported
            report.error = EsclopError.unsupportedFile(source.lastPathComponent).description
            return report
        }
        let steps = steps(for: kind)
        if steps.isEmpty {
            report.status = .unsupported
            report.error = "The pipeline has no steps for \(kind.rawValue) files"
            return report
        }

        for (i, step) in steps.enumerated() {
            let text = step.text
            if Task.isCancelled {
                report.status = .cancelled
                break
            }
            let started = runner.now()
            func log(_ outcome: PipelineLogEntry.Outcome, _ message: String? = nil) {
                report.log.append(PipelineLogEntry(stepIndex: i, step: text, outcome: outcome, message: message, file: current, seconds: runner.now().timeIntervalSince(started)))
            }

            let currentKind = MediaKind.of(current) ?? kind
            if !step.kinds.contains(currentKind) {
                log(.skipped, "does not apply to \(currentKind.rawValue) files")
                continue
            }
            let fileIndex = index, fileCount = count, file = current, stepCount = steps.count
            let stepReport: @Sendable (Double, String?) -> Void = { [progress] fraction, message in
                progress(PipelineProgress(fileIndex: fileIndex, fileCount: fileCount, file: file, stepIndex: i, stepCount: stepCount, step: text, stepFraction: fraction, message: message))
            }
            stepReport(0, nil)
            do {
                let (outcome, message) = try await perform(step, at: i, of: steps, kind: currentKind, report: stepReport)
                log(outcome, message)
            } catch EsclopError.alreadySmaller {
                log(.unchanged, EsclopError.alreadySmaller.description)
            } catch is CancellationError {
                log(.failed, EsclopError.cancelled.description)
                self.report.status = .cancelled
                break
            } catch {
                let message = (error as? EsclopError)?.description ?? (error as? LocalizedError)?.errorDescription ?? "\(error)"
                log(.failed, message)
                self.report.status = .failed
                self.report.error = message
                break
            }
            if stopped {
                self.report.status = .filtered
                break
            }
        }
        report.finalFile = fm.fileExists(atPath: current.path) ? current : nil
        return report
    }

    typealias StepOutcome = (PipelineLogEntry.Outcome, String?)

    // MARK: Steps

    mutating func perform(_ step: PipelineStep, at i: Int, of steps: [PipelineStep], kind: MediaKind, report: @escaping @Sendable (Double, String?) -> Void) async throws -> StepOutcome {
        let engine = runner.engine
        let ops = engine as? any PipelineMediaOperations
        let engineProgress: @Sendable (OptimisationProgress) -> Void = { p in report(p.fraction, p.message) }

        switch step {
        case let .optimise(encoder, adaptive, dpi, location, compression):
            var note: String?
            var quality = options.quality
            switch (compression, encoder) {
            case let (.factor(n)?, _): quality = CompressionQuality(tier: .custom, factor: n)
            case (_, .aggressive): quality = .aggressive
            case (_, .lossless), (_, .visuallyLossless): quality = CompressionQuality(tier: .custom, factor: 0)
            default: break
            }
            if compression == .adaptive || adaptive { note = "adaptive optimisation is not available yet; used the regular settings" }
            let videoEncoder: VideoEncoder? = switch encoder {
            case .fast: .h264VideoToolbox
            case .slowHighQuality, .visuallyLossless: .h264Software
            default: nil
            }
            return try await engineStep(location, note: note, adjust: {
                $0.quality = quality
                $0.videoEncoder = videoEncoder
                $0.pdfDPI = dpi
            }) { url, req in try await engine.optimise(url, request: req, progress: engineProgress) }

        case let .downscale(factor, location):
            return try await engineStep(location) { url, req in try await engine.downscale(url, factor: factor, request: req, progress: engineProgress) }

        case let .lowerBitrate(kbps, location):
            let ops = try require(ops, "lowerBitrate")
            return try await engineStep(location) { url, req in try await ops.lowerBitrate(url, kbps: kbps, request: req, progress: engineProgress) }

        case let .convert(to, location):
            guard let target = ConvertTarget(to, kind: kind) else {
                throw EsclopError.invalidArgument("esclop cannot write \(to) files yet")
            }
            if target.matches(current) { return (.unchanged, "already \(to)") }
            return try await engineStep(location, newExtension: target.fileExtension, adjust: { $0.format = target.format; $0.videoEncoder = target.videoEncoder ?? $0.videoEncoder }) { url, req in
                try await engine.convert(url, to: target.format, request: req, progress: engineProgress)
            }

        case let .crop(width, height, longEdge, aspectRatio, smartCrop, location):
            let size = CropSize(width: width, height: height, longEdge: longEdge, aspectRatio: aspectRatio, smart: smartCrop)
            return try await engineStep(location, adjust: { $0.crop = size }) { url, req in try await engine.crop(url, to: size, request: req, progress: engineProgress) }

        case let .extractPagesAsImages(format, quality, location):
            let ops = try require(ops, "extractPagesAsImages")
            let dir = try pageDirectory(location)
            let request = baseRequest(location: .path(dir.path))
            let pages = try await ops.extractPages(current, format: format, scale: quality.scale, into: dir, request: request, progress: engineProgress)
            self.report.extraOutputs += pages
            if pages.count == 1 { current = pages[0] }
            return (.done, "\(pages.count) page\(pages.count == 1 ? "" : "s") in \(dir.path)")

        case let .targetSize(bytes, location):
            return try await engineStep(location, adjust: { $0.targetBytes = bytes }) { url, req in try await engine.fit(url, underBytes: bytes, request: req, progress: engineProgress) }

        case .stripExif:
            return try await engineStep(.inPlace, adjust: { $0.stripMetadata = true }) { url, req in try await engine.stripMetadata(url, request: req) }

        case let .watermark(image, position, opacity, scale, location):
            let ops = try require(ops, "watermark")
            let mark = URL(fileURLWithPath: absolute(context.resolve(image), relativeTo: source.deletingLastPathComponent()))
            guard fm.fileExists(atPath: mark.path) else { throw EsclopError.fileNotFound(mark.path) }
            return try await engineStep(location) { url, req in
                try await ops.watermark(url, image: mark, position: position, opacity: opacity, scale: scale, request: req, progress: engineProgress)
            }

        case let .copy(to):
            let dest = try destination(for: to)
            guard dest != current else { return (.unchanged, "already there") }
            try replaceItem(at: dest) { try fm.copyItem(at: current, to: dest) }
            current = dest
            return (.done, "copied to \(dest.path)")

        case let .move(to):
            let dest = try destination(for: to)
            guard dest != current else { return (.unchanged, "already there") }
            try replaceItem(at: dest) { try fm.moveItem(at: current, to: dest) }
            current = dest
            return (.done, "moved to \(dest.path)")

        case let .rename(to):
            var name = context.resolve(to)
            guard !name.isEmpty, !name.contains("/") else { throw EsclopError.invalidArgument("rename takes a file name, not a path: \(name)") }
            if !hasExtension(name, wanted: current.pathExtension) { name += current.pathExtension.isEmpty ? "" : ".\(current.pathExtension)" }
            let dest = current.deletingLastPathComponent().appendingPathComponent(name)
            guard dest != current else { return (.unchanged, nil) }
            try replaceItem(at: dest) { try fm.moveItem(at: current, to: dest) }
            current = dest
            return (.done, "renamed to \(name)")

        case let .delete(path):
            guard options.allowDelete else { throw EsclopError.notPermitted("deleting files is not allowed here") }
            let target: URL = switch path {
            case "sourceFile": source
            case "currentFile": current
            default: URL(fileURLWithPath: absolute(context.resolve(path), relativeTo: current.deletingLastPathComponent()))
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: target.path, isDirectory: &isDir) else { return (.unchanged, "nothing at \(target.path)") }
            if isDir.boolValue { throw EsclopError.notPermitted("pipelines never delete folders (\(target.path))") }
            try fm.trashItem(at: target, resultingItemURL: nil)
            return (.done, "moved \(target.path) to the Trash")

        case let .filterIf(condition):
            let (matches, captures) = await condition.evaluate(current, inspector: runner.inspector, sourceApp: options.sourceApp)
            if !matches {
                stopped = true
                return (.stopped, "condition not met")
            }
            if !captures.isEmpty { context.captures = captures }
            return (.done, "condition met")

        case let .filterIfNot(condition):
            let (matches, _) = await condition.evaluate(current, inspector: runner.inspector, sourceApp: options.sourceApp)
            if matches {
                stopped = true
                return (.stopped, "excluded")
            }
            return (.done, "not excluded")

        case .removeAudio:
            if let ops {
                return try await engineStep(.inPlace) { url, req in try await ops.removeAudio(url, request: req, progress: engineProgress) }
            }
            return try await engineStep(.inPlace, adjust: { $0.removeAudio = true }) { url, req in try await engine.optimise(url, request: req, progress: engineProgress) }

        case let .changeSpeed(factor, frames):
            if let ops {
                return try await engineStep(.inPlace) { url, req in
                    try await ops.changeSpeed(url, factor: factor, keepFrames: frames.map { $0 == .keep }, request: req, progress: engineProgress)
                }
            }
            guard frames == nil else { throw EsclopError.toolMissing("the engine cannot run `changeSpeed(frames:)` yet") }
            return try await engineStep(.inPlace, adjust: { $0.playbackSpeed = factor }) { url, req in try await engine.optimise(url, request: req, progress: engineProgress) }

        case let .capFps(fps):
            let ops = try require(ops, "capFps")
            return try await engineStep(.inPlace) { url, req in try await ops.capFrameRate(url, fps: fps, request: req, progress: engineProgress) }

        case let .normalize(lufs):
            let ops = try require(ops, "normalize")
            return try await engineStep(.inPlace) { url, req in try await ops.normalizeLoudness(url, lufs: lufs, request: req, progress: engineProgress) }

        case let .runScript(path, code):
            return try await runScript(path: path, code: code, kind: kind)

        case let .runShortcut(name):
            return try await runShortcut(name, kind: kind)

        case let .copyToClipboard(format, relativeTo):
            return try await host(.copyToClipboard(format: format, relativeTo: relativeTo.map { context.resolve($0) }))
        case let .copyLinkForSending(expiration):
            return try await host(.copyLinkForSending(expiration: expiration))
        case let .shelveWith(app):
            return try await host(.shelve(app: app))
        case let .uploadWith(app):
            return try await host(.upload(app: app))
        case let .openWith(app):
            return try await host(.open(app: app))

        case let .fork(location):
            return try await fork(location, following: Array(steps[(i + 1)...]))
        }
    }

    func require(_ ops: (any PipelineMediaOperations)?, _ step: String) throws -> any PipelineMediaOperations {
        guard let ops else { throw EsclopError.toolMissing("the engine cannot run `\(step)` yet") }
        return ops
    }

    // MARK: Engine steps and locations

    func baseRequest(location: OutputLocation) -> OptimisationRequest {
        OptimisationRequest(sources: [current], origin: options.origin, quality: options.quality, location: location, showResultUI: false)
    }

    /// Runs an engine call with the step's location resolved, and makes its output the current file.
    mutating func engineStep(
        _ location: OutputLocation, newExtension: String? = nil, note: String? = nil,
        adjust: (inout OptimisationRequest) -> Void = { _ in },
        _ call: (URL, OptimisationRequest) async throws -> OptimisationResult
    ) async throws -> StepOutcome {
        var request = baseRequest(location: try resolve(location, newExtension: newExtension))
        adjust(&request)
        let result = try await call(current, request)
        report.results.append(result)
        current = result.output
        let saved = result.bytesBefore > 0 ? " (\(Int((result.savedFraction * 100).rounded()))% smaller)" : ""
        return (.done, ([note, "\(result.output.lastPathComponent)\(saved)"].compactMap { $0 }).joined(separator: "; "))
    }

    /// Turns a step's location into what the engine gets: `.inPlace` and `.temporary` as they are,
    /// `.sameFolder` next to the original file, and templates as absolute file paths.
    func resolve(_ location: OutputLocation, newExtension: String?) throws -> OutputLocation {
        let ext = newExtension ?? current.pathExtension
        let originalDir = source.deletingLastPathComponent()
        switch location {
        case .inPlace, .temporary:
            return location
        case .sameFolder:
            if current.deletingLastPathComponent() == originalDir { return .sameFolder }
            return .path(originalDir.appendingPathComponent(current.deletingPathExtension().lastPathComponent).appendingPathExtension(ext).path)
        case let .path(template):
            let resolved = context.resolve(template)
            guard !resolved.isEmpty else { return .inPlace }
            var path = absolute(resolved, relativeTo: originalDir)
            var isDir: ObjCBool = false
            if resolved.hasSuffix("/") || (fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue) {
                path = URL(fileURLWithPath: path).appendingPathComponent(current.deletingPathExtension().lastPathComponent).appendingPathExtension(ext).path
            } else if !hasExtension((path as NSString).lastPathComponent, wanted: ext) {
                path += ext.isEmpty ? "" : ".\(ext)"
            }
            try fm.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            return .path(path)
        }
    }

    /// Destination of `copy` and `move`: relative paths start in the current file's folder, a
    /// trailing `/` or an existing folder means "into it", and a missing extension is added.
    func destination(for template: String) throws -> URL {
        let resolved = context.resolve(template)
        guard !resolved.isEmpty else { throw EsclopError.invalidArgument("empty destination") }
        var path = absolute(resolved, relativeTo: current.deletingLastPathComponent())
        var isDir: ObjCBool = false
        if resolved.hasSuffix("/") || (fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue) {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            path = (path as NSString).appendingPathComponent(current.lastPathComponent)
        } else if !hasExtension((path as NSString).lastPathComponent, wanted: current.pathExtension), !current.pathExtension.isEmpty {
            path += ".\(current.pathExtension)"
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    func pageDirectory(_ location: OutputLocation) throws -> URL {
        let dir: URL = switch location {
        case .sameFolder: source.deletingLastPathComponent()
        case .inPlace: current.deletingLastPathComponent()
        case .temporary: options.temporaryDirectory
        case let .path(t): URL(fileURLWithPath: absolute(context.resolve(t), relativeTo: source.deletingLastPathComponent()))
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Overwrites like Clop does: an existing file at the destination is replaced.
    func replaceItem(at dest: URL, _ action: () throws -> Void) throws {
        if fm.fileExists(atPath: dest.path) {
            // Replacing a file is deleting it: the same switch as the delete step.
            guard options.allowDelete else {
                throw EsclopError.notPermitted("\(dest.path) already exists and replacing files is not allowed here")
            }
            try fm.removeItem(at: dest)
        }
        try action()
    }

    func absolute(_ path: String, relativeTo dir: URL) -> String {
        path.hasPrefix("/") ? path : dir.appendingPathComponent(path).path
    }

    /// Whether `name` already ends in the wanted extension or another media extension, so a
    /// template like `%f-small` gets one added and `cover.jpg` does not.
    func hasExtension(_ name: String, wanted: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return ext == wanted.lowercased() || MediaKind.of(URL(fileURLWithPath: name)) != nil
    }

    // MARK: Fork

    mutating func fork(_ location: OutputLocation?, following: [PipelineStep]) async throws -> StepOutcome {
        let forked: URL
        switch location {
        case .temporary?, nil:
            if location == nil, !clobbers(following) {
                forked = current
            } else {
                forked = try copyToTemporary(current, prefix: "fork")
            }
        case .inPlace?:
            forked = current
        case let location?:
            guard case let .path(p) = try resolve(location, newExtension: nil) else {
                // `.sameFolder` for a file already next to the original: copy with a suffix.
                let dest = source.deletingLastPathComponent().appendingPathComponent("\(current.deletingPathExtension().lastPathComponent)-fork").appendingPathExtension(current.pathExtension)
                try replaceItem(at: dest) { try fm.copyItem(at: current, to: dest) }
                report.extraOutputs.append(dest)
                return try await presentFork(dest)
            }
            let dest = URL(fileURLWithPath: p)
            if dest != current { try replaceItem(at: dest) { try fm.copyItem(at: current, to: dest) } }
            forked = dest
        }
        report.extraOutputs.append(forked)
        return try await presentFork(forked)
    }

    /// The fork exists either way; showing it as a result is up to the host.
    func presentFork(_ file: URL) async throws -> StepOutcome {
        _ = try await runner.host.perform(.presentFork, file: file, options: options)
        return (.done, "forked \(file.path)")
    }

    /// Whether a later step would overwrite, move or delete the current file.
    func clobbers(_ steps: [PipelineStep]) -> Bool {
        steps.contains { step in
            switch step {
            case .delete, .move, .rename: true
            case .convert: step.location == .inPlace
            case .optimise, .downscale, .lowerBitrate, .crop, .targetSize, .watermark: step.location == .inPlace
            case .stripExif, .capFps, .normalize, .removeAudio, .changeSpeed, .runScript, .runShortcut: true
            default: false
            }
        }
    }

    func copyToTemporary(_ file: URL, prefix: String) throws -> URL {
        let dir = options.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(file.lastPathComponent)
        try fm.copyItem(at: file, to: dest)
        return dest
    }

    // MARK: Host

    func host(_ action: PipelineHostAction) async throws -> StepOutcome {
        switch try await runner.host.perform(action, file: current, options: options) {
        case let .handled(message): return (.done, message)
        case let .unavailable(reason): return (.skipped, reason)
        }
    }

    // MARK: Scripts and Shortcuts

    mutating func runScript(path: String?, code: String?, kind: MediaKind) async throws -> StepOutcome {
        guard options.allowRunScripts else {
            throw EsclopError.notPermitted("running scripts is turned off; allow it in esclop's settings")
        }
        var env = ProcessInfo.processInfo.environment
        env["ESCLOP_INPUT_FILE"] = current.path
        if let bin = options.binDirectory { env["ESCLOP_BIN"] = bin.path }
        let zsh = URL(fileURLWithPath: "/bin/zsh")
        let output: CommandOutput
        if let code, !code.isEmpty {
            // Inline code runs as written: `$1` is the file, `%` tokens are not expanded.
            output = try await runner.commands.run(zsh, ["-c", code, "esclop", current.path], environment: env, input: nil)
        } else {
            let script = absolute(context.resolve(path ?? ""), relativeTo: source.deletingLastPathComponent())
            if fm.isExecutableFile(atPath: script) {
                output = try await runner.commands.run(URL(fileURLWithPath: script), [current.path], environment: env, input: nil)
            } else {
                output = try await runner.commands.run(zsh, [script, current.path], environment: env, input: nil)
            }
        }
        guard output.status == 0 else {
            let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).suffix(2000)
            throw EsclopError.toolFailed(tool: "script", exitCode: output.status, stderr: String(detail))
        }
        // A script that prints the path of a file of the same kind hands that file on.
        let printed = TemplateContext.expandHome(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        if !printed.isEmpty, fm.fileExists(atPath: printed) {
            let url = URL(fileURLWithPath: absolute(printed, relativeTo: current.deletingLastPathComponent())).standardizedFileURL
            if url != current, MediaKind.of(url) == nil || MediaKind.of(url) == kind {
                current = url
                return (.done, "continuing with \(url.path)")
            }
        }
        return (.done, nil)
    }

    mutating func runShortcut(_ name: String, kind: MediaKind) async throws -> StepOutcome {
        let dir = options.temporaryDirectory.appendingPathComponent("shortcut-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(current.lastPathComponent)
        let result = try await runner.commands.run(
            URL(fileURLWithPath: "/usr/bin/shortcuts"), ["run", name, "--input-path", current.path, "--output-path", out.path], environment: nil, input: nil
        )
        guard result.status == 0 else {
            throw EsclopError.toolFailed(tool: "shortcuts", exitCode: result.status, stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let size = runner.inspector.fileSize(out), size > 0, MediaKind.of(out) == kind {
            current = out
            return (.done, "continuing with the Shortcut's output")
        }
        return (.done, nil)
    }
}

// MARK: - Convert targets

/// What `convert(to:)` asks the engine for.
struct ConvertTarget {
    var name: String
    var format: OutputFormat
    var videoEncoder: VideoEncoder?

    init?(_ name: String, kind: MediaKind) {
        self.name = name
        switch name {
        case "jpg", "jpeg": format = .jpeg
        case "gif": format = kind == .video ? .gifVideo : .gif
        case "x265":
            format = .hevc
            videoEncoder = .hevcSoftware
        case "hevc":
            format = .hevc
            videoEncoder = .hevcVideoToolbox
        case "tif": format = .tiff
        default:
            guard let f = OutputFormat(rawValue: name), f != .gifVideo else { return nil }
            format = f
        }
    }

    /// The extension the output file will have.
    var fileExtension: String {
        switch format {
        case .jpeg: "jpg"
        case .gifVideo: "gif"
        case .hevc, .av1: "mp4"
        default: format.rawValue
        }
    }

    /// Whether the file already is this format, so converting would do nothing.
    func matches(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        switch format {
        case .jpeg: return ext == "jpg" || ext == "jpeg"
        case .tiff: return ext == "tif" || ext == "tiff"
        case .gif, .gifVideo: return ext == "gif"
        case .hevc, .av1: return false
        default: return ext == format.rawValue
        }
    }
}
