// SPDX-License-Identifier: GPL-3.0-or-later
//
// Glue between EsclopPipelines and the CLI / MCP: what a pipeline looks
// like in output, how people and agents name triggers, and `PipelineRunning` over
// `PipelineRunner` so `JobExecutor` (and the app) can run pipelines.

import EsclopCore
import EsclopIPC
import EsclopPipelines
import Foundation

extension Pipeline {
    var allSteps: [PipelineStep] { sections.flatMap(\.steps) }

    /// Steps that upload the file to one of the person's upload targets.
    public var usesUploads: Bool {
        allSteps.contains { if case .upload = $0 { return true } else { return false } }
    }

    /// Steps that run the person's own code or Shortcuts.
    public var usesScripts: Bool {
        allSteps.contains { step in
            switch step {
            case .runScript, .runShortcut: return true
            default: return false
            }
        }
    }

    /// Triggers that make esclop act on its own or change the person's menus: everything except
    /// being offered to the CLI and MCP.
    public var automationTriggers: [PipelineTrigger] {
        triggers.filter { $0 != .cli && $0 != .mcp }
    }
}

/// A pipeline as the CLI's `--json` and the MCP tools show it.
public struct PipelineInfo: Codable, Sendable, Hashable {
    public var name: String
    public var description: String?
    /// As written in the file: `clipboard`, `folder("~/Downloads")`.
    public var triggers: [String]
    /// `all` for steps that apply to every kind, otherwise image, video, pdf, audio.
    public var kinds: [String]
    /// What it does, in words.
    public var summary: String
    /// The pipeline text (front matter, sections and steps).
    public var text: String
    public var usesScripts: Bool
    public var path: String?
    public var valid: Bool
    /// Parse errors and warnings with line and column.
    public var problems: [String]

    public init(_ pipeline: Pipeline, text: String? = nil, path: URL? = nil, problems: [String] = []) {
        name = pipeline.name
        description = pipeline.description
        triggers = pipeline.triggers.map(\.description)
        kinds = pipeline.sections.map { $0.kind?.rawValue ?? "all" }
        summary = PipelineLanguage.describe(pipeline)
        self.text = text ?? pipeline.text
        usesScripts = pipeline.usesScripts
        self.path = path?.path
        valid = true
        self.problems = problems
    }

    public init(entry: PipelineStoreEntry) {
        let text = (try? String(contentsOf: entry.url, encoding: .utf8)) ?? ""
        if let pipeline = entry.pipeline {
            self.init(pipeline, text: text, path: entry.url, problems: entry.diagnostics.map(\.description))
        } else {
            self.init(broken: entry.name, text: text, path: entry.url, problems: entry.diagnostics.map(\.description))
        }
    }

    private init(broken name: String, text: String, path: URL, problems: [String]) {
        self.name = name
        description = nil
        triggers = []
        kinds = []
        summary = "Does not parse"
        self.text = text
        usesScripts = false
        self.path = path.path
        valid = false
        self.problems = problems
    }

    /// `name: summary (triggers)` on one line.
    public var line: String {
        var text = "\(name): \(valid ? summary : "has errors: " + problems.joined(separator: "; "))"
        if !triggers.isEmpty { text += " [\(triggers.joined(separator: ", "))]" }
        return text
    }
}

public struct PresetInfo: Codable, Sendable, Hashable {
    public var name: String
    public var summary: String
    public var text: String
    /// A saved pipeline with the same name exists.
    public var installed: Bool

    /// Every built-in preset, marked when the store already has one by that name.
    public static func all(in store: PipelineStore) -> [PresetInfo] {
        PipelineStore.presets.map {
            PresetInfo(name: $0.name, summary: PipelineLanguage.describe($0), text: $0.text, installed: store.contains($0.name))
        }
    }
}

public enum PipelineTriggers {
    public static let help = "clipboard, dropZone, presetZone, rightClick, cli, mcp, or a folder path"

