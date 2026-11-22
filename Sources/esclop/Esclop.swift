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

        Results replace the original by default and keep a backup: `esclop recent` lists them and \
        `esclop restore <file>` puts the original back. A result in another format follows the \
        "Converted … go" setting unless -o or --behaviour says where it goes. Relative paths, -o \
        included, start in the working directory.

        Exit codes:
          0   success, also when a file is already as small as it gets (left unchanged)
          1   one or more files failed, or the command failed
          64  usage error (bad flag or value)
          65  every file was unreadable (damaged or mislabelled)
          66  every file was missing
          69  something needed is unavailable (the app, the engine, a tool)
          70  a setting was not kept (settings set, settings import)
          77  not permitted (an agent permission is off)
          130 interrupted
        """,
        version: EsclopVersion.string,
        subcommands: [
            Optimise.self, Convert.self, Downscale.self, Crop.self, Fit.self, Strip.self, Upload.self,
            Recent.self, Restore.self, PDF.self, Pipeline.self, Settings.self, Status.self, Logs.self, MCPCommand.self, InstallCLI.self,
        ]
    )
}

// MARK: - Shared options

/// How results are printed: every command has these.
struct Printing: ParsableArguments {
    @Flag(name: [.customShort("j"), .long], help: "Print JSON instead of text.")
    var json = false

    @Flag(name: .customLong("no-color"), help: "No colour, even on a terminal.")
    var noColor = false

    var terminal: Terminal { Terminal(color: !noColor && !json) }
}

struct GlobalOptions: ParsableArguments {
    @OptionGroup var printing: Printing

    @Flag(name: .customLong("in-process"), help: "Do the work here even when the L'Esclop app is running.")
    var inProcess = false

    func context(origin: RequestOrigin = .cli) -> ServiceContext {
        Integrations.context(origin: origin, inProcess: inProcess)
    }

    var json: Bool { printing.json }
    var terminal: Terminal { printing.terminal }
}

enum Behaviour: String, ExpressibleByArgument, CaseIterable {
    case inplace, samefolder, temp, specificfolder
}

/// The files a command works on, shared by every file command and upload.
struct FileInputs: ParsableArguments {
    @Argument(help: "Files or folders. ~, file:// URLs and relative paths work. An http(s) address is downloaded first, into the working directory when the result goes beside its file (the default), else into the temporary folder.")
    var items: [String] = []

    @Flag(name: .shortAndLong, help: "Include files in subfolders.")
    var recursive = false

    @Option(name: .long, parsing: .upToNextOption, help: "Only these extensions from folders (png jpg ...).")
    var types: [String] = []

    @Option(name: .customLong("exclude-types"), parsing: .upToNextOption, help: "Skip these extensions.")
    var excludeTypes: [String] = []

    @Flag(name: .customLong("skip-errors"), help: "Skip files that do not exist instead of failing on them.")
    var skipErrors = false

    @Flag(name: [.customShort("g"), .customLong("gui")], inversion: .prefixedNo, help: "Show the result card when the app runs.")
    var gui = true

    @Flag(name: [.customShort("n"), .customLong("no-progress")], help: "No progress on stderr.")
    var noProgress = false

    /// The files to work on. A web address is the person's request to download it: it is
    /// fetched into the temporary folder and that copy is the file worked on, moved first into
    /// `folder` (the working directory, when the result goes beside its file) under a name
    /// nothing there has.
    func sources(
        into folder: URL? = nil, downloaded: (URL) -> Void = { _ in }, download: (URL) async throws -> URL = { try await WebDownload.fetch($0) }
    ) async throws -> [URL] {
        var urls: [URL] = []
        for item in items {
            guard let address = try WebDownload.address(item) else {
                urls.append(try PathInput.url(item))
                continue
            }
            if WebDownload.isInsecure(address) { note("\(item) comes over insecure http: it may have been changed on the way") }
            do {
                var file = try await download(address)
                if let folder {
                    let kept = OutputLocation.unique(folder.appendingPathComponent(file.lastPathComponent))
                    try FileManager.default.moveItem(at: file, to: kept)
                    // The download's own folder, once empty.
                    rmdir(file.deletingLastPathComponent().path)
                    file = kept
                }
                downloaded(file)
                urls.append(file)
            } catch where skipErrors {
                FileHandle.standardError.write(Data("skipped \(item): \(error)\n".utf8))
                continue
            } catch let error as EsclopError {
                throw error
            } catch let refusal as WebDownload.Refusal {
                throw EsclopError.other(refusal.description)
            } catch {
                throw EsclopError.other("Could not download \(item): \(error.localizedDescription)")
            }
        }
        let include = Set(types.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        let exclude = Set(excludeTypes.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        var files = PathInput.expand(urls, recursive: recursive, extensions: include)
        if !exclude.isEmpty { files.removeAll { exclude.contains($0.pathExtension.lowercased()) } }
        if skipErrors { files.removeAll { !FileManager.default.fileExists(atPath: $0.path) } }
        if files.isEmpty { urls.filter(PathInput.holdsOnlyLinks).forEach { note(PathInput.onlyLinks($0)) } }
        return files
    }
}

/// Files and where results go, shared by every file command.
struct FileOptions: ParsableArguments {
    @OptionGroup var inputs: FileInputs

    @Option(name: .shortAndLong, help: "Output folder (ending in /) or path template: %f name, %e extension, %d the file's folder. Relative to the working directory.")
    var output: String?

    @Option(help: "Where results go: inplace (default, keeps a backup; a result in another format follows the \"Converted … go\" setting), samefolder, temp, specificfolder (with -o).")
    var behaviour: Behaviour?

    @Flag(name: [.customShort("c"), .customLong("copy")], help: "Copy the results to the clipboard.")
    var copy = false

    func validate() throws {
        // An empty list is refused when the command runs: `pdf crop --list-devices` takes no files.
        if behaviour == .specificfolder, output == nil { throw ValidationError("--behaviour specificfolder needs -o <folder>.") }
        if let behaviour, behaviour != .specificfolder, output != nil {
            throw ValidationError("-o names where results go, and so does --behaviour \(behaviour.rawValue): give one of them.")
        }
    }

    var location: OutputLocation {
        if let output { return .path(Self.anchored(output)) }
        switch behaviour {
        case .samefolder: return .sameFolder
        case .temp: return .temporary
        case .inplace, .specificfolder, nil: return .inPlace
        }
    }

    /// Neither -o nor --behaviour: a result in another format follows "Converted … go".
    var locationFromSettings: Bool { output == nil && behaviour == nil }

    /// Where a web address is downloaded to: the working directory when the result goes beside
    /// its file, so the result is there and not in the temporary folder; else nil (temporary).
    var downloadFolder: URL? {
        output == nil && behaviour != .temp ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true) : nil
    }

    /// A relative -o template made absolute from the working directory, as every Unix tool reads
    /// it (the engines read a relative template from the file's folder). `~`, `%d` and `/` are
    /// absolute already.
    /// ponytail: templates have no escape, so a `%f`, `%e` or `%d` in the working directory's own
    /// path is expanded too; anchor per source in the CLI if a person ever hits it.
    static func anchored(_ template: String, workingDirectory: String = FileManager.default.currentDirectoryPath) -> String {
        if template.hasPrefix("file:"), let url = try? PathInput.url(template) {
            return url.path + (template.hasSuffix("/") ? "/" : "")
        }
        if template.hasPrefix("/") || template.hasPrefix("~") || template.hasPrefix("%d") { return template }
        let base = workingDirectory.hasSuffix("/") ? workingDirectory : workingDirectory + "/"
        return base + (template.hasPrefix("./") ? String(template.dropFirst(2)) : template)
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
