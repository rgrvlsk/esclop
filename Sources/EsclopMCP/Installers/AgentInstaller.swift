// SPDX-License-Identifier: GPL-3.0-or-later
//
// Writes the esclop MCP server into AI agents' configs, reads it back to verify, and removes it.
// Each agent is a row of data: where its config lives, its format, where servers go and the shape
// of an entry. Editing splices text so the person's other servers, comments and formatting stay.
//
// Behavioural reference: Clop's MCP installer (which agents, which files, which entry shapes);
// this is an independent implementation.

import EsclopCore
import EsclopIPC
import Foundation

// MARK: - Model

public struct ServerCommand: Codable, Hashable, Sendable {
    public var command: String
    public var args: [String]

    public init(command: String, args: [String] = ["mcp", "serve"]) {
        self.command = command
        self.args = args
    }

    /// The running binary, symlinks resolved, so the entry survives a moved symlink.
    public static func current() -> ServerCommand {
        let invoked = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let real = invoked.resolvingSymlinksInPath()
        // A Homebrew Cellar path changes with every upgrade; the bin symlink does not.
        let stable = real.path.contains("/Cellar/") && !invoked.path.contains("/Cellar/") ? invoked : real
        return ServerCommand(command: stable.path)
    }

    /// For a person to paste: `/path/to/esclop mcp serve`. Quoted for the shell where needed:
    /// the app's own copy lives under `/Applications/L'Esclop.app`, whose apostrophe a shell
    /// would otherwise take as the start of a string.
    public var shellLine: String {
        ([command] + args).map(Self.shellQuoted).joined(separator: " ")
    }

    public static func shellQuoted(_ word: String) -> String {
        let safe = !word.isEmpty && word.allSatisfy { $0.isLetter || $0.isNumber || "-_./:=@%+,".contains($0) }
        return safe ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The `esclop` command line next to the running executable: inside the app bundle
    /// (`Contents/MacOS/esclop`, where the bundle script puts it) or in the same build folder in a
    /// checkout. Nil when there is none.
    public static func sibling(of executable: URL? = Bundle.main.executableURL) -> ServerCommand? {
        guard let executable else { return nil }
        let candidate = executable.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("esclop")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else { return nil }
        return ServerCommand(command: candidate.path)
    }
}

public struct AgentDefinition: Sendable, Identifiable {
    public enum Format: String, Codable, Sendable {
        case json, toml, yaml, manual
    }

    /// How an entry looks in this agent's config.
    public enum EntryStyle: Sendable {
        /// `{"command": ..., "args": [...]}`
        case standard
        /// `{"type": "stdio", "command": ..., "args": [...]}`
        case typedStdio
        /// GitHub Copilot CLI: `{"type": "local", "command": ..., "args": [...], "tools": ["*"]}`
        case copilot
        /// OpenCode: `{"type": "local", "command": [cmd, args...], "enabled": true}`
        case openCode
        /// Codex: `[mcp_servers.esclop]` with `command` and `args`.
        case codexTable
        /// Goose: `extensions.esclop` with `cmd`, `args`, `type: stdio`, `enabled: true`.
        case gooseExtension
        /// No file to edit: the person adds it in the app.
        case manual(String)
    }

