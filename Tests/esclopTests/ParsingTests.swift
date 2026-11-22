// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import CoreGraphics
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
                                           "--exclude-types", "gif", "-o", "~/out/", "--skip-errors", "--no-gui", "-n", "-c", "-j", "--in-process"])
        #expect(command.files.inputs.items == ["a.png", "~/b.mov"])
        #expect(command.quality.aggressive)
        #expect(command.quality.quality == .aggressive)
        #expect(command.downscaleFactor == 0.5)
        #expect(command.crop == "1920x1080")
        #expect(command.removeAudio && command.files.inputs.recursive && command.files.inputs.skipErrors && command.files.inputs.noProgress && command.files.copy)
        #expect(command.playbackSpeedFactor == 2)
        #expect(command.pdfDPI == 150)
        #expect(command.files.inputs.types == ["png", "jpg"])
        #expect(command.files.inputs.excludeTypes == ["gif"])
        #expect(command.files.location == .path("~/out/"))
        #expect(!command.files.inputs.gui)
        #expect(command.global.json && command.global.inProcess)
        #expect(try parse(["optimize", "a.png"], as: Optimise.self).files.location == .inPlace)
        #expect(try parse(["optimise", "a.png", "--compression", "70"], as: Optimise.self).quality.quality == CompressionQuality(tier: .custom, factor: 70))
        #expect(try parse(["optimise", "a.png", "--behaviour", "temp"], as: Optimise.self).files.location == .temporary)
        #expect(try parse(["optimise", "a.png"], as: Optimise.self).adaptive == nil, "the setting decides")
        #expect(try parse(["optimise", "a.png", "--adaptive"], as: Optimise.self).adaptive == true)
        #expect(try parse(["optimise", "a.png", "--no-adaptive"], as: Optimise.self).adaptive == false)
    }

    /// `optimise image|video|pdf|audio`: the plain command's options for one kind; a file of
    /// another kind is refused before anything runs. Files keep working as before.
    @Test func optimiseOneKind() throws {
        let images: Optimise = try parse(["optimise", "image", "a.png", "b.jpg", "-a"])
        #expect(images.onlyKind == .image && images.files.inputs.items == ["image", "a.png", "b.jpg"] && images.quality.aggressive)
        let video: Optimise = try parse(["optimise", "video", "a.mov", "--bitrate", "2500"])
        #expect(video.onlyKind == .video && video.bitrate.bitrate == 2500)
        #expect(try parse(["optimize", "pdf", "a.pdf"], as: Optimise.self).onlyKind == .pdf)
        #expect(try parse(["optimise", "audio", "a.mp3"], as: Optimise.self).onlyKind == .audio)
        #expect(rejects(["optimise", "image", "a.png", "b.mov"]))
        #expect(rejects(["optimise", "pdf", "a.png"]))
        #expect(rejects(["optimise", "image"]))
        // A folder is fine: only its files of that kind are taken.
        #expect(throws: Never.self) { try parse(["optimise", "image", NSTemporaryDirectory()], as: Optimise.self) }
        #expect(try parse(["optimise", "images.png"], as: Optimise.self).onlyKind == nil)
    }

    @Test func bitrateIsForVideoAndAudio() throws {
        var request = OptimisationRequest(sources: [URL(fileURLWithPath: "/a.mov")], origin: .cli)
        try parse(["optimise", "a.mov", "--bitrate", "3000"], as: Optimise.self).bitrate.apply(to: &request)
        #expect(request.videoBitrateKbps == 3000 && request.audioBitrateKbps == nil, "the video stream's; the soundtrack keeps its own")
        var audio = OptimisationRequest(sources: [URL(fileURLWithPath: "/a.mp3")], origin: .cli)
        try parse(["convert", "-t", "m4a", "a.mp3", "--bitrate", "96"], as: Convert.self).bitrate.apply(to: &audio)
        #expect(audio.audioBitrateKbps == 96 && audio.videoBitrateKbps == nil)
        #expect(rejects(["optimise", "a.mov", "--bitrate", "0"]))
        #expect(rejects(["optimise", "a.mov", "--bitrate", "fast"]))
    }

    @Test func optimiseRejectsBadValues() {
        #expect(rejects(["optimise", "a.png", "--compression", "101"]))
        #expect(rejects(["optimise", "a.png", "--downscale-factor", "2"]))
        #expect(rejects(["optimise", "a.png", "--crop", "big"]))
        #expect(rejects(["optimise", "a.png", "--behaviour", "specificfolder"]))
        #expect(rejects(["optimise", "a.png", "--behaviour", "sideways"]))
        // Two answers to "where do results go".
        #expect(rejects(["optimise", "a.png", "--behaviour", "temp", "-o", "out/"]))
        #expect(rejects(["optimise", "a.png", "--behaviour", "inplace", "-o", "out/"]))
        #expect(throws: Never.self) { try parse(["optimise", "a.png", "--behaviour", "specificfolder", "-o", "out/"], as: Optimise.self) }
    }

    /// -o is read from the working directory, like every Unix tool; only a location the person
    /// did not choose follows "Converted … go".
    @Test func outputPathsStartInTheWorkingDirectory() throws {
        #expect(FileOptions.anchored("out/", workingDirectory: "/work") == "/work/out/")
        #expect(FileOptions.anchored("./out/%f.png", workingDirectory: "/work/") == "/work/out/%f.png")
        for absolute in ["/abs/", "~/out/", "%d/small/%f"] {
            #expect(FileOptions.anchored(absolute, workingDirectory: "/work") == absolute)
        }
        let cwd = FileManager.default.currentDirectoryPath
        let command: Optimise = try parse(["optimise", "in/a.png", "-o", "out/"])
        #expect(command.files.location == .path(cwd + (cwd.hasSuffix("/") ? "" : "/") + "out/"))
        #expect(!command.files.locationFromSettings)
        #expect(try parse(["convert", "-t", "webp", "a.png"], as: Convert.self).files.locationFromSettings)
        #expect(try !parse(["convert", "-t", "webp", "a.png", "--behaviour", "inplace"], as: Convert.self).files.locationFromSettings)
    }

    /// upload takes only what it honours: no output location, no --in-process.
    @Test func uploadOffersOnlyWhatItHonours() throws {
        let command: Upload = try parse(["upload", "a.png", "--to", "r2", "-c", "-j"])
        #expect(command.target == "r2" && command.copy && command.printing.json)
        #expect(rejects(["upload", "a.png", "-o", "out/"]))
        #expect(rejects(["upload", "a.png", "--behaviour", "temp"]))
        #expect(rejects(["upload", "a.png", "--in-process"]))
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

        #expect(try parse(["strip", "a.jpg", "-r"], as: Strip.self).files.inputs.recursive)
        #expect(try parse(["strip-exif", "a.jpg"], as: Strip.self).files.inputs.items == ["a.jpg"])
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
        #expect(run.files.inputs.items == ["a.png", "b.png"])
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

    /// `pdf pages` reports the size of every page it wrote, not of the first.
    @Test func pageExportReportsAllPages() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("esclop-pages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = folder.appendingPathComponent("doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = try #require(CGContext(pdf as CFURL, mediaBox: &box, nil))
        for shade in [0.2, 0.6] {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: shade, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 20, y: 20, width: 160, height: 260))
            context.endPDFPage()
        }
        context.closePDF()
        let output = try await runEsclop(["pdf", "pages", pdf.path, "--dpi", "72", "--json", "-o", folder.appendingPathComponent("pages").path]).stdout
        let export = try JSONDecoder().decode(PageExport.self, from: output)
        #expect(export.pages.count == 2)
        #expect(export.bytes == export.pages.reduce(0) { $0 + PageExport.size(of: URL(fileURLWithPath: $1)) })
        #expect(export.bytes > PageExport.size(of: URL(fileURLWithPath: export.pages[0])))
    }

    /// The result and total lines, as printed without colour: a growth reads "+33.9%", never "−-33.9%".
    @Test func resultAndTotalLinesSignTheirPercent() {
        func result(_ name: String, before: Int, after: Int) -> OptimisationResult {
            OptimisationResult(
                source: URL(fileURLWithPath: "/x/\(name)"), output: URL(fileURLWithPath: "/x/\(name)"), kind: .image,
                bytesBefore: before, bytesAfter: after, startedAt: Date(), finishedAt: Date(), steps: []
            )
        }
        let terminal = Terminal(color: false)
        func summary(_ results: OptimisationResult...) -> JobSummary {
            var report = JobReport(route: "in-process")
            report.results = results
            return JobSummary(operation: "strip", report: report)
        }
        let grew = summary(result("real.heic", before: 25_100_000, after: 33_600_000), result("p.tiff", before: 16_000, after: 3_600))
        #expect(grew.results.map { terminal.line($0) } == ["✓ real.heic 25.1 MB → 33.6 MB +33.9%", "✓ p.tiff 16.0 KB → 3.6 KB −77.5%"])
        #expect(terminal.total(grew) == "Total 25.1 MB → 33.6 MB (+33.8%) over 2 files")
        let shrank = summary(result("a.png", before: 2_000, after: 1_000), result("b.png", before: 2_000, after: 1_000))
        #expect(terminal.total(shrank) == "Total 4.0 KB → 2.0 KB (−50.0%) over 2 files")
    }

    /// A file already as small as it gets is unchanged, not failed: `set -e` scripts that
    /// optimise twice keep going.
    @Test func alreadySmallestIsNotAFailure() {
        func code(_ errors: [EsclopError], results: Int = 0) -> Int32 {
            var report = JobReport(route: "in-process")
            report.failures = errors.map { FileFailure(source: URL(fileURLWithPath: "/x/a.png"), error: $0) }
            let result = OptimisationResult(
                source: URL(fileURLWithPath: "/x/b.png"), output: URL(fileURLWithPath: "/x/b.png"), kind: .image,
                bytesBefore: 2, bytesAfter: 1, startedAt: Date(), finishedAt: Date(), steps: []
            )
            report.results = Array(repeating: result, count: results)
            return Output.exitCode(for: JobSummary(operation: "optimise", report: report))
        }
        #expect(code([.alreadySmaller]) == 0)
        #expect(code([.alreadySmaller], results: 1) == 0)
        #expect(code([.alreadySmaller, .fileNotFound("/x/c.png")]) == 1)
        #expect(code([.fileNotFound("/x/c.png")]) == 66)
        // `-o photo.jpg --to webp`: wrong for every file is a usage error.
        #expect(code([.invalidArgument("photo.jpg ends in .jpg, but the result is .webp")]) == 64)
        #expect(code([.invalidArgument("x"), .toolMissing("ffmpeg")]) == 1)
        #expect(code([.invalidArgument("x")], results: 1) == 1)
    }

    /// `esclop restore` on a file with no recent result names the CLI's list, not the MCP tool,
    /// and exits 1 (nothing to put back is not a usage error); the JSON code stays.
    @Test func restoringAnUnknownFileNamesEsclopRecent() async throws {
        // An empty support folder of its own: no recent results, and the person's log is not read.
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("esclop-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        func run(_ arguments: [String]) async throws -> (Int32, String) {
            let result = try await runEsclop(arguments, environment: ["ESCLOP_SUPPORT_DIR": support.path])
            return (result.exitCode, result.output)
        }
        let unknown = FileManager.default.temporaryDirectory.appendingPathComponent("esclop-never-\(UUID().uuidString).png").path
        let (status, output) = try await run(["restore", "--no-color", unknown])
        #expect(status == 1, "\(output)")
        #expect(output.contains("`esclop recent`") && !output.contains("esclop_recent_results"), "\(output)")
        let (jsonStatus, json) = try await run(["restore", "--json", unknown])
        #expect(jsonStatus == 1 && json.contains("\"invalidArgument\""), "\(json)")
    }

    /// Exit 65 when every file was unreadable, through the real binary: the per-file path, which
    /// is where a damaged file actually fails (UI check, N9). A damaged PNG fails in ImageIO,
    /// before any bundled tool, so this runs everywhere.
    @Test func everyFileUnreadableExits65() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("esclop-exit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let broken = folder.appendingPathComponent("broken.png")
        let other = folder.appendingPathComponent("also broken.png")
        try Data("not a picture".utf8).write(to: broken)
        try Data("nor this".utf8).write(to: other)
        func run(_ files: [URL]) async throws -> (Int32, String) {
            let result = try await runEsclop(["optimise", "--in-process", "--no-color"] + files.map(\.path))
            return (result.exitCode, result.output)
        }
        let (status, output) = try await run([broken, other])
        #expect(status == 65, "\(output)")
        #expect(output.contains("This file isn’t an image L’Esclop can read. It may be damaged."))
        #expect(!output.contains(folder.path), "no path in the message")
        // One unreadable among other failures is a plain failure.
        let (mixed, _) = try await run([broken, folder.appendingPathComponent("missing.png")])
        #expect(mixed == 1)
    }

    /// `optimise` leaves files L'Esclop already optimised as they are; `--force`, or a level
    /// stronger than the regular one, does them anyway.
    @Test func optimisedFilesAreLeftAloneWithoutForce() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("esclop-mark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("done.png")
        try Data("not a picture".utf8).write(to: file)
        try OptimisedMark.set(file)
        func run(_ extra: [String]) async throws -> (Int32, String) {
            let result = try await runEsclop(["optimise", "--in-process", "--no-color"] + extra + [file.path])
            return (result.exitCode, result.output)
        }
        let (status, output) = try await run([])
        // Left as it is, like a file already as small as it gets: not a failure.
        #expect(status == 0)
        #expect(output.contains("unchanged: already optimised by L'Esclop (--force optimises it again)"), "\(output)")
        let (_, forced) = try await run(["--force"])
        #expect(!forced.contains("already optimised"), "\(forced)")
        #expect(forced.contains("It may be damaged"), "--force reaches the optimiser: \(forced)")
        for stronger in [["-a"], ["--compression", "70"]] {
            let (_, output) = try await run(stronger)
            #expect(output.contains("It may be damaged"), "\(stronger) reaches the optimiser: \(output)")
        }
        #expect(try await run(["--compression", "30"]).1.contains("already optimised"), "the regular level is no request to go again")
    }
}
