// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Agents and MCP pane's data: which agents are on this Mac and whether they run L'Esclop's
// MCP server, the planned change to an agent's config while the person looks at it, and the
// live server test. Installing goes through `AgentInstaller`, the code behind
// `esclop mcp install`, in two steps: plan (shown as a diff) and apply (writes those bytes, after
// a backup, or nothing).

import EsclopCore
import EsclopMCP
import Foundation
import Observation

@MainActor @Observable
public final class AgentsModel {
    public struct Row: Identifiable, Equatable, Sendable {
        public var agent: AgentDefinition
        public var status: AgentStatus
        public var id: String { agent.id }

        public static func == (lhs: Row, rhs: Row) -> Bool { lhs.status == rhs.status }
    }

    public enum Outcome: Equatable {
        case done(String)
        case failed(String)
    }

    public enum Probe: Equatable {
        case idle
        case running
        case passed(MCPProbeReport)
        case failed(String)
    }

    public private(set) var rows: [Row] = []
    public private(set) var loaded = false
    /// The change shown for confirmation.
    public var pending: ConfigChange?
    /// The last outcome per agent, shown under its row.
    public private(set) var outcomes: [String: Outcome] = [:]
    public internal(set) var probe: Probe = .idle

    /// What agents are told to run; nil when no `esclop` command line was found.
    public let command: ServerCommand?
    @ObservationIgnored let installer: AgentInstaller
    @ObservationIgnored let probeEnvironment: [String: String]?

    public init(installer: AgentInstaller = AgentInstaller(), command: ServerCommand? = AgentsModel.defaultCommand(), probeEnvironment: [String: String]? = nil) {
        self.installer = installer
        self.command = command
        self.probeEnvironment = probeEnvironment
    }

    /// The command line inside the app bundle (or next to the app in a build folder), else one
    /// installed in the usual bin folders.
    public nonisolated static func defaultCommand() -> ServerCommand? {
        if let sibling = ServerCommand.sibling() { return sibling }
        let folders = AgentInstaller().binaryFolders
        return folders.map { $0.appendingPathComponent("esclop") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
            .map { ServerCommand(command: $0.path) }
    }

    // MARK: Status

    public var found: [Row] { rows.filter(\.status.present) }
    public var notFound: [Row] { rows.filter { !$0.status.present } }

    /// Reads every agent's config off the main thread: some (Claude Code's) are megabytes.
    public func refresh() async {
        let installer = installer
        let expected = command ?? ServerCommand(command: "")
        let rows = await Task.detached(priority: .userInitiated) {
            AgentCatalog.all.map { Row(agent: $0, status: installer.status($0, expected: expected)) }
        }.value
        self.rows = rows
        loaded = true
    }

    // MARK: Install and uninstall

    /// Plans connecting (or reconnecting) an agent and shows the change; writes nothing.
    public func connect(_ agent: AgentDefinition) {
        guard let command else {
            outcomes[agent.id] = .failed(Self.noCommand)
            return
        }
        do {
            pending = try installer.planInstall(agent, command: command)
            outcomes[agent.id] = nil
        } catch {
            outcomes[agent.id] = .failed(Self.words(error))
        }
    }

    public func disconnect(_ agent: AgentDefinition) {
        do {
            if let change = try installer.planUninstall(agent) {
                pending = change
                outcomes[agent.id] = nil
            } else {
                outcomes[agent.id] = .done("L'Esclop was not in \(agent.name)'s config.")
            }
        } catch {
            outcomes[agent.id] = .failed(Self.words(error))
        }
    }

    /// Writes the change the person saw, then reads every status again.
    public func confirm() async {
        guard let change = pending else { return }
        pending = nil
        do {
            try installer.apply(change)
            switch change.action {
            case .install:
                outcomes[change.agentID] = .done("Connected. Restart \(change.agentName), or start a new session, to load L'Esclop.")
            case .uninstall:
                outcomes[change.agentID] = .done("Disconnected. \(change.agentName) stops offering L'Esclop after a restart.")
            }
        } catch {
            outcomes[change.agentID] = .failed(Self.words(error))
        }
        await refresh()
    }

    public func cancel() {
        pending = nil
    }

    // MARK: Test

    /// Starts the server as agents do and asks for its tools.
    public func test() async {
        guard let command else {
            probe = .failed(Self.noCommand)
            return
        }
        probe = .running
        do {
            probe = .passed(try await MCPProbe.run(command, environment: probeEnvironment))
        } catch {
            probe = .failed(Self.words(error))
        }
    }

    // MARK: Setting up by hand

    public struct Snippet: Identifiable, Equatable {
        public var id: String
        public var title: String
        public var text: String
    }

    public var snippets: [Snippet] {
        guard let command else { return [] }
        var list = [Snippet(id: "command", title: "Command", text: command.shellLine)]
        if let agent = AgentCatalog.agent("claude-desktop"), let json = installer.snippet(for: agent, command: command) {
            list.append(Snippet(id: "json", title: "JSON, for most agents (mcpServers)", text: json))
        }
        if let agent = AgentCatalog.agent("codex"), let toml = installer.snippet(for: agent, command: command) {
            list.append(Snippet(id: "toml", title: "TOML, for Codex", text: toml))
        }
        list.append(Snippet(id: "claude", title: "Claude Code, in a terminal", text: "claude mcp add --scope user esclop -- \(command.shellLine)"))
        return list
    }

    /// What a person pastes into an agent that keeps servers in its own settings (Warp).
    public var manualJSON: String? {
        command.map(installer.manualSnippet)
    }

    static let noCommand = "The esclop command line was not found next to L'Esclop or in the usual bin folders. Reinstall L'Esclop, or build it with swift build --product esclop."

    static func words(_ error: any Error) -> String {
        if let error = error as? EsclopError { return error.description }
        return String(describing: error)
    }
}