    public let id: String
    public let name: String
    /// `~/...` paths, tried in order: the first that exists is edited, else the first is created.
    public let configPaths: [String]
    public let format: Format
    /// Keys from the root to the object that holds servers. A key may contain dots (Amp).
    public let container: [String]
    public let style: EntryStyle
    /// `~/...` paths whose presence means the agent is installed.
    public let homeEvidence: [String]
    /// App bundle names looked up in the Applications folders.
    public let apps: [String]
    /// Executables looked up in the usual bin folders.
    public let binaries: [String]
}

public enum AgentCatalog {
    public static let all: [AgentDefinition] = [
        AgentDefinition(id: "claude-code", name: "Claude Code", configPaths: ["~/.claude.json"], format: .json,
                        container: ["mcpServers"], style: .standard, homeEvidence: ["~/.claude"], apps: [], binaries: ["claude"]),
        AgentDefinition(id: "claude-desktop", name: "Claude Desktop", configPaths: ["~/Library/Application Support/Claude/claude_desktop_config.json"], format: .json,
                        container: ["mcpServers"], style: .standard, homeEvidence: [], apps: ["Claude.app"], binaries: []),
        AgentDefinition(id: "codex", name: "Codex CLI and ChatGPT desktop", configPaths: ["~/.codex/config.toml"], format: .toml,
                        container: ["mcp_servers"], style: .codexTable, homeEvidence: ["~/.codex"], apps: ["Codex.app", "ChatGPT.app"], binaries: ["codex"]),
        AgentDefinition(id: "cursor", name: "Cursor", configPaths: ["~/.cursor/mcp.json"], format: .json,
                        container: ["mcpServers"], style: .standard, homeEvidence: ["~/.cursor"], apps: ["Cursor.app"], binaries: ["cursor-agent"]),
        AgentDefinition(id: "windsurf", name: "Windsurf", configPaths: ["~/.config/devin/mcp_config.json", "~/.codeium/windsurf/mcp_config.json"], format: .json,
                        container: ["mcpServers"], style: .standard, homeEvidence: ["~/.codeium/windsurf", "~/.config/devin"], apps: ["Windsurf.app", "Devin.app"], binaries: ["devin"]),
        AgentDefinition(id: "zed", name: "Zed", configPaths: ["~/.config/zed/settings.json"], format: .json,
                        container: ["context_servers"], style: .standard, homeEvidence: ["~/.config/zed"], apps: ["Zed.app"], binaries: []),
        AgentDefinition(id: "gemini", name: "Gemini CLI", configPaths: ["~/.gemini/settings.json"], format: .json,
                        container: ["mcpServers"], style: .standard, homeEvidence: [], apps: [], binaries: ["gemini"]),
        AgentDefinition(id: "copilot", name: "GitHub Copilot CLI", configPaths: ["~/.copilot/mcp-config.json"], format: .json,
                        container: ["mcpServers"], style: .copilot, homeEvidence: ["~/.copilot"], apps: [], binaries: ["copilot"]),
        AgentDefinition(id: "opencode", name: "OpenCode", configPaths: ["~/.config/opencode/opencode.json", "~/.config/opencode/opencode.jsonc"], format: .json,
                        container: ["mcp"], style: .openCode, homeEvidence: ["~/.config/opencode", "~/.opencode"], apps: ["OpenCode.app"], binaries: ["opencode"]),
        AgentDefinition(id: "pi", name: "pi", configPaths: ["~/.pi/agent/mcp.json"], format: .json,
                        container: ["mcpServers"], style: .standard, homeEvidence: ["~/.pi"], apps: [], binaries: ["pi"]),
        AgentDefinition(id: "warp", name: "Warp", configPaths: [], format: .manual, container: [],
                        style: .manual("Warp keeps MCP servers in its own settings: open Warp → Settings → AI → MCP Servers → Add, and paste the JSON from `esclop mcp install warp`."),
                        homeEvidence: ["~/.warp"], apps: ["Warp.app"], binaries: []),
        AgentDefinition(id: "goose", name: "Goose", configPaths: ["~/.config/goose/config.yaml"], format: .yaml,
                        container: ["extensions"], style: .gooseExtension, homeEvidence: ["~/.config/goose"], apps: ["Goose.app"], binaries: ["goose"]),
        AgentDefinition(id: "vscode", name: "VS Code", configPaths: ["~/Library/Application Support/Code/User/mcp.json"], format: .json,
                        container: ["servers"], style: .typedStdio, homeEvidence: ["~/Library/Application Support/Code"], apps: ["Visual Studio Code.app"], binaries: []),
        AgentDefinition(id: "amp", name: "Amp", configPaths: ["~/.config/amp/settings.json"], format: .json,
                        container: ["amp.mcpServers"], style: .standard, homeEvidence: ["~/.config/amp", "~/.amp"], apps: [], binaries: ["amp"]),
        AgentDefinition(id: "droid", name: "Factory Droid", configPaths: ["~/.factory/mcp.json"], format: .json,
                        container: ["mcpServers"], style: .typedStdio, homeEvidence: ["~/.factory"], apps: [], binaries: ["droid"]),
        AgentDefinition(id: "qwen", name: "Qwen Code", configPaths: ["~/.qwen/settings.json"], format: .json,
                        container: ["mcpServers"], style: .standard, homeEvidence: ["~/.qwen"], apps: [], binaries: ["qwen"]),
    ]

    public static func agent(_ id: String) -> AgentDefinition? {
        let key = id.lowercased()
        let aliases = ["claude": "claude-code", "chatgpt": "codex", "codex-cli": "codex", "github-copilot": "copilot", "copilot-cli": "copilot", "gemini-cli": "gemini", "code": "vscode", "devin": "windsurf"]
        return all.first { $0.id == (aliases[key] ?? key) }
    }
}

public struct AgentStatus: Codable, Sendable, Hashable {
    public enum State: String, Codable, Sendable {
        /// The entry is there and runs this command.
        case installed
        /// The entry is there with a different command or arguments.
        case different
        case absent
        /// The config exists but cannot be read.
        case unreadable
        /// This agent is configured in its own UI.
        case manual
    }

