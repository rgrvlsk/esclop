// SPDX-License-Identifier: GPL-3.0-or-later

import EsclopCore
import EsclopIPC
@testable import EsclopMCP
import EsclopPipelines
import Foundation
import Testing

@Suite struct ServiceBehaviour {
    @Test func agentJobsAreGatedAndLogged() async throws {
        let temp = TempDir()
        let file = temp.file("a.png")
        let service = makeService(temp, origin: .mcp)
        await #expect(throws: EsclopError.self) {
            _ = try await service.perform(OptimisationJob(request: OptimisationRequest(sources: [file], origin: .mcp, location: .inPlace), operation: .optimise))
        }
        let report = try await service.perform(OptimisationJob(request: OptimisationRequest(sources: [file], origin: .mcp, location: .sameFolder), operation: .optimise))
        #expect(report.results.count == 1)
        #expect(await service.recentResults(limit: 10).map(\.id) == report.results.map(\.id))
    }

    @Test func originIsStampedByTheService() async throws {
        let temp = TempDir()
        // A request claiming to come from the CLI still counts as the agent's.
        await #expect(throws: EsclopError.self) {
            _ = try await makeService(temp, origin: .mcp).perform(OptimisationJob(
                request: OptimisationRequest(sources: [temp.file("a.png")], origin: .cli, location: .inPlace), operation: .optimise
            ))
        }
    }

    @Test func agentPipelinesRunOnCopies() async throws {
        let temp = TempDir()
        let original = temp.file("photo.png", bytes: 4000)
        let engine = FakeEngine()
        let service = makeService(temp, origin: .mcp, engine: engine)
        _ = try service.writePipeline(name: "shrink", source: "optimise", replace: false)
        let report = try await service.perform(OptimisationJob(
            request: OptimisationRequest(sources: [original], origin: .mcp, location: .sameFolder), operation: .pipeline("shrink")
        ))
        #expect(report.failures.isEmpty, "\(report.failures)")
        let copy = try #require(engine.sources.first)
        #expect(copy != original)
        #expect(copy.lastPathComponent == "photo-esclop.png")
        #expect(report.results.first?.source == copy)
        // With the permission, the pipeline gets the original.
        let allowed = FakeEngine()
        _ = try await makeService(temp, origin: .mcp, allow: [.allowOverwriteOriginals], engine: allowed).perform(OptimisationJob(
            request: OptimisationRequest(sources: [original], origin: .mcp, location: .inPlace), operation: .pipeline("optimise")
        ))
        #expect(allowed.sources == [original])
    }

    @Test func agentPipelinesCannotReplaceFiles() async throws {
        let temp = TempDir()
        let precious = temp.file("Documents/thesis.pdf", bytes: 777)
        let report = try await makeService(temp, origin: .mcp).perform(OptimisationJob(
            request: OptimisationRequest(sources: [temp.file("a.png")], origin: .mcp, location: .sameFolder),
            operation: .pipeline("copy(to: \"\(precious.path)\")")
        ))
        #expect(report.results.isEmpty)
        #expect(report.failures.first?.error.code == "other" || report.failures.first?.error.code == "notPermitted")
        #expect(try Data(contentsOf: precious).count == 777, "the existing file is untouched")
    }

    @Test func cliPipelinesUseTheRunner() async throws {
        let temp = TempDir()
        let file = temp.file("a.png")
        let engine = FakeEngine()
        let report = try await makeService(temp, origin: .cli, engine: engine).perform(OptimisationJob(
            request: OptimisationRequest(sources: [file], origin: .cli), operation: .pipeline("downscale(factor: 0.5) -> convert(to: webp)")
        ))
        #expect(engine.calls == ["downscale:0.5", "convert:webp"])
        #expect(report.results.first?.steps.contains { $0.hasPrefix("downscale") } == true)
    }

    @Test func badInlinePipelinesNameTheProblem() async {
        let temp = TempDir()
        do {
            _ = try await makeService(temp, origin: .cli).perform(OptimisationJob(
                request: OptimisationRequest(sources: [temp.file("a.png")], origin: .cli), operation: .pipeline("optimize")
            ))
            Issue.record("expected an error")
        } catch let EsclopError.invalidPipeline(message) {
            #expect(message.contains("optimise"), "suggests the right step: \(message)")
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func scriptPipelinesNeedPermission() async throws {
        let temp = TempDir()
        let service = makeService(temp, origin: .mcp)
        #expect(throws: EsclopError.self) { try service.writePipeline(name: "s", source: "runScript(code: \"echo hi\")", replace: false) }
        _ = try service.writePipeline(name: "w", source: "convert(to: webp)", replace: false)
        #expect(throws: EsclopError.self) { try service.writePipeline(name: "w", source: "convert(to: avif)", replace: false) }
        #expect(throws: EsclopError.self) { try service.writePipeline(name: "w", source: "convert(to: avif)", replace: true) }
        await #expect(throws: EsclopError.self) {
            _ = try await service.perform(OptimisationJob(
                request: OptimisationRequest(sources: [temp.file("a.png")], origin: .mcp, location: .sameFolder), operation: .pipeline("runShortcut(name: \"x\")")
            ))
        }
        let allowed = makeService(temp, origin: .mcp, allow: [.allowRunScripts, .allowSettingsChanges])
        _ = try allowed.writePipeline(name: "s", source: "runScript(code: \"echo hi\")", replace: false)
        _ = try allowed.writePipeline(name: "w", source: "convert(to: avif)", replace: true)
        #expect(try allowed.context.pipelines.text(of: "w").contains("avif"))
    }

    @Test func automationsNeedPermission() throws {
        let temp = TempDir()
        let service = makeService(temp, origin: .mcp)
        _ = try service.writePipeline(name: "p", source: "optimise", replace: false)
        #expect(throws: EsclopError.self) { try service.attach(.clipboard, to: "p") }
        #expect(throws: EsclopError.self) { try service.writePipeline(name: "auto", source: "---\ntriggers: clipboard\n---\noptimise", replace: false) }
        #expect(throws: Never.self) { try service.writePipeline(name: "agent", source: "---\ntriggers: mcp\n---\noptimise", replace: false) }

        let allowed = makeService(temp, origin: .mcp, allow: [.allowSettingsChanges])
        let attached = try allowed.attach(.folder(temp.url.path), to: "p")
        #expect(attached.triggers == [.folder(temp.url.path)])
        #expect(throws: EsclopError.self) { try service.deletePipeline("p") }
        #expect(try allowed.detach(.folder(temp.url.path), from: nil) == ["p"])
        try service.deletePipeline("p")
        #expect(!service.context.pipelines.contains("p"))
    }

    @Test func presetsInstallAndBecomeZones() throws {
        let temp = TempDir()
        let cli = makeService(temp, origin: .cli)
        let preset = try #require(PipelineStore.presets.first)
        let zone = try cli.attach(.presetZone, to: preset.name)
        #expect(zone.triggers.contains(.presetZone))
        #expect(cli.context.pipelines.contains(preset.name))
        #expect(throws: EsclopError.self) { try cli.installPreset(preset.name, replace: false) }
        #expect(try cli.detach(.presetZone, from: preset.name) == [preset.name])
        #expect(throws: EsclopError.self) { try makeService(temp, origin: .mcp).installPreset(preset.name, replace: true) }
    }

    @Test func permissionSettingsAreReadOnlyForAgents() async throws {
        let temp = TempDir()
        let service = makeService(temp, origin: .mcp, allow: [.allowSettingsChanges])
        await #expect(throws: EsclopError.self) { _ = try await service.setSetting("allowRunScripts", to: "true") }
        #expect(try await makeService(temp, origin: .cli).setSetting("allowRunScripts", to: "true") == .bool(true))
    }

    @Test func resetGoesThroughTheSameGate() async throws {
        let temp = TempDir()
        let cli = makeService(temp, origin: .cli)
        _ = try await cli.setSetting("allowRunScripts", to: "true")
        #expect(throws: EsclopError.self) { _ = try makeService(temp, origin: .mcp, allow: [.allowSettingsChanges]).resetSetting("allowRunScripts") }
        #expect(try cli.resetSetting("allowRunScripts") == .bool(false))
        #expect(try await cli.setting("allowRunScripts").value == .bool(false))
        #expect(throws: EsclopError.self) { _ = try cli.resetSetting("noSuchSetting") }
    }

    @Test func restoreBringsTheOriginalBack() async throws {
        let temp = TempDir()
        let original = temp.file("photo.jpg", bytes: 100)
        let backup = temp.file("backups/photo.jpg", bytes: 5000)
        let service = makeService(temp, origin: .mcp, allow: [.allowOverwriteOriginals])
        service.results.append([OptimisationResult(source: original, output: original, backup: backup, kind: .image, bytesBefore: 5000, bytesAfter: 100, startedAt: Date(), finishedAt: Date())])
        await #expect(throws: EsclopError.self) { _ = try await service.restoreBackup(for: original, deleteBackup: true) }
        let outcome = try await service.restoreBackup(for: original, deleteBackup: false)
        #expect(outcome.restored == original.path)
        #expect(try Data(contentsOf: original).count == 5000)
        #expect(FileManager.default.fileExists(atPath: backup.path))
        await #expect(throws: EsclopError.self) { _ = try await makeService(temp, origin: .mcp).restoreBackup(for: original, deleteBackup: false) }
    }

    @Test func statusReportsPermissionsAndRoute() async {
        let temp = TempDir()
        let status = await makeService(temp, origin: .mcp, allow: [.allowDeleteBackups]).status()
        #expect(status.route == "in-process")
        #expect(!status.app.running)
        #expect(status.permissions["allowDeleteBackups"] == true)
        #expect(status.permissions["allowOverwriteOriginals"] == false)
        #expect(status.engine == "fake")
    }

    @Test func logWindowIsValidated() {
        #expect(throws: EsclopError.self) { try makeService(TempDir(), origin: .cli).logs(window: "yesterday") }
    }

    @Test func triggersParse() throws {
        let temp = TempDir()
        #expect(try PipelineTriggers.parse("Drop Zone") == .dropZone)
        #expect(try PipelineTriggers.parse("clipboard") == .clipboard)
        #expect(try PipelineTriggers.parse(temp.url.path) == .folder(PathInput.abbreviate(temp.url)))
        #expect(try PipelineTriggers.parse("folder(\"\(temp.url.path)\")") == .folder(PathInput.abbreviate(temp.url)))
        #expect(throws: EsclopError.self) { try PipelineTriggers.parse("/no/such/folder") }
        #expect(throws: EsclopError.self) { try PipelineTriggers.parse("sometimes") }
    }
}
