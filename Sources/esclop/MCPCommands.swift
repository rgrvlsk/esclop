// SPDX-License-Identifier: GPL-3.0-or-later
//
// esclop mcp serve | install | uninstall | status

import ArgumentParser
import EsclopCore
import EsclopIPC
import EsclopMCP
import Foundation

struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "The MCP server that lets AI agents use L'Esclop, and its installers.",
        subcommands: [Serve.self, Install.self, Uninstall.self, Status.self],
        defaultSubcommand: Status.self
    )

    struct Serve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Speak MCP over stdin and stdout (agents run this).")

        @Flag(name: .customLong("in-process"), help: "Do the work here even when the L'Esclop app is running.")
        var inProcess = false

        func run() async throws {
            let environment = ProcessInfo.processInfo.environment
            // The origin is fixed here, not taken from the environment, so a client cannot drop it.
            let service = EsclopService(Integrations.context(origin: .mcp, inProcess: inProcess))
            let timeout = environment["ESCLOP_MCP_ELICIT_TIMEOUT"].flatMap(TimeInterval.init) ?? 120
            try await EsclopMCPServer(service: service, elicitationTimeout: timeout).serveStdio()
        }
    }

    struct AgentSelection: ParsableArguments {
        @Argument(help: "Agents: \(AgentCatalog.all.map(\.id).joined(separator: ", ")).")
        var agents: [String] = []

        @Flag(help: "Every agent found on this Mac.")
        var all = false

        func validate() throws {
            guard all != !agents.isEmpty else { throw ValidationError("Name agents or pass --all.") }
            for id in agents where AgentCatalog.agent(id) == nil {
                throw ValidationError("Unknown agent \(id). Known: \(AgentCatalog.all.map(\.id).joined(separator: ", ")).")
            }
        }

        func resolve(_ installer: AgentInstaller) -> [AgentDefinition] {
            all ? AgentCatalog.all.filter(installer.isPresent) : agents.compactMap(AgentCatalog.agent)
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add L'Esclop to agents' MCP configs, keeping their other servers, and verify it.",
            discussion: "Edits each agent's config file in place (comments and formatting are kept). Warp has no file: it prints the JSON to paste."
        )

        @OptionGroup var selection: AgentSelection
        @Option(help: "The esclop binary agents should run. Default: this one.")
        var command: String?
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            let installer = AgentInstaller()
            let server = try serverCommand(command)
            var results: [AgentStatus] = []
            var failed = false
            for agent in selection.resolve(installer) {
                do {
                    if case .manual = agent.style, selection.all { continue }
                    results.append(try installer.install(agent, command: server))
                    if !global.json { print("\(global.terminal.green("✓")) \(agent.name): \(installer.configURL(agent).map(installer.shown) ?? "")") }
                } catch {
                    failed = true
                    var status = installer.status(agent, expected: server)
                    status.detail = "\(error)"
                    results.append(status)
                    if !global.json { print("\(global.terminal.red("✗")) \(agent.name): \(error)") }
                }
            }
            if global.json { Output.json(results) }
            else if results.isEmpty { print("No agents found. Name one: esclop mcp install claude-code") }
            else { print(global.terminal.dim("Restart the agents (or start a new session) to load esclop.")) }
            if failed { throw ExitCode(1) }
        }
    }

    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove esclop from agents' MCP configs.")

        @OptionGroup var selection: AgentSelection
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            let installer = AgentInstaller()
            var results: [AgentStatus] = []
            var failed = false
            for agent in selection.all ? AgentCatalog.all : selection.resolve(installer) {
                if selection.all, installer.status(agent, expected: ServerCommand(command: "")).state == .absent { continue }
                if case .manual = agent.style, selection.all { continue }
                do {
                    results.append(try installer.uninstall(agent))
                    if !global.json { print("\(global.terminal.green("✓")) removed from \(agent.name)") }
                } catch {
                    failed = true
                    if !global.json { print("\(global.terminal.red("✗")) \(agent.name): \(error)") }
                }
            }
            if global.json { Output.json(results) } else if results.isEmpty, !failed { print("esclop was not installed in any agent.") }
            if failed { throw ExitCode(1) }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Which agents are on this Mac and which run esclop.")

        @Option(help: "The esclop binary agents should run. Default: this one.")
        var command: String?
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            let installer = AgentInstaller()
            let server = try serverCommand(command)
            let statuses = AgentCatalog.all.map { installer.status($0, expected: server) }
            if global.json { Output.json(statuses); return }
            let t = global.terminal
            for status in statuses {
                let state: String
                switch status.state {
                case .installed: state = t.green("installed")
                case .different: state = t.yellow("installed, other command")
                case .absent: state = status.present ? "not installed" : t.dim("not found")
                case .unreadable: state = t.red("config unreadable")
                case .manual: state = status.present ? "add in its settings" : t.dim("not found")
                }
                print("\(status.name.padding(toLength: 30, withPad: " ", startingAt: 0)) \(state)\(status.configPath.map { "  " + t.dim($0) } ?? "")")
            }
            print("")
            print("Server command: \(server.shellLine)")
            print("Claude Code alternative: claude mcp add --scope user esclop -- \(server.shellLine)")
        }
    }
}

func serverCommand(_ override: String?) throws -> ServerCommand {
    guard let override else { return ServerCommand.current() }
    let url = try PathInput.url(override)
    guard FileManager.default.isExecutableFile(atPath: url.path) else {
        throw ValidationError("\(override) is not an executable file.")
    }
    return ServerCommand(command: url.path)
}