    public var id: String
    public var name: String
    public var present: Bool
    public var configPath: String?
    public var format: String
    public var state: State
    public var command: ServerCommand?
    public var detail: String?
}

// MARK: - Installer

public struct AgentInstaller: Sendable {
    public var home: URL
    public var applicationFolders: [URL]
    public var binaryFolders: [URL]
    /// The key the entry is stored under in every config.
    public var entryName: String
    /// Where the last version of each config is kept before esclop changes it.
    public var backupFolder: URL

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationFolders: [URL]? = nil, binaryFolders: [URL]? = nil, entryName: String = "esclop", backupFolder: URL? = nil
    ) {
        self.home = home
        self.backupFolder = backupFolder ?? home.appendingPathComponent("Library/Application Support/esclop/agent-config-backups", isDirectory: true)
        self.applicationFolders = applicationFolders ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        self.binaryFolders = binaryFolders ?? [
            home.appendingPathComponent(".local/bin"), URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"), home.appendingPathComponent(".bun/bin"), home.appendingPathComponent(".npm-global/bin"),
        ]
        self.entryName = entryName
    }

    func expand(_ path: String) -> URL {
        path.hasPrefix("~/") ? home.appendingPathComponent(String(path.dropFirst(2))) : URL(fileURLWithPath: path)
    }

    public func isPresent(_ agent: AgentDefinition) -> Bool {
        let fm = FileManager.default
        if agent.configPaths.contains(where: { fm.fileExists(atPath: expand($0).path) }) { return true }
        if agent.homeEvidence.contains(where: { fm.fileExists(atPath: expand($0).path) }) { return true }
        if agent.apps.contains(where: { app in applicationFolders.contains { fm.fileExists(atPath: $0.appendingPathComponent(app).path) } }) { return true }
        return agent.binaries.contains { binary in binaryFolders.contains { fm.isExecutableFile(atPath: $0.appendingPathComponent(binary).path) } }
    }

    /// The config file to read and edit: the first that exists, else the first listed.
    public func configURL(_ agent: AgentDefinition) -> URL? {
        let candidates = agent.configPaths.map(expand)
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates.first
    }

    /// The JSON a person pastes into an agent that has no file to edit.
    public func manualSnippet(_ command: ServerCommand) -> String {
        OrderedJSON.object([(entryName, entry(.standard, command))]).render(indent: "", unit: "  ")
    }

    /// The whole config an agent would need if it had none: `{"mcpServers": {"esclop": ...}}`
    /// for most, the `[mcp_servers.esclop]` table for Codex. Nil for agents without a file.
    public func snippet(for agent: AgentDefinition, command: ServerCommand) -> String? {
        if case .manual = agent.style { return nil }
        return try? render(agent, into: "", command: command).trimmingCharacters(in: .newlines)
    }

    public func status(_ agent: AgentDefinition, expected: ServerCommand) -> AgentStatus {
        var status = AgentStatus(
            id: agent.id, name: agent.name, present: isPresent(agent), configPath: configURL(agent).map { shown($0) },
            format: agent.format.rawValue, state: .absent, command: nil, detail: nil
        )
        if case let .manual(how) = agent.style {
            status.state = .manual
            status.detail = how
            return status
        }
        do {
            guard let found = try installedCommand(agent) else { return status }
            status.command = found
            status.state = found == expected ? .installed : .different
            if status.state == .different { status.detail = "runs \(found.shellLine)" }
        } catch {
            status.state = .unreadable
            status.detail = "\(error)"
        }
        return status
    }

    /// Writes the entry, keeping everything else, and verifies by reading it back.
    @discardableResult
    public func install(_ agent: AgentDefinition, command: ServerCommand) throws -> AgentStatus {
        try apply(planInstall(agent, command: command))
    }

    /// Removes the entry. Returns the status after removal (absent).
    @discardableResult
    public func uninstall(_ agent: AgentDefinition) throws -> AgentStatus {
        guard let change = try planUninstall(agent) else {
            return status(agent, expected: ServerCommand(command: ""))
        }
        return try apply(change)
    }

    // MARK: Planning and applying

