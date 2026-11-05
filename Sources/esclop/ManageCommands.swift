// SPDX-License-Identifier: GPL-3.0-or-later
//
// pipeline, settings, status, logs, install-cli.

import ArgumentParser
import EsclopCore
import EsclopIPC
import EsclopMCP
import EsclopPipelines
import Foundation

// MARK: - pipeline

struct Pipeline: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage and run pipelines: saved step sequences, built-in presets and inline steps.",
        discussion: "The language is described in docs/pipelines.md; `esclop pipeline reference` prints the step reference.",
        subcommands: [List.self, Show.self, Run.self, Write.self, Delete.self, Attach.self, Detach.self, Preset.self, Reference.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List saved pipelines with their triggers, and the built-in presets.")
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await guarded(global) {
                let store = global.context().pipelines
                let saved = try store.entries().map(PipelineInfo.init(entry:))
                let presets = PresetInfo.all(in: store)
                if global.json {
                    Output.json(PipelineListing(pipelines: saved, presets: presets))
                    return 0
                }
                let t = global.terminal
                if saved.isEmpty { print("No saved pipelines. `esclop pipeline write <name> <steps>` saves one.") }
                for info in saved {
                    let triggers = info.triggers.isEmpty ? "" : t.cyan("  [\(info.triggers.joined(separator: ", "))]")
                    let scripts = info.usesScripts ? t.yellow(" (script)") : ""
                    print("\(t.bold(info.name))\(scripts)  \(info.valid ? t.dim(info.summary) : t.red(info.problems.joined(separator: "; ")))\(triggers)")
                }
                print(t.dim("Presets: \(presets.map(\.name).joined(separator: ", "))"))
                return 0
            }
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print a saved pipeline or built-in preset.")
        @Argument(help: "The pipeline's name.") var name: String
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await guarded(global) {
                let store = global.context().pipelines
                let info: PipelineInfo
                if let entry = try store.entries().first(where: { $0.name.lowercased() == name.lowercased() }) {
                    info = PipelineInfo(entry: entry)
                } else if let preset = PipelineStore.preset(named: name) {
                    info = PipelineInfo(preset)
                } else {
                    throw EsclopError.invalidArgument("No pipeline named \(name)")
                }
                if global.json { Output.json(info) } else { print(info.text, terminator: info.text.hasSuffix("\n") ? "" : "\n") }
                return 0
            }
        }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run a pipeline on files: a saved name, a preset or inline steps.")
        @Argument(help: "A saved name, a preset, or steps such as \"crop(longEdge: 1600) -> convert(to: webp)\".") var pipeline: String
        @OptionGroup var files: FileOptions
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await runFileJob(.pipeline(pipeline), files: files, global: global) { $0.pipeline = pipeline }
        }
    }

    struct Write: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Save a pipeline under a name.", aliases: ["add"])
        @Argument(help: "The name.") var name: String
        @Argument(help: "The pipeline text (steps, or a whole .pipeline file), or - to read it from stdin.") var steps: String
        @Flag(name: [.customLong("replace"), .customLong("force")], help: "Replace a pipeline with the same name.") var replace = false
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await guarded(global) {
                let source = steps == "-" ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) : steps
                let service = EsclopService(global.context())
                let pipeline = try service.writePipeline(name: name, source: source, replace: replace)
                let info = PipelineInfo(pipeline, path: service.context.pipelines.fileURL(for: pipeline.name))
                if global.json { Output.json(info) } else { print("\(global.terminal.green("✓")) saved \(global.terminal.bold(name)): \(info.summary)") }
                return 0
            }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a saved pipeline (it goes to the Trash).")
        @Argument(help: "The name.") var name: String
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await guarded(global) {
                try EsclopService(global.context()).deletePipeline(name)
                if global.json { Output.json(["deleted": name]) } else { print("deleted \(name)") }
                return 0
            }
        }
    }

    struct Attach: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Make a pipeline run on its own: add a trigger.")
        @Argument(help: "A saved pipeline or built-in preset.") var pipeline: String
        @Option(name: [.customLong("trigger"), .customLong("source")], help: "\(PipelineTriggers.help).") var trigger: String
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await guarded(global) {
                let parsed = try PipelineTriggers.parse(trigger)
                let service = EsclopService(global.context())
                let updated = try service.attach(parsed, to: pipeline)
                let info = PipelineInfo(updated, path: service.context.pipelines.fileURL(for: updated.name))
                if global.json { Output.json(info) } else { print("\(updated.name) runs on \(parsed.description)") }
                return 0
            }
        }
    }

    struct Detach: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a trigger from one pipeline, or from all that have it.")
        @Argument(help: "Only this pipeline.") var pipeline: String?
        @Option(name: [.customLong("trigger"), .customLong("source")], help: "\(PipelineTriggers.help).") var trigger: String
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await guarded(global) {
                let parsed = try PipelineTriggers.parse(trigger)
                let changed = try EsclopService(global.context()).detach(parsed, from: pipeline)
                if global.json { Output.json(changed) } else { print(changed.isEmpty ? "no pipeline had \(parsed.description)" : "removed \(parsed.description) from \(changed.joined(separator: ", "))") }
                return 0
            }
        }
    }

    struct Preset: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Built-in presets and drop-zone preset zones.",
            subcommands: [List.self, Install.self, Add.self, Remove.self], defaultSubcommand: List.self
        )

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "List the built-in presets.")
            @OptionGroup var global: GlobalOptions

            func run() async throws {
                let store = global.context().pipelines
                let presets = PresetInfo.all(in: store)
                if global.json { Output.json(presets); return }
                for preset in presets { print("\(global.terminal.bold(preset.name))\(preset.installed ? global.terminal.dim(" (installed)") : "")  \(preset.summary)") }
            }
        }

        struct Install: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Copy a built-in preset into the pipelines folder to edit or attach.")
            @Argument(help: "The preset's name.") var name: String
            @Flag(name: [.customLong("replace"), .customLong("force")], help: "Overwrite a saved pipeline with the same name.") var replace = false
            @OptionGroup var global: GlobalOptions

            func run() async throws {
                try await guarded(global) {
                    let pipeline = try EsclopService(global.context()).installPreset(name, replace: replace)
                    if global.json { Output.json(PipelineInfo(pipeline)) } else { print("installed \(pipeline.name)") }
                    return 0
                }
            }
        }

        struct Add: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Show a pipeline as a preset zone while dragging.")
            @Argument(help: "A saved pipeline or built-in preset.") var name: String
            @OptionGroup var global: GlobalOptions

            func run() async throws {
                try await guarded(global) {
                    let pipeline = try EsclopService(global.context()).attach(.presetZone, to: name)
                    if global.json { Output.json(PipelineInfo(pipeline)) } else { print("\(pipeline.name) is a preset zone") }
                    return 0
                }
            }
        }

        struct Remove: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Stop showing a pipeline as a preset zone.")
            @Argument(help: "The pipeline's name.") var name: String
            @OptionGroup var global: GlobalOptions

            func run() async throws {
                try await guarded(global) {
                    let changed = try EsclopService(global.context()).detach(.presetZone, from: name)
                    if global.json { Output.json(changed) } else { print(changed.isEmpty ? "\(name) was not a preset zone" : "\(name) is no longer a preset zone") }
                    return 0
                }
            }
        }
    }

    struct Reference: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the pipeline language reference (every step and argument).", aliases: ["prompt"])

        func run() async throws {
            print(PipelineLanguage.referenceMarkdown())
        }
    }
}

