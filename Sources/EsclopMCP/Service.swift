// SPDX-License-Identifier: GPL-3.0-or-later
//
// What the CLI and the MCP server do, in one place: route a job to the running app or run it
// in-process, read and change settings, manage pipelines, report status, read logs and restore
// backups. Both front ends are thin layers of argument parsing and output over this.

import EsclopCore
import EsclopIPC
import EsclopPipelines
import Foundation

// MARK: - Context

/// Service dependencies, injected by the host or tests.
public struct ServiceContext: Sendable {
    public var origin: RequestOrigin
    public var engine: any OptimisationEngine
    /// Shown in `status`, e.g. "EsclopEngine" or "unavailable".
    public var engineName: String
    public var settings: any SettingsProvider
    public var pipelines: PipelineStore
    public var locations: EsclopLocations
    public var app: AppClient
    /// False forces in-process work even when the app runs (`--in-process`, `ESCLOP_NO_APP=1`).
    public var useApp: Bool

    public init(
        origin: RequestOrigin, engine: any OptimisationEngine, engineName: String, settings: any SettingsProvider,
        pipelines: PipelineStore,
        locations: EsclopLocations, app: AppClient = AppClient(), useApp: Bool = true
    ) {
        self.origin = origin
        self.engine = engine
        self.engineName = engineName
        self.settings = settings
        self.pipelines = pipelines
        self.locations = locations
        self.app = app
        self.useApp = useApp
    }
}

// MARK: - Reports

public struct StatusReport: Codable, Sendable {
    public struct AppState: Codable, Sendable {
        public var running: Bool
        public var used: Bool
        public var pid: Int32?
        public var version: String?
        public var activeJobs: Int?
    }

    public var version: String
    public var app: AppState
    /// Where the next job runs: `app` or `in-process`.
    public var route: String
    public var engine: String
    public var permissions: [String: Bool]
    public var paths: [String: String]
    public var pipelines: Int
    /// The corresponding source (GPL/AGPL), when this build knows it.
    public var source: String?
    public var mcpServer: String
}

public struct RestoreOutcome: Codable, Sendable {
    public var restored: String
    public var from: String
    public var backupDeleted: Bool
    public var leftInPlace: String?
}

public struct LogExcerpt: Codable, Sendable {
    public var window: String
    public var system: [String]
    public var files: [String: [String]]
    public var note: String?
}

// MARK: - Service

public struct EsclopService: Sendable {
    public let context: ServiceContext

    public init(_ context: ServiceContext) {
        self.context = context
    }

    public var policy: AgentPolicy { AgentPolicy(origin: context.origin, permissions: context.settings) }
    public var results: ResultsLog { ResultsLog(url: context.locations.recentResults) }
    public var executor: JobExecutor {
        JobExecutor(engine: context.engine, pipelineRunner: pipelineRunner, backups: context.locations.backups)
    }

    /// Stream B's runner over the saved pipelines, with this caller's permissions.
    public var pipelineRunner: StorePipelineRunner {
        StorePipelineRunner(
            store: context.pipelines,
            allowRunScripts: policy.allowed(.allowRunScripts),
            allowDelete: policy.allowed(.allowOverwriteOriginals),
            temporaryDirectory: Paths.temporary
        )
    }

    /// True when jobs go through the app.
    public var routesThroughApp: Bool { context.useApp && context.app.isAppRunning }

    // MARK: Jobs

