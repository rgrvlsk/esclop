// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import EsclopCore
import EsclopIPC
@testable import esclop
import Foundation
import Testing

func parse<T: ParsableCommand>(_ arguments: [String], as type: T.Type = T.self) throws -> T {
    let command = try EsclopCommand.parseAsRoot(arguments)
    guard let typed = command as? T else { throw ValidationError("parsed as \(Swift.type(of: command)), not \(T.self)") }
    return typed
}

func rejects(_ arguments: [String]) -> Bool {
    (try? EsclopCommand.parseAsRoot(arguments)) == nil
}

@Suite struct CLIParsing {
    @Test func optimise() throws {
        let command: Optimise = try parse(["optimise", "a.png", "~/b.mov", "-a", "--downscale-factor", "0.5", "--crop", "1920x1080",
                                           "--remove-audio", "--playback-speed-factor", "2", "--pdf-dpi", "150", "-r", "--types", "png", "jpg",
                                           "--exclude-types", "gif", "-o", "~/out/", "--behaviour", "samefolder", "--skip-errors", "--no-gui", "-n", "-c", "-j", "--in-process"])
        #expect(command.files.items == ["a.png", "~/b.mov"])
        #expect(command.quality.aggressive)
        #expect(command.quality.quality == .aggressive)
        #expect(command.downscaleFactor == 0.5)
        #expect(command.crop == "1920x1080")
        #expect(command.removeAudio && command.files.recursive && command.files.skipErrors && command.files.noProgress && command.files.copy)
        #expect(command.playbackSpeedFactor == 2)
        #expect(command.pdfDPI == 150)
        #expect(command.files.types == ["png", "jpg"])
        #expect(command.files.excludeTypes == ["gif"])
        #expect(command.files.location == .path("~/out/"))
        #expect(!command.files.gui)
        #expect(command.global.json && command.global.inProcess)
        #expect(try parse(["optimize", "a.png"], as: Optimise.self).files.location == .inPlace)
        #expect(try parse(["optimise", "a.png", "--compression", "70"], as: Optimise.self).quality.quality == CompressionQuality(tier: .custom, factor: 70))
        #expect(try parse(["optimise", "a.png", "--behaviour", "temp"], as: Optimise.self).files.location == .temporary)
    }

    @Test func optimiseRejectsBadValues() {
        #expect(rejects(["optimise", "a.png", "--compression", "101"]))
        #expect(rejects(["optimise", "a.png", "--downscale-factor", "2"]))
        #expect(rejects(["optimise", "a.png", "--crop", "big"]))
        #expect(rejects(["optimise", "a.png", "--behaviour", "specificfolder"]))
        #expect(rejects(["optimise", "a.png", "--behaviour", "sideways"]))
    }

    @Test func convert() throws {
        let command: Convert = try parse(["convert", "-t", "webp", "a.png", "--compression", "40", "--strip-metadata"])
        #expect(command.to == .webp)
        #expect(command.quality.stripMetadata)
        #expect(try parse(["convert", "--to", "jpg", "a.heic"], as: Convert.self).to == .jpeg)
        #expect(try parse(["convert", "--to", "gif-video", "a.mov"], as: Convert.self).to == .gifVideo)
        #expect(rejects(["convert", "a.png"]))
        #expect(rejects(["convert", "--to", "doc", "a.png"]))
    }

    @Test func downscaleCropFitStrip() throws {
        #expect(try parse(["downscale", "a.png"], as: Downscale.self).factor == 0.5)
        #expect(try parse(["downscale", "--factor", "0.25", "a.png"], as: Downscale.self).factor == 0.25)
        #expect(rejects(["downscale", "--factor", "0", "a.png"]))

        #expect(try parse(["crop", "-s", "1200x630", "a.png"], as: Crop.self).cropSize() == CropSize(width: 1200, height: 630))
        #expect(try parse(["crop", "--size", "16:9", "--smart-crop", "a.png"], as: Crop.self).cropSize() == CropSize(aspectRatio: "16:9", smart: true))
        #expect(try parse(["crop", "-s", "1600", "-l", "a.png"], as: Crop.self).cropSize() == CropSize(longEdge: 1600))
        #expect(rejects(["crop", "a.png"]))
        #expect(rejects(["crop", "-s", "huge", "a.png"]))

        #expect(try parse(["fit", "--under", "2MB", "a.png"], as: Fit.self).under == "2MB")
        #expect(try parse(["fit", "--max-size", "500KB", "a.png"], as: Fit.self).under == "500KB")
        #expect(rejects(["fit", "--under", "lots", "a.png"]))
        #expect(rejects(["fit", "a.png"]))

        #expect(try parse(["strip", "a.jpg", "-r"], as: Strip.self).files.recursive)
        #expect(try parse(["strip-exif", "a.jpg"], as: Strip.self).files.items == ["a.jpg"])
    }

