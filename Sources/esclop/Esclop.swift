// SPDX-License-Identifier: GPL-3.0-or-later
//
// `esclop`: optimise, convert, crop and resize media from the command line, manage pipelines and
// settings, and serve MCP to AI agents.

import ArgumentParser
import EsclopCore
import EsclopIPC
import EsclopMCP
import Foundation

@main
struct EsclopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "esclop",
        abstract: "Optimise, convert, crop and downscale images, videos, PDFs and audio.",
        discussion: """
        Commands go through the L'Esclop app when it is running (results then show on screen and use the \
        app's settings) and run in this process otherwise. --in-process (or ESCLOP_NO_APP=1) skips the app.

        Exit codes:
          0   success
          1   one or more files failed, or the command failed
          64  usage error (bad flag or value)
          65  every file was unreadable (damaged or mislabelled)
          66  every file was missing
          69  something needed is unavailable (the app, the engine, a tool)
          77  not permitted (an agent permission is off)
          130 interrupted
        """,
        version: EsclopVersion.string,
        subcommands: [
            Optimise.self, Convert.self, Downscale.self, Crop.self, Fit.self, Strip.self, Upload.self,
            PDF.self, Pipeline.self, Settings.self, Status.self, Logs.self, MCPCommand.self, InstallCLI.self,
        ]
    )
}

// MARK: - Shared options

struct GlobalOptions: ParsableArguments {
    @Flag(name: [.customShort("j"), .long], help: "Print JSON instead of text.")
    var json = false

    @Flag(name: .customLong("no-color"), help: "No colour, even on a terminal.")
    var noColor = false

    @Flag(name: .customLong("in-process"), help: "Do the work here even when the L'Esclop app is running.")
    var inProcess = false

    func context(origin: RequestOrigin = .cli) -> ServiceContext {
        Integrations.context(origin: origin, inProcess: inProcess)
    }

    var terminal: Terminal { Terminal(color: !noColor && !json) }
}

enum Behaviour: String, ExpressibleByArgument, CaseIterable {
    case inplace, samefolder, temp, specificfolder
}

/// Files and where results go, shared by every file command.
struct FileOptions: ParsableArguments {
    @Argument(help: "Files or folders. ~, file:// URLs and relative paths work.")
    var items: [String] = []

    @Flag(name: .shortAndLong, help: "Include files in subfolders.")
    var recursive = false

    @Option(name: .long, parsing: .upToNextOption, help: "Only these extensions from folders (png jpg ...).")
    var types: [String] = []

    @Option(name: .customLong("exclude-types"), parsing: .upToNextOption, help: "Skip these extensions.")
    var excludeTypes: [String] = []

    @Option(name: .shortAndLong, help: "Output folder (ending in /) or path template: %f name, %e extension, %d folder.")
    var output: String?

    @Option(help: "Where results go: inplace (default, keeps a backup), samefolder, temp, specificfolder (with -o).")
    var behaviour: Behaviour?

    @Flag(name: .customLong("skip-errors"), help: "Skip files that do not exist instead of failing on them.")
    var skipErrors = false

    @Flag(name: [.customShort("g"), .customLong("gui")], inversion: .prefixedNo, help: "Show the result card when the app runs.")
    var gui = true

    @Flag(name: [.customShort("n"), .customLong("no-progress")], help: "No progress on stderr.")
    var noProgress = false

    @Flag(name: [.customShort("c"), .customLong("copy")], help: "Copy the results to the clipboard.")
    var copy = false

    func validate() throws {
        // An empty list is refused when the command runs: `pdf crop --list-devices` takes no files.
        if behaviour == .specificfolder, output == nil { throw ValidationError("--behaviour specificfolder needs -o <folder>.") }
    }

    var location: OutputLocation {
        if let output { return .path(output) }
        switch behaviour {
        case .samefolder: return .sameFolder
        case .temp: return .temporary
        case .inplace, .specificfolder, nil: return .inPlace
        }
    }

    func sources() throws -> [URL] {
        let urls = try items.map { try PathInput.url($0) }
        let include = Set(types.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        let exclude = Set(excludeTypes.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        var files = PathInput.expand(urls, recursive: recursive, extensions: include)
        if !exclude.isEmpty { files.removeAll { exclude.contains($0.pathExtension.lowercased()) } }
        if skipErrors { files.removeAll { !FileManager.default.fileExists(atPath: $0.path) } }
        return files
    }
}

struct QualityOptions: ParsableArguments {
    @Flag(name: .shortAndLong, help: "Trade visible quality for smaller files.")
    var aggressive = false

    @Option(help: "0-100, higher is smaller and lossier. Overrides --aggressive.")
    var compression: Int?

    @Flag(name: .customLong("strip-metadata"), help: "Also remove EXIF, GPS and other metadata.")
    var stripMetadata = false

    func validate() throws {
        if let compression, !(0 ... 100).contains(compression) { throw ValidationError("--compression is 0 to 100.") }
    }

    var quality: CompressionQuality {
        if let compression { return CompressionQuality(tier: .custom, factor: compression) }
        return aggressive ? .aggressive : .normal
    }
}