struct PipelineListing: Codable {
    var pipelines: [PipelineInfo]
    var presets: [PresetInfo]
}

// MARK: - settings

struct Settings: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read and change L'Esclop's settings.",
        subcommands: [Schema.self, Get.self, Set.self], defaultSubcommand: Schema.self
    )

    struct Schema: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Every setting, its value and what it accepts. Words narrow it.")
        @Argument(help: "Words to search for.") var query: [String] = []
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await guarded(global) {
                let list = try await EsclopService(global.context()).settingsSchema(query: query.isEmpty ? nil : query.joined(separator: " "))
                if global.json { Output.json(list); return 0 }
                let t = global.terminal
                if list.isEmpty { print("No setting matches.") }
                for setting in list {
                    let choices = setting.choices.map { " (\($0.joined(separator: ", ")))" } ?? ""
                    print("\(t.bold(setting.key)) = \(t.cyan((setting.value ?? setting.defaultValue).plain))  \(t.dim(setting.type.rawValue + choices))")
                    print("  \(setting.title). \(setting.summary)")
                }
                return 0
            }
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Read one setting.")
        @Argument(help: "The key.") var key: String
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await guarded(global) {
                let setting = try await EsclopService(global.context()).setting(key)
                if global.json { Output.json(setting) } else { print((setting.value ?? setting.defaultValue).plain) }
                return 0
            }
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change one setting. Applies immediately.")
        @Argument(help: "The key.") var key: String
        @Argument(help: "The value: true/false, a number, or one of the allowed values.") var value: String
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await guarded(global) {
                let stored = try await EsclopService(global.context()).setSetting(key, to: value)
                if global.json { Output.json(["key": JSONValue.string(key), "value": stored]) } else { print("\(key) = \(stored.plain)") }
                return 0
            }
        }
    }
}

