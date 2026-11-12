// SPDX-License-Identifier: GPL-3.0-or-later
//
// The app's side of the CLI and MCP protocol. Jobs go into the same queue as the clipboard and
// the drop zone and show the same cards. Every request passes AgentPolicy here again, since the
// app is the place an agent cannot route around.

import AppKit
import EsclopCore
import EsclopIPC
import EsclopMCP
import Foundation

public final class AppIPCHandler: AppRequestHandler {
    let model: AppModel
    let settings: any SettingsProvider
    let terminate: @Sendable @MainActor () -> Void

    @MainActor
    public init(model: AppModel, terminate: @escaping @Sendable @MainActor () -> Void = { NSApp.terminate(nil) }) {
        self.model = model
        settings = model.service.context.settings
        self.terminate = terminate
    }

    public func perform(_ job: OptimisationJob, events: @escaping @Sendable (JobEvent) -> Void) async throws {
        let policy = AgentPolicy(origin: job.request.origin, permissions: settings)
        var usesScripts = false
        var uploads = false
        if case let .pipeline(pipeline) = job.operation, let runner = await model.executor(for: job.request.origin).pipelineRunner {
            usesScripts = try runner.usesScripts(pipeline)
            uploads = try runner.usesUploads(pipeline)
        }
        try policy.check(job, pipelineUsesScripts: usesScripts, pipelineUploads: uploads)
        await model.run(job, events: events)
        try Task.checkCancellation()
    }

    public func stop(_ request: StopRequest) async {
        guard request.remove else { return }
        await model.removeCards(ofJobs: request.ids)
    }

    public func settings(_ command: SettingsCommand, origin: RequestOrigin) async throws -> SettingsReply {
        let policy = AgentPolicy(origin: origin, permissions: settings)
        switch command {
        case let .schema(query):
            return .descriptors(settings.search(query))
        case let .get(key):
            return .value(key: key, value: try settings.value(forKey: key))
        case let .set(key, value):
            try policy.checkSettingsChange(try settings.descriptor(forKey: key))
            let stored = try settings.setValue(value, forKey: key)
            if key == EsclopSettings.pauseAutomaticOptimisations.key {
                await model.pauseChanged(stored.boolValue ?? false)
            }
            return .value(key: key, value: stored)
        }
    }

    public func status() async -> AppStatus {
        AppStatus(version: EsclopVersion.string, pid: ProcessInfo.processInfo.processIdentifier, activeJobs: await model.activeFiles)
    }

    public func recentResults(limit: Int) async -> [OptimisationResult] {
        Array(await model.recent.prefix(max(0, limit)))
    }

    public func quit() async {
        await terminate()
    }
}
