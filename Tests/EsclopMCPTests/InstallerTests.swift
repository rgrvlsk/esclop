// SPDX-License-Identifier: GPL-3.0-or-later

import EsclopCore
import EsclopIPC
@testable import EsclopMCP
import Foundation
import Testing

/// Every agent, against configs in a temporary home folder.
@Suite struct Installers {
    static let editable = AgentCatalog.all.filter { if case .manual = $0.style { return false }; return true }
    static let command = ServerCommand(command: "/Applications/esclop.app/Contents/MacOS/esclop")

    func installer(_ temp: TempDir) -> AgentInstaller {
        AgentInstaller(home: temp.url, applicationFolders: [temp.url.appendingPathComponent("Applications")], binaryFolders: [temp.url.appendingPathComponent("bin")])
    }

    func relative(_ path: String) -> String { String(path.dropFirst(2)) }

    @Test(arguments: editable.map(\.id))
    func freshInstallCreatesTheConfig(_ id: String) throws {
        let temp = TempDir()
        let agent = try #require(AgentCatalog.agent(id))
        let installer = installer(temp)
        let status = try installer.install(agent, command: Self.command)
        #expect(status.state == .installed)
        #expect(status.command == Self.command)
        let url = try #require(installer.configURL(agent))
        let first = try String(contentsOf: url, encoding: .utf8)
        // Idempotent: the second install writes the same bytes.
        try installer.install(agent, command: Self.command)
        #expect(try String(contentsOf: url, encoding: .utf8) == first)
        if agent.format == .json {
            #expect((try? JSONSerialization.jsonObject(with: Data(first.utf8))) != nil, "plain JSON stays valid JSON:\n\(first)")
        }
        try installer.uninstall(agent)
        #expect(installer.status(agent, expected: Self.command).state == .absent)
    }

    @Test(arguments: editable.map(\.id))
    func otherEntriesSurviveAndUninstallRestoresTheFile(_ id: String) throws {
        let temp = TempDir()
        let agent = try #require(AgentCatalog.agent(id))
        let path = relative(agent.configPaths[0])
        let original = Self.fixture(for: agent)
        temp.write(path, original)
        let installer = installer(temp)
        try installer.install(agent, command: Self.command)
        let installed = temp.read(path)
        for marker in ["other-server", "keep-me"] where original.contains(marker) {
            #expect(installed.contains(marker), "\(marker) survived in\n\(installed)")
        }
        #expect(installer.status(agent, expected: Self.command).state == .installed)
        try installer.uninstall(agent)
        #expect(temp.read(path) == original, "install then uninstall gives back the file:\n\(temp.read(path))")
    }

    @Test(arguments: editable.map(\.id))
    func aDifferentCommandIsReportedAndReplaced(_ id: String) throws {
        let temp = TempDir()
        let agent = try #require(AgentCatalog.agent(id))
        let installer = installer(temp)
        let old = ServerCommand(command: "/old/esclop", args: ["mcp", "serve"])
        try installer.install(agent, command: old)
        let status = installer.status(agent, expected: Self.command)
        #expect(status.state == .different)
        #expect(status.command == old)
        try installer.install(agent, command: Self.command)
        #expect(installer.status(agent, expected: Self.command).state == .installed)
    }

    static func fixture(for agent: AgentDefinition) -> String {
        switch agent.format {
        case .toml:
            return """
            # keep-me: model settings
            model = "o4"

            [mcp_servers.other-server]
            command = "npx"
            args = ["-y", "other"]

            [profiles.fast]
            model = "mini"

            """
        case .yaml:
            return """
            # keep-me
            GOOSE_PROVIDER: anthropic
            extensions:
              other-server:
                enabled: true
                type: stdio
                cmd: npx
                args:
                - other
            GOOSE_MODE: smart

            """
        case .json:
            let container = agent.container[0]
            return """
            {
              // keep-me: a comment
              "theme": "dark",
              "\(container)": {
                "other-server": {
                  "command": "npx",
                  "args": ["-y", "other"]
                }
              }
            }

            """
        case .manual:
            return ""
        }
    }

