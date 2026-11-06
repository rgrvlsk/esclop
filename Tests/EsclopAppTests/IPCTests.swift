// SPDX-License-Identifier: GPL-3.0-or-later

import EsclopCore
import EsclopIPC
@testable import EsclopAppKit
import Foundation
import Testing

@MainActor
@Suite struct IPCHandlerTests {
    @Test func agentsCannotOverwriteOriginalsThroughTheApp() async throws {
        let harness = Harness()
        let handler = AppIPCHandler(model: harness.model) {}
        let file = harness.temp.file("a.png")
        await #expect(throws: EsclopError.self) {
            try await handler.perform(harness.job(file, origin: .mcp, location: .inPlace)) { _ in }
        }
        #expect(harness.model.cards.isEmpty)
        #expect(AppModel.size(of: file) == 100_000, "the file is untouched")
        // The CLI may.
        try await handler.perform(harness.job(file, origin: .cli)) { _ in }
        #expect(harness.model.cards.first?.result != nil)
    }

    @Test func settingsFollowTheAgentRules() async throws {
        let harness = Harness()
        let handler = AppIPCHandler(model: harness.model) {}
        await #expect(throws: EsclopError.self) {
            _ = try await handler.settings(.set(key: "allowRunScripts", value: "true"), origin: .mcp)
        }
        await #expect(throws: EsclopError.self) {
            _ = try await handler.settings(.set(key: "stripMetadata", value: "false"), origin: .mcp)
        }
        let reply = try await handler.settings(.set(key: "pauseAutomaticOptimisations", value: "true"), origin: .cli)
        guard case let .value(_, value) = reply else { Issue.record("no value"); return }
        #expect(value == .bool(true))
        #expect(harness.model.paused, "the menu follows a pause set from the CLI")
        guard case let .descriptors(list) = try await handler.settings(.schema(query: "results corner"), origin: .mcp) else { return }
        #expect(list.map(\.key) == ["floatingResultsCorner"])
    }

    @Test func statusAndRecentResults() async throws {
        let harness = Harness()
        let handler = AppIPCHandler(model: harness.model) {}
        _ = await harness.model.run(harness.job(harness.temp.file("a.png")))
        #expect(await handler.status().activeJobs == 0)
        #expect(await handler.recentResults(limit: 5).count == 1)
    }

    /// The whole route: a client sends a job over the message ports, the app runs it with a
    /// card and streams the result back.
    @Test func cliJobsRouteThroughTheRunningApp() async throws {
        let harness = Harness()
        let ports = IPCPorts(prefix: "dev.esclop.app-tests.\(UUID().uuidString.prefix(8))")
        let server = AppServer(handler: AppIPCHandler(model: harness.model) {}, ports: ports)
        try server.start()
        defer { server.stop() }
        let client = AppClient(ports: ports, replyTimeout: 30)
        #expect(client.isAppRunning)
        let file = harness.temp.file("routed.png", bytes: 50_000)
        let report = try await client.perform(harness.job(file, origin: .cli))
        #expect(report.route == "app")
        #expect(report.results.first?.bytesAfter == 20_000)
        #expect(harness.model.cards.first?.result?.source.lastPathComponent == "routed.png")
        let status = try await client.status()
        #expect(status.pid == ProcessInfo.processInfo.processIdentifier)
    }
}

@MainActor
@Suite struct SettingsViewModelTests {
    @Test func listsEverySettingBySectionAndSearches() {
        let settings = TestSettings()
        let model = SettingsViewModel(provider: RegistrySettingsProvider(store: settings.store))
        #expect(model.groups.map(\.section) == SettingsSection.allCases)
        #expect(model.groups.flatMap(\.settings).count == SettingsRegistry.shared.all.count - SettingsViewModel.customised.count)
        model.query = "drop zone"
        #expect(model.groups.flatMap(\.settings).map(\.key).contains("enableDragAndDrop"))
        #expect(model.groups.first?.section == .interface)
    }

    @Test func writesAndReportsRefusals() {
        let settings = TestSettings()
        var changed: [String] = []
        let model = SettingsViewModel(provider: RegistrySettingsProvider(store: settings.store)) { key, _ in changed.append(key) }
        #expect(model.set("floatingResultsCorner", to: "topLeft"))
        #expect(EsclopSettings.floatingResultsCorner.value(in: settings.store) == .topLeft)
        #expect(model.value("floatingResultsCorner") == .string("topLeft"))
        #expect(!model.set("autoHideFloatingResultsAfter", to: "soon"))
        #expect(model.errors["autoHideFloatingResultsAfter"] != nil)
        #expect(changed == ["floatingResultsCorner"])
        #expect(SettingsViewModel.text(for: .array(["webp", "avif"])) == "webp, avif")
    }
}