// MARK: - status, logs

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Version, app, engine, agent permissions and paths.")
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await guarded(global) {
            let status = await EsclopService(global.context()).status()
            if global.json { Output.json(status); return 0 }
            let t = global.terminal
            print("L'Esclop \(status.version)")
            print("app       \(status.app.running ? t.green("running") + (status.app.pid.map { " (pid \($0))" } ?? "") : t.dim("not running"))")
            print("jobs run  \(status.route)\(status.route == "in-process" ? " with engine \(status.engine)" : "")")
            print("agents    " + AgentPermission.allCases.map { "\($0.rawValue) \(status.permissions[$0.rawValue] == true ? t.green("on") : t.dim("off"))" }.joined(separator: ", "))
            for key in ["support", "pipelines", "backups", "logs"] { print("\(key.padding(toLength: 10, withPad: " ", startingAt: 0))\(status.paths[key] ?? "")") }
            return 0
        }
    }
}

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "L'Esclop's recent log messages and log files.")
    @Option(help: "How far back: 30s, 10m, 1h, 2d.") var last = "10m"
    @Option(help: "At most this many lines per source.") var lines = 200
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await guarded(global) {
            let excerpt = try EsclopService(global.context()).logs(window: last, limit: lines)
            if global.json { Output.json(excerpt); return 0 }
            excerpt.system.forEach { print($0) }
            for (file, tail) in excerpt.files.sorted(by: { $0.key < $1.key }) {
                print(global.terminal.bold("== \(file)"))
                tail.forEach { print($0) }
            }
            if let note = excerpt.note { FileHandle.standardError.write(Data("\(note)\n".utf8)) }
            return 0
        }
    }
}

// MARK: - install-cli

struct InstallCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-cli",
        abstract: "Link this esclop binary into a folder on PATH (default ~/.local/bin)."
    )

    @Option(help: "Folder to link into.") var dir: String = "~/.local/bin"
    @Flag(help: "Replace an existing esclop there.") var force = false
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await guarded(global) {
            let folder = try PathInput.url(dir)
            let link = folder.appendingPathComponent("esclop")
            let target = ServerCommand.current().command
            let fm = FileManager.default
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path), URL(fileURLWithPath: existing, relativeTo: folder).resolvingSymlinksInPath().path == target {
                print("\(PathInput.abbreviate(link)) already points to this esclop")
                return 0
            }
            if fm.fileExists(atPath: link.path) || (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
                guard force else { throw EsclopError.invalidArgument("\(PathInput.abbreviate(link)) exists; pass --force to replace it") }
                try fm.removeItem(at: link)
            }
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
            let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            let onPath = path.contains(folder.path) || path.contains(folder.path + "/")
            if global.json {
                Output.json(["link": link.path, "target": target, "onPath": onPath ? "true" : "false"])
            } else {
                print("\(global.terminal.green("✓")) \(PathInput.abbreviate(link)) → \(PathInput.abbreviate(target))")
                if !onPath { print("\(PathInput.abbreviate(folder)) is not on PATH; add it to your shell profile.") }
            }
            return 0
        }
    }
}
