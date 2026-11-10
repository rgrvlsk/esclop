// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Agents and MCP pane against a temporary home folder: detection, connect and disconnect
// through a previewed change, refusing a file that changed after the preview, the snippets, and
// the live server test.

import EsclopCore
import EsclopIPC
import EsclopMCP
@testable import EsclopAppKit
import Foundation
import Testing

/// A home folder with a few agents in different states.
struct AgentsFixture {
    let temp = TempDir()
    static let command = ServerCommand(command: "/Applications/L'Esclop.app/Contents/MacOS/esclop")

    var installer: AgentInstaller {
        AgentInstaller(home: temp.url, applicationFolders: [temp.url.appendingPathComponent("Applications")], binaryFolders: [temp.url.appendingPathComponent("bin")])
    }

    func write(_ relative: String, _ text: String) {
        let url = temp.url.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func text(_ relative: String) -> String? {
        try? String(contentsOf: temp.url.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Claude Code connected, Cursor running another esclop, Codex found but not connected, Zed
    /// with a config that does not parse.
    func populate() {
        write(".claude.json", """
        {
          "numStartups": 12,
          "mcpServers": {
            "esclop": { "command": "/Applications/L'Esclop.app/Contents/MacOS/esclop", "args": ["mcp", "serve"] }
          }
        }

        """)
        write(".cursor/mcp.json", """
        {
          "mcpServers": {
            "esclop": { "command": "/opt/homebrew/bin/esclop", "args": ["mcp", "serve"] }
          }
        }

        """)
        write(".codex/auth.json", "{}\n")
        write(".config/zed/settings.json", "{ \"theme\": \n")
    }
}

@MainActor
@Suite struct AgentsPaneTests {
    @Test func detectsStates() async {
        let fixture = AgentsFixture()
        fixture.populate()
        let agents = AgentsModel(installer: fixture.installer, command: AgentsFixture.command)
        await agents.refresh()
        func state(_ id: String) -> AgentStatus.State? { agents.rows.first { $0.id == id }?.status.state }
        #expect(state("claude-code") == .installed)
        #expect(state("cursor") == .different)
        #expect(state("codex") == .absent)
        #expect(state("zed") == .unreadable)
        #expect(Set(agents.found.map(\.id)) == ["claude-code", "cursor", "codex", "zed"])
        #expect(agents.rows.count == AgentCatalog.all.count)
    }

    @Test func connectShowsTheChangeThenWritesIt() async throws {
        let fixture = AgentsFixture()
        fixture.populate()
        let agents = AgentsModel(installer: fixture.installer, command: AgentsFixture.command)
        await agents.refresh()
        let codex = try #require(AgentCatalog.agent("codex"))
        agents.connect(codex)
        let change = try #require(agents.pending)
        #expect(change.action == .install)
        #expect(fixture.text(".codex/config.toml") == nil, "nothing is written before the person agrees")
        #expect(change.diff().contains { $0.kind == .added && $0.text == "[mcp_servers.esclop]" })
        await agents.confirm()
        #expect(agents.pending == nil)
        #expect(fixture.text(".codex/config.toml") == change.after)
        #expect(agents.rows.first { $0.id == "codex" }?.status.state == .installed)
        guard case let .done(text)? = agents.outcomes["codex"] else { Issue.record("no outcome"); return }
        #expect(text.contains("Restart"))
    }

    @Test func updateReplacesAnotherEsclopAndKeepsABackup() async throws {
        let fixture = AgentsFixture()
        fixture.populate()
        let before = fixture.text(".cursor/mcp.json")
        let agents = AgentsModel(installer: fixture.installer, command: AgentsFixture.command)
        agents.connect(try #require(AgentCatalog.agent("cursor")))
        let change = try #require(agents.pending)
        #expect(change.diff().contains { $0.kind == .removed && $0.text.contains("/opt/homebrew/bin/esclop") })
        await agents.confirm()
        #expect(agents.rows.first { $0.id == "cursor" }?.status.state == .installed)
        let backup = try #require(change.backup)
        #expect(try String(contentsOf: backup, encoding: .utf8) == before)
        #expect(backup.path.hasPrefix(fixture.installer.backupFolder.path))
    }

    @Test func disconnectRemovesOnlyTheEntry() async throws {
        let fixture = AgentsFixture()
        fixture.populate()
        let agents = AgentsModel(installer: fixture.installer, command: AgentsFixture.command)
        agents.disconnect(try #require(AgentCatalog.agent("claude-code")))
        #expect(agents.pending?.action == .uninstall)
        await agents.confirm()
        let after = try #require(fixture.text(".claude.json"))
        #expect(!after.contains("esclop"))
        #expect(after.contains("\"numStartups\": 12"), "the rest of the file stays")
        agents.disconnect(try #require(AgentCatalog.agent("codex")))
        #expect(agents.pending == nil, "nothing to remove, nothing to confirm")
    }

    @Test func aFileEditedDuringThePreviewIsNotOverwritten() async throws {
        let fixture = AgentsFixture()
        fixture.populate()
        let agents = AgentsModel(installer: fixture.installer, command: AgentsFixture.command)
        agents.connect(try #require(AgentCatalog.agent("codex")))
        fixture.write(".codex/config.toml", "model = \"o3\"\n")
        await agents.confirm()
        #expect(fixture.text(".codex/config.toml") == "model = \"o3\"\n")
        guard case let .failed(text)? = agents.outcomes["codex"] else { Issue.record("expected a refusal"); return }
        #expect(text.contains("changed since"))
    }

    @Test func unreadableConfigsAreNotPlanned() async throws {
        let fixture = AgentsFixture()
        fixture.populate()
        let agents = AgentsModel(installer: fixture.installer, command: AgentsFixture.command)
        agents.connect(try #require(AgentCatalog.agent("zed")))
        #expect(agents.pending == nil)
        guard case .failed? = agents.outcomes["zed"] else { Issue.record("expected the parse error"); return }
        #expect(fixture.text(".config/zed/settings.json") == "{ \"theme\": \n")
    }

    @Test func withoutACommandLineNothingIsPlanned() async throws {
        let fixture = AgentsFixture()
        let agents = AgentsModel(installer: fixture.installer, command: nil)
        agents.connect(try #require(AgentCatalog.agent("cursor")))
        #expect(agents.pending == nil)
        #expect(agents.snippets.isEmpty)
        await agents.test()
        #expect(agents.probe == .failed(AgentsModel.noCommand))
    }

    @Test func snippetsUseTheCommand() {
        let agents = AgentsModel(installer: AgentsFixture().installer, command: AgentsFixture.command)
        let byID = Dictionary(uniqueKeysWithValues: agents.snippets.map { ($0.id, $0.text) })
        #expect(byID["command"] == "\"/Applications/L'Esclop.app/Contents/MacOS/esclop\" mcp serve")
        #expect(byID["json"]?.contains("\"mcpServers\"") == true)
        #expect((try? JSONSerialization.jsonObject(with: Data((byID["json"] ?? "").utf8))) != nil, "the JSON snippet parses")
        #expect(byID["toml"]?.hasPrefix("[mcp_servers.esclop]") == true)
        #expect(byID["claude"]?.hasPrefix("claude mcp add --scope user esclop -- ") == true)
        #expect(agents.manualJSON?.contains("\"esclop\"") == true)
    }

    @Test func liveTestAgainstTheBuiltServer() async throws {
        guard let path = ProcessInfo.processInfo.environment["ESCLOP_TEST_BINARY"], FileManager.default.isExecutableFile(atPath: path) else {
            return // Scripts/test.sh sets it; a bare `swift test` skips the live test.
        }
        var environment = ProcessInfo.processInfo.environment
        environment["ESCLOP_NO_APP"] = "1"
        environment["ESCLOP_SUPPORT_DIR"] = AgentsFixture().temp.url.path
        let agents = AgentsModel(installer: AgentsFixture().installer, command: ServerCommand(command: path), probeEnvironment: environment)
        await agents.test()
        guard case let .passed(report) = agents.probe else { Issue.record("probe: \(agents.probe)"); return }
        #expect(report.serverName == "esclop-mcp")
        #expect(report.toolCount > 0)
    }

    @Test func agentRowsAreFoundAndLinked() {
        let settings = TestSettings()
        let model = SettingsViewModel(provider: RegistrySettingsProvider(store: settings.store), extraRows: SettingsPaneView.extraRows)
        model.query = "cursor"
        #expect(model.hits.first { $0.pane == .agents }?.id == "agent.cursor")
        #expect(model.link(to: "agent.cursor")?.absoluteString == "esclop://settings/agents/agent.cursor")
        model.query = "mcp test"
        #expect(model.hits.map(\.id).contains(AgentsTestSection.rowID))
    }
}