    public func perform(_ job: OptimisationJob, progress: @escaping @Sendable (OptimisationProgress) -> Void = { _ in }) async throws -> JobReport {
        var job = job
        job.request.origin = context.origin
        var usesScripts = false
        var uploads = false
        if case let .pipeline(pipeline) = job.operation {
            usesScripts = try pipelineRunner.usesScripts(pipeline)
            uploads = try pipelineRunner.usesUploads(pipeline)
        }
        try policy.check(job, pipelineUsesScripts: usesScripts, pipelineUploads: uploads)
        if case .upload = job.operation, context.useApp, !context.app.isAppRunning {
            // Only the app holds the upload keys: start it rather than fail.
            try await context.app.launchApp()
        }
        if case .pipeline = job.operation, policy.applies, !policy.allowed(.allowOverwriteOriginals) {
            // Pipeline steps choose their own locations (optimise works in place). An agent that may
            // not overwrite originals runs the pipeline on copies written where it asked.
            job.request.sources = try job.request.sources.map { try workingCopy(of: $0, location: job.request.location) }
        }

        var report: JobReport
        if routesThroughApp {
            do {
                report = try await context.app.perform(job, progress: progress)
            } catch EsclopError.appNotRunning where !context.app.isAppRunning {
                // The app quit between the check and the send: do the work here instead.
                report = await executor.run(job) { if case let .progress(p) = $0 { progress(p) } }
            }
        } else {
            report = await executor.run(job) { if case let .progress(p) = $0 { progress(p) } }
        }
        results.append(report.results)
        return report
    }