    // MARK: Shapes

    func installedEntry(_ id: String) throws -> JSONValue? {
        let temp = TempDir()
        let agent = try #require(AgentCatalog.agent(id))
        let installer = installer(temp)
        try installer.install(agent, command: Self.command)
        return try JSONCDocument(temp.read(relative(agent.configPaths[0]))).value(at: agent.container + ["esclop"])
    }

    @Test func previewIsExactlyWhatIsWritten() throws {
        let temp = TempDir()
        let installer = installer(temp)
        let agent = try #require(AgentCatalog.agent("cursor"))
        let config = temp.url.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "{\n  \"mcpServers\": {\n    \"other\": { \"command\": \"x\" }\n  }\n}\n"
        try original.write(to: config, atomically: true, encoding: .utf8)
        let change = try installer.planInstall(agent, command: Self.command)
        #expect(try String(contentsOf: config, encoding: .utf8) == original, "planning writes nothing")
        #expect(change.before == original)
        #expect(change.shownPath == "~/.cursor/mcp.json")
        let diff = change.diff()
        #expect(diff.contains { $0.kind == .added && $0.text.contains("\"esclop\"") })
        #expect(change.after.contains("\"other\": { \"command\": \"x\" }"), "other servers stay")
        try installer.apply(change)
        #expect(try String(contentsOf: config, encoding: .utf8) == change.after)
        let backup = try #require(change.backup)
        #expect(try String(contentsOf: backup, encoding: .utf8) == original, "the previous version is kept")
    }