    /// The exact text an install would write, computed without writing anything. The app shows it
    /// before the person agrees; `apply` then writes these bytes or nothing.
    public func planInstall(_ agent: AgentDefinition, command: ServerCommand) throws -> ConfigChange {
        if case let .manual(how) = agent.style {
            throw ConfigLayoutError("\(agent.name) has no config file esclop can edit. \(how)\n\(manualSnippet(command))")
        }
        guard let url = configURL(agent) else { throw ConfigLayoutError("\(agent.name) has no config path") }
        let (target, before, exists) = try read(url)
        let after = try render(agent, into: before, command: command)
        // Checked before anything is written: the new text parses and holds the entry.
        guard try installedCommand(agent, in: after) == command else {
            throw ConfigLayoutError("The edited \(shown(url)) would not read back the esclop entry; nothing was written")
        }
        return ConfigChange(
            agentID: agent.id, agentName: agent.name, action: .install, file: target, shownPath: shown(url),
            fileExists: exists, before: before, after: after, command: command, backup: exists ? backupURL(agent, target) : nil, shownBackup: exists ? shown(backupURL(agent, target)) : nil
        )
    }

    /// The text an uninstall would leave, or nil when there is no entry to remove.
    public func planUninstall(_ agent: AgentDefinition) throws -> ConfigChange? {
        if case let .manual(how) = agent.style {
            throw ConfigLayoutError("\(agent.name) is configured in its own settings: remove esclop there. \(how)")
        }
        guard let url = configURL(agent), FileManager.default.fileExists(atPath: url.path) else { return nil }
        let (target, before, _) = try read(url)
        guard try installedCommand(agent, in: before) != nil else { return nil }
        let after = try remove(agent, from: before)
        guard try installedCommand(agent, in: after) == nil else {
            throw ConfigLayoutError("Removing esclop from \(shown(url)) did not take; nothing was written")
        }
        return ConfigChange(
            agentID: agent.id, agentName: agent.name, action: .uninstall, file: target, shownPath: shown(url),
            fileExists: true, before: before, after: after, command: nil, backup: backupURL(agent, target), shownBackup: shown(backupURL(agent, target))
        )
    }

    /// Writes a planned change: only to the agent's config file, after keeping its previous
    /// version in `backupFolder`. Refuses when the file changed since the plan, so what is written
    /// is what was shown. Verifies by reading the file back.
    @discardableResult
    public func apply(_ change: ConfigChange) throws -> AgentStatus {
        guard let agent = AgentCatalog.agent(change.agentID) ?? AgentCatalog.all.first(where: { $0.id == change.agentID }) else {
            throw ConfigLayoutError("Unknown agent \(change.agentID)")
        }
        let fm = FileManager.default
        let target = change.file
        let exists = fm.fileExists(atPath: target.path)
        let current = exists ? try String(contentsOf: target, encoding: .utf8) : ""
        guard exists == change.fileExists, current == change.before else {
            throw ConfigLayoutError("\(change.shownPath) changed since it was read; nothing was written. Look at the change again")
        }
        if change.after != change.before {
            if exists, let backup = change.backup {
                // The version before esclop touched it, one per agent, overwritten each time.
                try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(change.before.utf8).write(to: backup, options: .atomic)
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let permissions = exists ? (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions] : nil
            try change.after.write(to: target, atomically: true, encoding: .utf8)
            if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
        }
        switch change.action {
        case .install:
            let command = change.command ?? ServerCommand(command: "")
            let status = status(agent, expected: command)
            guard status.state == .installed else {
                throw ConfigLayoutError("Wrote \(change.shownPath) but reading it back found \(status.state.rawValue)\(status.detail.map { ": \($0)" } ?? "")")
            }
            return status
        case .uninstall:
            let after = status(agent, expected: ServerCommand(command: ""))
            guard after.state == .absent else { throw ConfigLayoutError("Removed esclop from \(change.shownPath) but it is still there") }
            return after
        }
    }

    /// The file behind a config path (a symlinked dotfile resolves to its target), its text, and
    /// whether it exists.
    private func read(_ url: URL) throws -> (URL, String, Bool) {
        let target = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: target.path) else { return (target, "", false) }
        return (target, try String(contentsOf: target, encoding: .utf8), true)
    }

    /// `~/.claude.json`: the path under this installer's home, as the docs name it.
    public func shown(_ url: URL) -> String {
        let home = self.home.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(home + "/") ? "~/" + path.dropFirst(home.count + 1) : path
    }