    @Test func pdf() throws {
        let crop: PDF.CropPDF = try parse(["pdf", "crop", "--for-device", "Kindle Paperwhite", "-e", "doc.pdf"])
        #expect(crop.forDevice == "Kindle Paperwhite")
        #expect(crop.extend)
        #expect(try parse(["pdf", "crop", "--aspect-ratio", "3:4", "doc.pdf"], as: PDF.CropPDF.self).aspectRatio == "3:4")
        #expect(try parse(["pdf", "crop", "--paper-size", "A4", "doc.pdf"], as: PDF.CropPDF.self).paperSize == "A4")
        #expect(try parse(["pdf", "crop", "--list-devices"], as: PDF.CropPDF.self).listDevices)
        #expect(rejects(["pdf", "crop", "doc.pdf"]))
        #expect(rejects(["pdf", "crop", "--aspect-ratio", "3:4", "--paper-size", "A4", "doc.pdf"]))
        #expect(rejects(["pdf", "crop", "--paper-size", "Napkin", "doc.pdf"]))

        #expect(try parse(["pdf", "uncrop", "doc.pdf", "-o", "~/x/"], as: PDF.UncropPDF.self).files.output == "~/x/")

        let pages: PDF.Pages = try parse(["pdf", "pages", "doc.pdf", "--pages", "1,3-5", "--format", "jpeg", "--dpi", "200", "-o", "out"])
        #expect(try PDF.Pages.parsePages(pages.pages!) == [1, 3, 4, 5])
        #expect(pages.format == .jpeg)
        #expect(pages.dpi == 200)
        #expect(rejects(["pdf", "pages", "doc.pdf", "--format", "webp"]))
        #expect(rejects(["pdf", "pages", "doc.pdf", "--pages", "3-1"]))
    }

    @Test func pipeline() throws {
        _ = try parse(["pipeline", "list", "--json"], as: Pipeline.List.self)
        #expect(try parse(["pipeline", "show", "web"], as: Pipeline.Show.self).name == "web")
        let run: Pipeline.Run = try parse(["pipeline", "run", "crop(longEdge: 1600) -> convert(to: webp)", "a.png", "b.png", "--behaviour", "samefolder"])
        #expect(run.pipeline.hasPrefix("crop"))
        #expect(run.files.items == ["a.png", "b.png"])
        let write: Pipeline.Write = try parse(["pipeline", "write", "web", "convert(to: webp)", "--replace"])
        #expect(write.replace && write.name == "web")
        #expect(try parse(["pipeline", "add", "web", "-", "--force"], as: Pipeline.Write.self).replace)
        #expect(try parse(["pipeline", "delete", "web"], as: Pipeline.Delete.self).name == "web")
        #expect(try parse(["pipeline", "attach", "web", "--trigger", "clipboard"], as: Pipeline.Attach.self).trigger == "clipboard")
        #expect(try parse(["pipeline", "attach", "web", "--source", "~/Downloads"], as: Pipeline.Attach.self).trigger == "~/Downloads")
        #expect(try parse(["pipeline", "detach", "--trigger", "clipboard"], as: Pipeline.Detach.self).pipeline == nil)
        #expect(try parse(["pipeline", "detach", "web", "--trigger", "dropZone"], as: Pipeline.Detach.self).pipeline == "web")
        _ = try parse(["pipeline", "preset"], as: Pipeline.Preset.List.self)
        #expect(try parse(["pipeline", "preset", "install", "to WebP", "--replace"], as: Pipeline.Preset.Install.self).replace)
        #expect(try parse(["pipeline", "preset", "add", "to WebP"], as: Pipeline.Preset.Add.self).name == "to WebP")
        #expect(try parse(["pipeline", "preset", "remove", "to WebP"], as: Pipeline.Preset.Remove.self).name == "to WebP")
        _ = try parse(["pipeline", "reference"], as: Pipeline.Reference.self)
        #expect(rejects(["pipeline", "attach", "web"]))
    }