    /// A copy of `source` for an agent's pipeline run, placed where `location` says.
    func workingCopy(of source: URL, location: OutputLocation) throws -> URL {
        guard FileManager.default.fileExists(atPath: source.path) else { return source }
        let target = try OutputPlanner.destination(for: source, location: location, suffix: "esclop")
        guard target.standardizedFileURL != source.standardizedFileURL else { return source }
        // Never replaces anything: copyItem fails when the target exists.
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    /// Cancels jobs the app is running.
    public func stop(_ ids: [UUID]) {
        guard routesThroughApp else { return }
        try? context.app.stop(ids)
    }

    // MARK: Settings

    public func settingsSchema(query: String?) async throws -> [SettingDescriptor] {
        if routesThroughApp, case let .descriptors(list) = try await context.app.settings(.schema(query: query), origin: context.origin) {
            return list
        }
        return context.settings.search(query)
    }

    public func setting(_ key: String) async throws -> SettingDescriptor {
        var descriptor = try context.settings.descriptor(forKey: key)
        if routesThroughApp, case let .value(_, value) = try await context.app.settings(.get(key: key), origin: context.origin) {
            descriptor.value = value
        }
        return descriptor
    }

    public func setSetting(_ key: String, to value: String) async throws -> JSONValue {
        let descriptor = try context.settings.descriptor(forKey: key)
        try policy.checkSettingsChange(descriptor)
        if routesThroughApp, case let .value(_, stored) = try await context.app.settings(.set(key: key, value: value), origin: context.origin) {
            return stored
        }
        return try context.settings.setValue(value, forKey: key)
    }

    /// Puts a setting back to its default. Writes the shared defaults suite directly: a running
    /// app sees the change, since its Settings window observes the suite.
    public func resetSetting(_ key: String) throws -> JSONValue {
        let descriptor = try context.settings.descriptor(forKey: key)
        try policy.checkSettingsChange(descriptor)
        return try context.settings.resetValue(forKey: key)
    }

    // MARK: Pipelines

    /// Saves pipeline text (steps, optionally with front matter and sections) after the gate.
    public func writePipeline(name: String, source: String, replace: Bool) throws -> Pipeline {
        try PipelineStore.validate(name: name)
        let parsed: Pipeline
        do { parsed = try PipelineParser.parse(source, name: name) } catch let error as PipelineSyntaxError { throw error.esclopError }
        let exists = context.pipelines.contains(name)
        if exists, !replace {
            throw EsclopError.invalidArgument("A pipeline named \(name) already exists. Pass replace to overwrite it (the old one goes to the Trash).")
        }
        try policy.checkPipelineWrite(replacing: exists, usesScripts: parsed.usesScripts)
        if policy.applies, !parsed.automationTriggers.isEmpty {
            try policy.checkAutomationChange()
        }
        if exists, context.pipelines.useTrash,
           let url = try? context.pipelines.entries().first(where: { $0.name.lowercased() == name.lowercased() })?.url {
            // Keep the replaced version recoverable, as delete does.
            _ = try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        do {
            return try context.pipelines.save(text: source, name: name, overwrite: true)
        } catch let error as PipelineSyntaxError {
            throw error.esclopError
        }
    }

    public func deletePipeline(_ name: String) throws {
        let pipeline = try loadPipeline(name)
        try policy.checkPipelineDelete(automatic: !pipeline.automationTriggers.isEmpty)
        try context.pipelines.delete(name)
    }

    public func loadPipeline(_ name: String) throws -> Pipeline {
        do { return try context.pipelines.load(name) } catch let error as PipelineSyntaxError { throw error.esclopError }
    }

    /// Adds a trigger to a saved pipeline. A built-in preset's name installs it first.
    public func attach(_ trigger: PipelineTrigger, to name: String) throws -> Pipeline {
        try policy.checkAutomationChange()
        if !context.pipelines.contains(name), PipelineStore.preset(named: name) != nil {
            try context.pipelines.install(preset: name)
        }
        let pipeline = try loadPipeline(name)
        if policy.applies, pipeline.usesScripts { try policy.checkPipelineWrite(replacing: false, usesScripts: true) }
        try context.pipelines.attach(trigger, to: pipeline.name)
        return try loadPipeline(pipeline.name)
    }

    /// Removes a trigger from one pipeline, or from every pipeline that has it. Returns the names.
    public func detach(_ trigger: PipelineTrigger, from name: String?) throws -> [String] {
        try policy.checkAutomationChange()
        let names = try name.map { [try loadPipeline($0).name] } ?? context.pipelines.pipelines(triggeredBy: trigger).map(\.name)
        return try names.filter { try context.pipelines.detach(trigger, from: $0) }
    }

    /// Copies a built-in preset into the pipelines folder.
    public func installPreset(_ name: String, replace: Bool) throws -> Pipeline {
        if context.pipelines.contains(name) {
            guard replace else { throw EsclopError.invalidArgument("A pipeline named \(name) already exists; pass replace") }
            try policy.checkPipelineWrite(replacing: true, usesScripts: false)
        }
        return try context.pipelines.install(preset: name, overwrite: replace)
    }

    // MARK: Status, results, logs

    public func status() async -> StatusReport {
        let running = context.app.isAppRunning
        var app = StatusReport.AppState(running: running, used: running && context.useApp)
        if running, let status = try? await context.app.status() {
            app.pid = status.pid
            app.version = status.version
            app.activeJobs = status.activeJobs
        }
        let locations = context.locations
        return StatusReport(
            version: EsclopVersion.string,
            app: app,
            route: app.used ? "app" : "in-process",
            engine: context.engineName,
            permissions: Dictionary(uniqueKeysWithValues: AgentPermission.allCases.map { ($0.rawValue, context.settings.isAllowed($0)) }),
            paths: [
                "support": PathInput.abbreviate(locations.support),
                "pipelines": PathInput.abbreviate(locations.pipelines),
                "backups": PathInput.abbreviate(locations.backups),
                "logs": PathInput.abbreviate(locations.logs),
                "recentResults": PathInput.abbreviate(locations.recentResults),
            ],
            pipelines: (try? context.pipelines.entries().count) ?? 0,
            source: EsclopVersion.sourceURL,
            mcpServer: "esclop-mcp"
        )
    }

    /// Newest first, from the shared log and, when it runs, the app.
    public func recentResults(limit: Int) async -> [OptimisationResult] {
        var all = results.recent(limit: limit)
        if routesThroughApp, let fromApp = try? await context.app.recentResults(limit: limit) {
            let known = Set(all.map(\.id))
            all += fromApp.filter { !known.contains($0.id) }
        }
        return Array(all.sorted { $0.finishedAt > $1.finishedAt }.prefix(limit))
    }

    /// Puts the backup of the most recent result for `path` (its source or its output) back at the
    /// source path.
    public func restoreBackup(for path: URL, deleteBackup: Bool) async throws -> RestoreOutcome {
        try policy.checkRestore(deleteBackup: deleteBackup)
        // Symlinks resolved on both sides: /tmp and /private/tmp are the same folder.
        func canonical(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
        let target = canonical(path)
        let candidates = await recentResults(limit: 500)
        guard let result = candidates.first(where: { canonical($0.output) == target || canonical($0.source) == target }) else {
            throw EsclopError.invalidArgument("No recent result for \(path.path). esclop_recent_results lists what can be restored")
        }
        return try restoreBackup(of: result, deleteBackup: deleteBackup)
    }

    /// Puts back the original of a result already in hand (the app's own windows).
    public func restoreBackup(of result: OptimisationResult, deleteBackup: Bool) throws -> RestoreOutcome {
        try policy.checkRestore(deleteBackup: deleteBackup)
        guard let backup = result.backup, FileManager.default.fileExists(atPath: backup.path) else {
            throw EsclopError.fileNotFound("No backup is kept for \(result.source.path); it was not changed in place")
        }
        let fm = FileManager.default
        let staging = result.source.deletingLastPathComponent().appendingPathComponent(".\(result.source.lastPathComponent).esclop-restore")
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: backup, to: staging)
        if fm.fileExists(atPath: result.source.path) {
            _ = try fm.replaceItemAt(result.source, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: result.source)
        }
        if deleteBackup { try fm.removeItem(at: backup) }
        let leftover = result.output.standardizedFileURL != result.source.standardizedFileURL && fm.fileExists(atPath: result.output.path)
        return RestoreOutcome(
            restored: result.source.path, from: backup.path, backupDeleted: deleteBackup,
            leftInPlace: leftover ? result.output.path : nil
        )
    }

    /// L'Esclop's unified-log messages from the last `window` (`10m`, `1h`, `2d`), plus the tail of
    /// its own log files.
    public func logs(window: String = "10m", limit: Int = 200) throws -> LogExcerpt {
        guard window.range(of: #"^\d+[smhd]$"#, options: .regularExpression) != nil else {
            throw EsclopError.invalidArgument("The window looks like 30s, 10m, 1h or 2d, not \(window)")
        }
        let limit = max(1, min(limit, 5000))
        var note: String?
        var system: [String] = []
        do {
            let output = try HelperProcess.run(
                "/usr/bin/log",
                ["show", "--style", "compact", "--info", "--last", window, "--predicate", "subsystem BEGINSWITH \"dev.esclop\""],
                timeout: 30
            )
            if output.timedOut { note = "log show timed out; try a shorter window" }
            system = output.stdout.split(separator: "\n").map(String.init)
                .filter { !$0.hasPrefix("Timestamp") && !$0.hasPrefix("Filtering the log data") }
                .suffix(limit).map { $0 }
        } catch {
            note = "log show failed: \(error)"
        }
        var files: [String: [String]] = [:]
        let folder = context.locations.logs
        if let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let newest = entries
                .filter { !$0.lastPathComponent.hasPrefix(".") }
                .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast
                    > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
                .prefix(3)
            for file in newest {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                files[PathInput.abbreviate(file)] = text.split(separator: "\n").suffix(limit).map(String.init)
            }
        }
        if system.isEmpty, files.isEmpty, note == nil { note = "Nothing logged in the last \(window)" }
        return LogExcerpt(window: window, system: system, files: files, note: note)
    }

    // MARK: App lifecycle

    public func startApp() async throws -> StatusReport {
        try await context.app.launchApp()
        return await status()
    }

    public func stopApp() async throws {
        try await context.app.quit()
    }
}