    @Test func aFileChangedAfterThePreviewIsLeftAlone() throws {
        let temp = TempDir()
        let installer = installer(temp)
        let agent = try #require(AgentCatalog.agent("gemini"))
        let change = try installer.planInstall(agent, command: Self.command)
        #expect(!change.fileExists)
        let config = temp.url.appendingPathComponent(".gemini/settings.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"theme\": \"dark\"}\n".write(to: config, atomically: true, encoding: .utf8)
        #expect(throws: ConfigLayoutError.self) { try installer.apply(change) }
        #expect(try String(contentsOf: config, encoding: .utf8) == "{\"theme\": \"dark\"}\n")
    }

    @Test func aChangeAimedAtAnotherFileWritesNothing() throws {
        let temp = TempDir()
        let installer = installer(temp)
        let agent = try #require(AgentCatalog.agent("cursor"))
        let planned = try installer.planInstall(agent, command: Self.command)
        let elsewhere = temp.url.appendingPathComponent("Documents/notes.json")
        var redirected = planned
        redirected.file = elsewhere
        redirected.shownPath = "~/Documents/notes.json"
        #expect(throws: ConfigLayoutError.self) { try installer.apply(redirected) }
        #expect(!FileManager.default.fileExists(atPath: elsewhere.path))
        #expect(!FileManager.default.fileExists(atPath: planned.file.path), "the real config is not written either")

        // An existing config, with its backup pointed somewhere else.
        try FileManager.default.createDirectory(at: planned.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}\n".write(to: planned.file, atomically: true, encoding: .utf8)
        var misplaced = try installer.planInstall(agent, command: Self.command)
        let strayBackup = temp.url.appendingPathComponent("Desktop/cursor.json")
        misplaced.backup = strayBackup
        #expect(throws: ConfigLayoutError.self) { try installer.apply(misplaced) }
        #expect(!FileManager.default.fileExists(atPath: strayBackup.path))
        #expect(try String(contentsOf: planned.file, encoding: .utf8) == "{}\n")
        // The unaltered plan still applies.
        try installer.apply(try installer.planInstall(agent, command: Self.command))
        #expect(installer.status(agent, expected: Self.command).state == .installed)
    }

    @Test(arguments: editable.map(\.id))
    func writesOnlyTheConfigAndItsBackup(_ id: String) throws {
        let temp = TempDir()
        let installer = installer(temp)
        let agent = try #require(AgentCatalog.agent(id))
        try installer.install(agent, command: Self.command)
        try installer.install(agent, command: ServerCommand(command: "/usr/local/bin/esclop"))
        try installer.uninstall(agent)
        let config = try #require(installer.configURL(agent)).standardizedFileURL.path
        let written = try FileManager.default.subpathsOfDirectory(atPath: temp.url.path)
            .map { temp.url.appendingPathComponent($0) }
            .filter { !$0.hasDirectoryPath && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map(\.standardizedFileURL.path)
        for path in written {
            #expect(path == config || path.hasPrefix(installer.backupFolder.standardizedFileURL.path + "/"), "\(id) wrote \(path)")
        }
    }

    @Test func uninstallPlanIsNilWhenAbsent() throws {
        let temp = TempDir()
        let agent = try #require(AgentCatalog.agent("claude-code"))
        #expect(try installer(temp).planUninstall(agent) == nil)
    }

    @Test func diffShowsOnlyTheSpliceWithContext() {
        let before = (1 ... 40).map { "line \($0)" }.joined(separator: "\n") + "\n"
        var lines = (1 ... 40).map { "line \($0)" }
        lines.insert("new", at: 20)
        let change = ConfigChange(
            agentID: "x", agentName: "X", action: .install, file: URL(fileURLWithPath: "/tmp/x"), shownPath: "~/x",
            fileExists: true, before: before, after: lines.joined(separator: "\n") + "\n", command: nil, backup: nil, shownBackup: nil
        )
        let diff = change.diff(context: 2)
        #expect(diff.map(\.kind) == [.skipped, .same, .same, .added, .same, .same, .skipped])
        #expect(diff.first?.skipped == 18)
        #expect(diff.last?.skipped == 18)
        #expect(diff[3].text == "new" && diff[3].number == 21)
    }

    @Test func shellLinesSurviveApostrophesAndSpaces() {
        #expect(ServerCommand(command: "/usr/local/bin/esclop").shellLine == "/usr/local/bin/esclop mcp serve")
        #expect(ServerCommand(command: "/Applications/L'Esclop.app/Contents/MacOS/esclop").shellLine == "\"/Applications/L'Esclop.app/Contents/MacOS/esclop\" mcp serve")
        #expect(ServerCommand(command: "/Volumes/My Disk/esclop").shellLine == "\"/Volumes/My Disk/esclop\" mcp serve")
    }

    /// The shell reads every quoted word back exactly as it was.
    @Test func quotedWordsSurviveTheShell() throws {
        for word in ["/Applications/L'Esclop.app/esclop", "My Disk", "it's \"$HOME\"", "a`b`", "back\\slash", "bang!", "plain"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf %s " + ServerCommand.shellQuoted(word)]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            #expect(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == word)
        }
    }

    @Test func entryShapes() throws {
        #expect(try installedEntry("claude-code") == ["command": .string(Self.command.command), "args": ["mcp", "serve"]])
        #expect(try installedEntry("copilot") == ["type": "local", "command": .string(Self.command.command), "args": ["mcp", "serve"], "tools": ["*"]])
        #expect(try installedEntry("opencode") == ["type": "local", "command": [.string(Self.command.command), "mcp", "serve"], "enabled": true])
        #expect(try installedEntry("vscode") == ["type": "stdio", "command": .string(Self.command.command), "args": ["mcp", "serve"]])
        #expect(try installedEntry("zed")?["command"] == .string(Self.command.command))
    }

    @Test func ampUsesADottedTopLevelKey() throws {
        let temp = TempDir()
        let agent = try #require(AgentCatalog.agent("amp"))
        try installer(temp).install(agent, command: Self.command)
        let json = try JSONSerialization.jsonObject(with: Data(temp.read(".config/amp/settings.json").utf8)) as? [String: Any]
        #expect((json?["amp.mcpServers"] as? [String: Any])?["esclop"] != nil)
    }

    @Test func codexTableLooksRight() throws {
        let temp = TempDir()
        try installer(temp).install(try #require(AgentCatalog.agent("codex")), command: ServerCommand(command: "/Apps/My \"esclop\".app/esclop"))
        #expect(temp.read(".codex/config.toml") == """
        [mcp_servers.esclop]
        command = "/Apps/My \\"esclop\\".app/esclop"
        args = ["mcp", "serve"]

        """)
    }

    @Test func codexSubtablesSurviveReinstallAndGoOnUninstall() throws {
        let temp = TempDir()
        temp.write(".codex/config.toml", """
        [mcp_servers.esclop]
        command = "/old"

        [mcp_servers.esclop.env]
        A = "1"

        # keep-me: docs server
        [mcp_servers.other]
        x = 1

        """)
        let installer = installer(temp)
        let codex = try #require(AgentCatalog.agent("codex"))
        try installer.install(codex, command: Self.command)
        var text = temp.read(".codex/config.toml")
        #expect(!text.contains("/old"))
        #expect(text.contains("[mcp_servers.esclop.env]\nA = \"1\""))
        #expect(text.contains("\n\n# keep-me: docs server\n[mcp_servers.other]"))
        try installer.uninstall(codex)
        text = temp.read(".codex/config.toml")
        #expect(!text.contains("esclop"))
        #expect(text == "# keep-me: docs server\n[mcp_servers.other]\nx = 1\n")
    }

    @Test func commentsBeforeTheNextEntryStay() throws {
        let temp = TempDir()
        let original = """
        extensions:
          other-server:
            cmd: x
        # keep-me: global settings
        GOOSE_MODE: auto

        """
        temp.write(".config/goose/config.yaml", original)
        let installer = installer(temp)
        let goose = try #require(AgentCatalog.agent("goose"))
        try installer.install(goose, command: Self.command)
        #expect(temp.read(".config/goose/config.yaml").contains("    - \"serve\"\n    envs: {}\n    timeout: 300\n# keep-me: global settings\n"))
        try installer.uninstall(goose)
        #expect(temp.read(".config/goose/config.yaml") == original)
    }

    @Test func jsonCommentsNextToTheEntryStay() throws {
        let temp = TempDir()
        let installer = installer(temp)
        let cursor = try #require(AgentCatalog.agent("cursor"))
        temp.write(".cursor/mcp.json", "{\"mcpServers\":{ // mine\n\"esclop\":{\"command\":\"c\"}}}\n")
        try installer.uninstall(cursor)
        let afterOnly = temp.read(".cursor/mcp.json")
        #expect(afterOnly.contains("// mine"))
        #expect((try? JSONCDocument(afterOnly).parse()) != nil, "still parses: \(afterOnly)")

        temp.write(".cursor/mcp.json", "{\n  \"mcpServers\": {\n    \"other\": {\"command\": \"x\"}, // keep me\n    \"esclop\": {\"command\": \"c\"}\n  }\n}\n")
        try installer.uninstall(cursor)
        #expect(temp.read(".cursor/mcp.json") == "{\n  \"mcpServers\": {\n    \"other\": {\"command\": \"x\"} // keep me\n  }\n}\n")
    }

    @Test func lineEndingsAndUntouchedFilesStay() throws {
        let temp = TempDir()
        let installer = installer(temp)
        let codex = try #require(AgentCatalog.agent("codex"))
        let crlf = "model = \"o4\"\r\n[x]\r\ny = 1"
        temp.write(".codex/config.toml", crlf)
        try installer.uninstall(codex)
        #expect(temp.read(".codex/config.toml") == crlf, "uninstall without an entry writes nothing")
        try installer.install(codex, command: Self.command)
        let installed = temp.read(".codex/config.toml")
        #expect(installed.hasPrefix("model = \"o4\"\r\n[x]\r\ny = 1\r\n\r\n[mcp_servers.esclop]\r\n"))
        #expect(!installed.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        // The version before the change is kept.
        let backup = temp.url.appendingPathComponent("Library/Application Support/esclop/agent-config-backups/codex.toml")
        #expect((try? String(contentsOf: backup, encoding: .utf8)) == crlf)
    }

    @Test func gooseEntryLooksRight() throws {
        let temp = TempDir()
        try installer(temp).install(try #require(AgentCatalog.agent("goose")), command: Self.command)
        let text = temp.read(".config/goose/config.yaml")
        #expect(text.hasPrefix("extensions:\n  esclop:\n    enabled: true\n    type: stdio\n"))
        #expect(text.contains("    cmd: \"\(Self.command.command)\"\n    args:\n    - \"mcp\"\n    - \"serve\"\n"))
    }

    @Test func zedKeepsCommentsAndTrailingCommas() throws {
        let temp = TempDir()
        let original = """
        // Zed settings
        {
          "ui_font_size": 16, // keep-me
          /* block */
          "context_servers": {
            "other-server": { "command": "x", },
          },
        }

        """
        temp.write(".config/zed/settings.json", original)
        let installer = installer(temp)
        let zed = try #require(AgentCatalog.agent("zed"))
        try installer.install(zed, command: Self.command)
        let text = temp.read(".config/zed/settings.json")
        #expect(text.contains("// Zed settings") && text.contains("/* block */") && text.contains("// keep-me"))
        #expect(installer.status(zed, expected: Self.command).state == .installed)
        try installer.uninstall(zed)
        #expect(!temp.read(".config/zed/settings.json").contains("esclop"))
        #expect(temp.read(".config/zed/settings.json").contains("other-server"))
    }

    @Test func openCodeFallsBackToJSONC() throws {
        let temp = TempDir()
        temp.write(".config/opencode/opencode.jsonc", "{\n  // keep-me\n  \"theme\": \"x\"\n}\n")
        let installer = installer(temp)
        let agent = try #require(AgentCatalog.agent("opencode"))
        #expect(installer.configURL(agent)?.lastPathComponent == "opencode.jsonc")
        try installer.install(agent, command: Self.command)
        #expect(temp.read(".config/opencode/opencode.jsonc").contains("// keep-me"))
        #expect(!FileManager.default.fileExists(atPath: temp.url.appendingPathComponent(".config/opencode/opencode.json").path))
    }

    // MARK: Refusals and edge cases

    @Test func inlineTOMLIsRefused() throws {
        let temp = TempDir()
        let codex = try #require(AgentCatalog.agent("codex"))
        temp.write(".codex/config.toml", "mcp_servers = { other = { command = \"x\" } }\n")
        #expect(throws: (any Error).self) { try installer(temp).install(codex, command: Self.command) }
        temp.write(".codex/config.toml", "[mcp_servers]\nesclop = { command = \"x\" }\n")
        #expect(throws: (any Error).self) { try installer(temp).install(codex, command: Self.command) }
        #expect(temp.read(".codex/config.toml") == "[mcp_servers]\nesclop = { command = \"x\" }\n", "nothing written")
    }

    @Test func flowYAMLIsRefused() throws {
        let temp = TempDir()
        temp.write(".config/goose/config.yaml", "extensions: {other: {cmd: x}}\n")
        #expect(throws: (any Error).self) { try installer(temp).install(try #require(AgentCatalog.agent("goose")), command: Self.command) }
    }

    @Test func emptyFlowYAMLIsExpanded() throws {
        let temp = TempDir()
        temp.write(".config/goose/config.yaml", "extensions: {}\nGOOSE_MODE: auto\n")
        let installer = installer(temp)
        let goose = try #require(AgentCatalog.agent("goose"))
        try installer.install(goose, command: Self.command)
        #expect(installer.status(goose, expected: Self.command).state == .installed)
        #expect(temp.read(".config/goose/config.yaml").contains("GOOSE_MODE: auto"))
    }

    @Test func brokenJSONIsReportedNotOverwritten() throws {
        let temp = TempDir()
        temp.write(".cursor/mcp.json", "{ \"mcpServers\": { ")
        let installer = installer(temp)
        let cursor = try #require(AgentCatalog.agent("cursor"))
        #expect(installer.status(cursor, expected: Self.command).state == .unreadable)
        #expect(throws: (any Error).self) { try installer.install(cursor, command: Self.command) }
        #expect(temp.read(".cursor/mcp.json") == "{ \"mcpServers\": { ")
    }

    @Test func symlinkedDotfilesAndPermissionsSurvive() throws {
        let temp = TempDir()
        let real = temp.write("dotfiles/claude.json", "{\n  \"keep-me\": 1\n}\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        let link = temp.url.appendingPathComponent(".claude.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try installer(temp).install(try #require(AgentCatalog.agent("claude-code")), command: Self.command)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil, "still a symlink")
        #expect(temp.read("dotfiles/claude.json").contains("esclop"))
        let mode = (try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
    }

    @Test func warpIsManual() throws {
        let temp = TempDir()
        let warp = try #require(AgentCatalog.agent("warp"))
        let installer = installer(temp)
        #expect(installer.status(warp, expected: Self.command).state == .manual)
        do {
            try installer.install(warp, command: Self.command)
            Issue.record("Warp has no file to edit")
        } catch {
            #expect("\(error)".contains("\"esclop\""), "the error carries the JSON to paste")
        }
    }

    @Test func detection() throws {
        let temp = TempDir()
        let installer = installer(temp)
        let claude = try #require(AgentCatalog.agent("claude-code"))
        let desktop = try #require(AgentCatalog.agent("claude-desktop"))
        let gemini = try #require(AgentCatalog.agent("gemini"))
        #expect(!installer.isPresent(claude) && !installer.isPresent(desktop) && !installer.isPresent(gemini))
        try FileManager.default.createDirectory(at: temp.url.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp.url.appendingPathComponent("Applications/Claude.app"), withIntermediateDirectories: true)
        let gem = temp.file("bin/gemini")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gem.path)
        #expect(installer.isPresent(claude) && installer.isPresent(desktop) && installer.isPresent(gemini))
    }

    @Test func aliasesResolve() {
        #expect(AgentCatalog.agent("claude")?.id == "claude-code")
        #expect(AgentCatalog.agent("ChatGPT")?.id == "codex")
        #expect(AgentCatalog.agent("nope") == nil)
        #expect(Set(AgentCatalog.all.map(\.id)).isSuperset(of: ["claude-code", "claude-desktop", "codex", "cursor", "windsurf", "zed", "gemini", "copilot", "opencode", "pi", "warp"]))
    }
}

@Suite struct JSONCEditing {
    @Test func setInsertsIntoEmptyAndNestedObjects() throws {
        var doc = JSONCDocument("")
        try doc.set(["a", "b"], to: .object([("c", .string("d"))]))
        #expect(try doc.value(at: ["a", "b", "c"]) == "d")
        doc = JSONCDocument("{}")
        try doc.set(["x"], to: .bool(true))
        #expect(doc.string == "{\n  \"x\": true\n}")
        doc = JSONCDocument("{\n\t\"a\": {\n\t\t\"k\": 1\n\t}\n}\n")
        try doc.set(["a", "new"], to: .string("v"))
        #expect(doc.string == "{\n\t\"a\": {\n\t\t\"k\": 1,\n\t\t\"new\": \"v\"\n\t}\n}\n", "follows the file's tabs")
    }

    @Test func replaceAndRemove() throws {
        var doc = JSONCDocument("{\"a\": 1, \"b\": [1, 2], \"c\": \"x\\\"y\"}")
        try doc.set(["b"], to: .string("z"))
        #expect(try doc.value(at: ["b"]) == "z")
        #expect(try doc.value(at: ["c"]) == "x\"y")
        #expect(try doc.remove(["a"]))
        #expect(try doc.remove(["c"]))
        #expect(!(try doc.remove(["missing"])))
        #expect((try? JSONSerialization.jsonObject(with: Data(doc.string.utf8))) != nil, "\(doc.string)")
    }

    @Test func nonObjectsAreRefused() {
        var doc = JSONCDocument("{\"mcpServers\": []}")
        #expect(throws: (any Error).self) { try doc.set(["mcpServers", "esclop"], to: .bool(true)) }
    }
}