    /// What a person or agent typed: a trigger name, `folder("...")`, or a folder path.
    public static func parse(_ raw: String) throws -> PipelineTrigger {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let squashed = text.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        if let name = PipelineTrigger.simpleNames.first(where: { $0.lowercased() == squashed }) {
            return PipelineTrigger(name: name)!
        }
        var path = text
        if text.hasPrefix("folder("), text.hasSuffix(")") {
            path = String(text.dropFirst(7).dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        guard path.hasPrefix("/") || path.hasPrefix("~") || path.lowercased().hasPrefix("file:") else {
            throw EsclopError.invalidArgument("A trigger is \(help); not \(raw)")
        }
        let url = try PathInput.url(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw EsclopError.invalidArgument("\(path) is not an existing folder")
        }
        return .folder(PathInput.abbreviate(url))
    }
}

/// `PipelineRunning` over the pipeline runner and store.
public struct StorePipelineRunner: PipelineRunning {
    public let store: PipelineStore
    public let allowRunScripts: Bool
    public let allowDelete: Bool
    public let temporaryDirectory: URL
    /// What steps that need the app reach (the app's own host, with uploads); nil: the default for
    /// the origin, which cannot upload.
    public let host: (any PipelineHost)?

    public init(store: PipelineStore, allowRunScripts: Bool, allowDelete: Bool, temporaryDirectory: URL = Paths.temporary, host: (any PipelineHost)? = nil) {
        self.store = store
        self.allowRunScripts = allowRunScripts
        self.allowDelete = allowDelete
        self.temporaryDirectory = temporaryDirectory
        self.host = host
    }

    /// A saved name, a built-in preset, or inline steps.
    public func resolve(_ pipeline: String) throws -> Pipeline {
        do { return try store.resolve(pipeline) } catch let error as PipelineSyntaxError { throw error.esclopError }
    }

    public func usesScripts(_ pipeline: String) throws -> Bool {
        try resolve(pipeline).usesScripts
    }

    public func usesUploads(_ pipeline: String) throws -> Bool {
        try resolve(pipeline).usesUploads
    }

    public func run(
        pipeline: String, on source: URL, request: OptimisationRequest, engine: any OptimisationEngine,
        progress: @escaping @Sendable (OptimisationProgress) -> Void
    ) async throws -> OptimisationResult {
        let resolved = try resolve(pipeline)
        let started = Date()
        let before = Self.size(source)
        let host: any PipelineHost = self.host ?? (request.origin == .cli ? CommandLinePipelineHost() : NoopPipelineHost())
        let options = PipelineRunOptions(
            origin: request.origin, allowRunScripts: allowRunScripts, allowDelete: allowDelete,
            quality: request.quality, temporaryDirectory: temporaryDirectory
        )
        let requestID = request.id
        let report = await PipelineRunner(engine: engine, host: host).run(resolved, on: [source], options: options) { step in
            progress(OptimisationProgress(requestID: requestID, source: source, fraction: step.overallFraction, message: step.step))
        }
        guard let file = report.files.first else { throw EsclopError.other("The pipeline produced no report") }
        let log = file.log.map { entry in
            "\(entry.step): \(entry.outcome.rawValue)\(entry.message.map { " (\($0))" } ?? "")"
        }
        switch file.status {
        case .completed, .filtered:
            let output = file.finalFile ?? source
            let last = file.results.last
            return OptimisationResult(
                source: source, output: output, backup: file.results.first?.backup,
                kind: file.kind ?? MediaKind.of(source) ?? .image,
                bytesBefore: before, bytesAfter: file.finalFile.map(Self.size) ?? 0,
                width: last?.width, height: last?.height, duration: last?.duration,
                startedAt: started, finishedAt: Date(),
                steps: (file.status == .filtered ? ["filtered: no step applied"] : []) + log + file.extraOutputs.map { "also wrote \($0.path)" }
            )
        case .cancelled:
            throw EsclopError.cancelled
        case .unsupported:
            throw EsclopError.unsupportedFile(file.error ?? "\(source.lastPathComponent): the pipeline has no steps for this kind of file")
        case .failed:
            throw EsclopError.other(([file.error ?? "The pipeline failed"] + log).joined(separator: "\n"))
        }
    }

    static func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }
}