    func backupURL(_ agent: AgentDefinition, _ target: URL) -> URL {
        let ext = target.pathExtension.isEmpty ? "txt" : target.pathExtension
        return backupFolder.appendingPathComponent("\(agent.id).\(ext)")
    }

    // MARK: Reading

    public func installedCommand(_ agent: AgentDefinition) throws -> ServerCommand? {
        guard let url = configURL(agent), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try installedCommand(agent, in: try String(contentsOf: url.resolvingSymlinksInPath(), encoding: .utf8))
    }

    /// The entry in a config's text; throws when the text does not parse.
    func installedCommand(_ agent: AgentDefinition, in text: String) throws -> ServerCommand? {
        switch agent.format {
        case .json:
            let document = JSONCDocument(text)
            _ = try document.parse()
            guard let entry = try document.value(at: agent.container + [entryName]) else { return nil }
            if case .openCode = agent.style {
                let parts = entry["command"]?.arrayValue?.compactMap(\.stringValue) ?? []
                guard let first = parts.first else { return ServerCommand(command: "", args: []) }
                return ServerCommand(command: first, args: Array(parts.dropFirst()))
            }
            // Zed's older settings nest it: "command": {"path": ..., "args": [...]}.
            if let nested = entry["command"]?.objectValue {
                return ServerCommand(command: nested["path"]?.stringValue ?? "", args: nested["args"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            }
            return ServerCommand(command: entry["command"]?.stringValue ?? "", args: entry["args"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        case .toml:
            guard let entries = try TOMLTableEditor(text, table: agent.container + [entryName]).entries() else { return nil }
            return ServerCommand(
                command: entries["command"].flatMap { TOMLTableEditor.strings($0).first } ?? "",
                args: entries["args"].map(TOMLTableEditor.strings) ?? []
            )
        case .yaml:
            guard let entries = try YAMLMappingEditor(text, parent: agent.container.first ?? "", child: entryName).entries() else { return nil }
            return ServerCommand(command: entries["cmd"]?.first ?? "", args: entries["args"] ?? [])
        case .manual:
            return nil
        }
    }

    // MARK: Writing

    func entry(_ style: AgentDefinition.EntryStyle, _ command: ServerCommand) -> OrderedJSON {
        let args = OrderedJSON.array(command.args.map(OrderedJSON.string))
        switch style {
        case .typedStdio:
            return .object([("type", .string("stdio")), ("command", .string(command.command)), ("args", args)])
        case .copilot:
            return .object([("type", .string("local")), ("command", .string(command.command)), ("args", args), ("tools", .array([.string("*")]))])
        case .openCode:
            return .object([("type", .string("local")), ("command", .array(([command.command] + command.args).map(OrderedJSON.string))), ("enabled", .bool(true))])
        default:
            return .object([("command", .string(command.command)), ("args", args)])
        }
    }

    func render(_ agent: AgentDefinition, into text: String, command: ServerCommand) throws -> String {
        switch agent.format {
        case .json:
            var document = JSONCDocument(text)
            try document.set(agent.container + [entryName], to: entry(agent.style, command))
            return document.string
        case .toml:
            var editor = TOMLTableEditor(text, table: agent.container + [entryName])
            try editor.set([
                ("command", TOMLTableEditor.quote(command.command)),
                ("args", "[" + command.args.map(TOMLTableEditor.quote).joined(separator: ", ") + "]"),
            ])
            return editor.text
        case .yaml:
            var editor = YAMLMappingEditor(text, parent: agent.container.first ?? "extensions", child: entryName)
            try editor.set([
                "\(entryName):",
                "  enabled: true",
                "  type: stdio",
                "  name: \(entryName)",
                "  description: Optimise, convert and crop images, videos, PDFs and audio",
                "  cmd: \(YAMLMappingEditor.quote(command.command))",
                "  args:",
            ] + command.args.map { "  - \(YAMLMappingEditor.quote($0))" } + [
                "  envs: {}",
                "  timeout: 300",
            ])
            return editor.text
        case .manual:
            return text
        }
    }

    func remove(_ agent: AgentDefinition, from text: String) throws -> String {
        switch agent.format {
        case .json:
            var document = JSONCDocument(text)
            try document.remove(agent.container + [entryName])
            return document.string
        case .toml:
            var editor = TOMLTableEditor(text, table: agent.container + [entryName])
            try editor.remove()
            return editor.text
        case .yaml:
            var editor = YAMLMappingEditor(text, parent: agent.container.first ?? "extensions", child: entryName)
            try editor.remove()
            return editor.text
        case .manual:
            return text
        }
    }
}