    @Test func settingsStatusLogs() throws {
        #expect(try parse(["settings", "schema", "agent", "permission"], as: Settings.Schema.self).query == ["agent", "permission"])
        _ = try parse(["settings"], as: Settings.Schema.self)
        #expect(try parse(["settings", "get", "allowRunScripts", "-j"], as: Settings.Get.self).global.json)
        let set: Settings.Set = try parse(["settings", "set", "allowRunScripts", "true"])
        #expect(set.key == "allowRunScripts" && set.value == "true")
        #expect(rejects(["settings", "set", "allowRunScripts"]))
        #expect(try parse(["settings", "reset", "imageCompression"], as: Settings.Reset.self).key == "imageCompression")
        #expect(rejects(["settings", "reset"]))
        _ = try parse(["status", "--json"], as: Status.self)
        let logs: Logs = try parse(["logs", "--last", "1h", "--lines", "50"])
        #expect(logs.last == "1h" && logs.lines == 50)
        #expect(try parse(["install-cli", "--dir", "~/bin", "--force"], as: InstallCLI.self).force)
    }

    @Test func mcp() throws {
        _ = try parse(["mcp", "serve"], as: MCPCommand.Serve.self)
        _ = try parse(["mcp"], as: MCPCommand.Status.self)
        let install: MCPCommand.Install = try parse(["mcp", "install", "claude-code", "codex", "--command", "/usr/bin/true"])
        #expect(install.selection.agents == ["claude-code", "codex"])
        #expect(install.command == "/usr/bin/true")
        #expect(try parse(["mcp", "install", "--all"], as: MCPCommand.Install.self).selection.all)
        #expect(try parse(["mcp", "uninstall", "cursor"], as: MCPCommand.Uninstall.self).selection.agents == ["cursor"])
        #expect(rejects(["mcp", "install"]))
        #expect(rejects(["mcp", "install", "notepad"]))
        #expect(rejects(["mcp", "install", "cursor", "--all"]))
    }
}

@Suite struct CLIOutput {
    @Test func exitCodes() {
        #expect(Output.exitCode(for: .fileNotFound("x")) == 66)
        #expect(Output.exitCode(for: .appNotRunning) == 69)
        #expect(Output.exitCode(for: .toolMissing("engine")) == 69)
        #expect(Output.exitCode(for: .notPermitted("x")) == 77)
        #expect(Output.exitCode(for: .invalidPipeline("x")) == 64)
        #expect(Output.exitCode(for: .cancelled) == 130)
        #expect(Output.exitCode(for: .other("x")) == 1)
        #expect(Output.exitCode(for: .unreadable(kind: .video)) == 65)
    }

    /// Exit 65 when every file was unreadable, through the real binary: the per-file path, which
    /// is where a damaged file actually fails (UI check, N9). A damaged PNG fails in ImageIO,
    /// before any bundled tool, so this runs everywhere.
    @Test func everyFileUnreadableExits65() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("esclop-exit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let broken = folder.appendingPathComponent("broken.png")
        let other = folder.appendingPathComponent("also broken.png")
        try Data("not a picture".utf8).write(to: broken)
        try Data("nor this".utf8).write(to: other)
        func run(_ files: [URL]) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = try esclopBinary()
            process.arguments = ["optimise", "--in-process", "--no-color"] + files.map(\.path)
            process.environment = ProcessInfo.processInfo.environment.merging(["ESCLOP_NO_APP": "1"]) { $1 }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        let (status, output) = try run([broken, other])
        #expect(status == 65, "\(output)")
        #expect(output.contains("This file isn’t an image L’Esclop can read. It may be damaged."))
        #expect(!output.contains(folder.path), "no path in the message")
        // One unreadable among other failures is a plain failure.
        let (mixed, _) = try run([broken, folder.appendingPathComponent("missing.png")])
        #expect(mixed == 1)
    }
}
