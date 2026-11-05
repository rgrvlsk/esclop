// SPDX-License-Identifier: GPL-3.0-or-later
import EsclopCore
import Foundation
import Testing
@testable import EsclopPipelines

func runner(_ recorder: Recorder, engine: (any OptimisationEngine)? = nil, host: (any PipelineHost)? = nil, inspector: any MediaInspector = FakeInspector()) -> PipelineRunner {
    PipelineRunner(
        engine: engine ?? FakeEngine(recorder: recorder), host: host ?? NoopPipelineHost(), inspector: inspector,
        commands: FakeCommands(recorder: recorder), now: { fixedDate }
    )
}

func options(_ tmp: TempDir, scripts: Bool = false) -> PipelineRunOptions {
    PipelineRunOptions(allowRunScripts: scripts, temporaryDirectory: tmp.url.appendingPathComponent("tmp"))
}

// MARK: - Step sequence

@Test func runsStepsInOrderAndTracksTheFile() async throws {
    let tmp = try TempDir()
    let shot = try tmp.file("Screenshot 1.png", bytes: 4000)
    let rec = Recorder()
    let steps = try PipelineParser.parseSteps(#"if(regex: "^screen") -> optimise(encoder: aggressive) -> downscale(factor: 0.5) -> convert(to: webp) -> stripExif"#)
    let report = await runner(rec).run(steps: steps, on: [shot], options: options(tmp))

    #expect(rec.calls == [
        "optimise(Screenshot 1.png, inPlace, q64)",
        "downscale(Screenshot 1.png, inPlace, 0.5)",
        "convert(Screenshot 1.png, sameFolder, webp)",
        "strip(Screenshot 1-esclop.webp, inPlace)",
    ])
    let file = try #require(report.files.first)
    #expect(file.status == .completed)
    #expect(file.finalFile?.lastPathComponent == "Screenshot 1-esclop.webp")
    #expect(file.log.map(\.outcome) == [.done, .done, .done, .done, .done])
    #expect(file.results.count == 4)
    #expect(report.succeeded)
}

@Test func filterStopsTheFileQuietly() async throws {
    let tmp = try TempDir()
    let photo = try tmp.file("photo.png")
    let rec = Recorder()
    let report = await runner(rec).run(steps: try PipelineParser.parseSteps(#"if(nameContains: "shot") -> optimise"#), on: [photo], options: options(tmp))
    #expect(rec.calls.isEmpty)
    #expect(report.files[0].status == .filtered)
    #expect(report.files[0].log.last?.outcome == .stopped)
    #expect(report.succeeded)

    let rec2 = Recorder()
    let excluded = await runner(rec2).run(steps: try PipelineParser.parseSteps(#"ifNot(types: png) -> optimise"#), on: [photo], options: options(tmp))
    #expect(excluded.files[0].status == .filtered)
    #expect(rec2.calls.isEmpty)
}

@Test func filtersReadSizesDimensionsAndDuration() async throws {
    let tmp = try TempDir()
    let clip = try tmp.file("clip.mp4", bytes: 5000)
    let inspector = FakeInspector(size: (1920, 1080), seconds: 12)
    let pass = "if(widthGreaterThan: 1000, minResolution: 1000x1000, durationLowerThan: 30, fileSizeGreaterThan: 4000, minFileSize: 4KB) -> optimise"
    let rec = Recorder()
    let ok = await runner(rec, inspector: inspector).run(steps: try PipelineParser.parseSteps(pass), on: [clip], options: options(tmp))
    #expect(ok.files[0].status == .completed)
    let fail = await runner(Recorder(), inspector: inspector).run(steps: try PipelineParser.parseSteps("if(durationGreaterThan: 60) -> optimise"), on: [clip], options: options(tmp))
    #expect(fail.files[0].status == .filtered)
    let app = await runner(Recorder(), inspector: inspector).run(
        steps: try PipelineParser.parseSteps(#"if(copiedBy: "safari") -> optimise"#), on: [clip],
        options: PipelineRunOptions(sourceApp: "com.apple.Safari", temporaryDirectory: tmp.url)
    )
    #expect(app.files[0].status == .completed)
}

@Test func stepsForOtherKindsAreSkipped() async throws {
    let tmp = try TempDir()
    let png = try tmp.file("a.png")
    let rec = Recorder()
    let report = await runner(rec).run(steps: [.removeAudio, .capFps(fps: 30), .optimise()], on: [png], options: options(tmp))
    #expect(report.files[0].log.map(\.outcome) == [.skipped, .skipped, .done])
    #expect(rec.calls == ["optimise(a.png, inPlace, q30)"])
}

@Test func sectionsPickStepsPerKind() async throws {
    let tmp = try TempDir()
    let png = try tmp.file("a.png"), mov = try tmp.file("b.mov"), pdf = try tmp.file("c.pdf")
    let pipeline = try PipelineParser.parse("""
    optimise
    [video]
    changeSpeed(factor: 2, frames: drop) -> removeAudio -> optimise(encoder: fast)
    [pdf]
    optimise(dpi: 150)
    """)
    let rec = Recorder()
    let report = await runner(rec).run(pipeline, on: [png, mov, pdf], options: options(tmp))
    #expect(rec.calls == [
        "optimise(a.png, inPlace, q30)",
        "speed(b.mov, inPlace, 2.0 drop)",
        "mute(b.mov, inPlace)",
        "optimise(b.mov, inPlace, q30, h264_videotoolbox)",
        "optimise(c.pdf, inPlace, q30, 150dpi)",
    ])
    #expect(report.files.allSatisfy { $0.status == .completed })
}

@Test func optimiseFirstGoesAfterLeadingFilters() async throws {
    let tmp = try TempDir()
    let png = try tmp.file("shot.png")
    var p = try PipelineParser.parse(#"if(nameContains: "shot") -> copyToClipboard"#)
    p.optimiseFirst = true
    let rec = Recorder()
    let report = await runner(rec).run(p, on: [png], options: options(tmp))
    #expect(report.files[0].log.map(\.step) == [#"if(nameContains: "shot")"#, "optimise", "copyToClipboard"])
    // A pipeline that starts by re-encoding is not optimised first.
    var q = try PipelineParser.parse("convert(to: webp)")
    q.optimiseFirst = true
    let rec2 = Recorder()
    _ = await runner(rec2).run(q, on: [try tmp.file("b.png")], options: options(tmp))
    #expect(rec2.calls == ["convert(b.png, sameFolder, webp)"])
}

// MARK: - Locations and templates

@Test func templatesResolve() {
    let file = URL(fileURLWithPath: "/data/in/IMG_0042.HEIC")
    let ctx = TemplateContext(file: file, captures: ["0042"], date: fixedDate, counter: 7)
    #expect(ctx.resolve("%P/%y/%m/%d/%f.%e") == "/data/in/2026/03/07/IMG_0042.HEIC")
    #expect(ctx.resolve("%H-%M-%S %p #%i") == "14-05-09 PM #7")
    #expect(ctx.resolve("photo-$1") == "photo-0042")
    #expect(ctx.resolve("%F") == "/data/in/IMG_0042.HEIC")
    #expect(ctx.resolve("%n") == Calendar.current.monthSymbols[2])
    #expect(ctx.resolve("100% sure %q") == "100% sure %q")
    #expect(ctx.resolve("%r").count == 5)
    #expect(ctx.resolve("~/x") == FileManager.default.homeDirectoryForCurrentUser.path + "/x")
    #expect(ctx.resolve("$HOME") == FileManager.default.homeDirectoryForCurrentUser.path)
    // A file name containing a token is not expanded twice.
    let odd = TemplateContext(file: URL(fileURLWithPath: "/a/%y.png"), date: fixedDate)
    #expect(odd.resolve("%f") == "%y")
}

@Test func locationTemplatesBecomeAbsolutePathsWithTheRightExtension() async throws {
    let tmp = try TempDir()
    let png = try tmp.file("cat.png")
    let rec = Recorder()
    let out = tmp.url.appendingPathComponent("web").path
    let steps: [PipelineStep] = [
        .convert(to: "webp", location: .path("\(out)/%f-%y")),
        .downscale(factor: 0.5, location: .path("small/")),
        .optimise(location: .path("final")),
    ]
    let report = await runner(rec).run(steps: steps, on: [png], options: options(tmp))
    #expect(rec.calls == [
        "convert(cat.png, path:\(out)/cat-2026.webp, webp)",
        "downscale(cat-2026.webp, path:\(tmp.url.path)/small/cat-2026.webp, 0.5)",
        "optimise(cat-2026.webp, path:\(tmp.url.path)/final.webp, q30)",
    ])
    #expect(report.files[0].finalFile?.path == "\(tmp.url.path)/final.webp")
}

@Test func sameFolderMeansNextToTheOriginal() async throws {
    let tmp = try TempDir()
    let png = try tmp.file("cat.png")
    let rec = Recorder()
    _ = await runner(rec).run(steps: [.optimise(location: .temporary), .convert(to: "webp")], on: [png], options: options(tmp))
    #expect(rec.calls.count == 2)
    #expect(rec.calls[1].hasPrefix("convert("))
    #expect(rec.calls[1].contains("path:\(tmp.url.path)/"))
    #expect(rec.calls[1].hasSuffix("-cat.webp, webp)"))
}

@Test func fileOperationsMoveTheCurrentFile() async throws {
    let tmp = try TempDir()
    let png = try tmp.file("IMG_0042.png")
    let sorted = tmp.url.appendingPathComponent("sorted").path
    let steps = try PipelineParser.parseSteps(#"""
    if(regex: "^img_(\d+)")
    copy(to: "backup/")
    move(to: "\#(sorted)/%y/")
    rename(to: "photo-$1")
    """#)
    let report = await runner(Recorder()).run(steps: steps, on: [png], options: options(tmp))
    #expect(report.files[0].status == .completed, "\(report.files[0].log)")
    // `copy` continues with the copy, so the later move takes the copy and the original stays.
    #expect(tmp.exists("IMG_0042.png"))
    #expect(!tmp.exists("backup/IMG_0042.png"))
    #expect(tmp.exists("sorted/2026/photo-0042.png"))
    #expect(report.files[0].finalFile?.path == "\(sorted)/2026/photo-0042.png")
}

@Test func counterGoesUpPerFile() async throws {
    let tmp = try TempDir()
    let a = try tmp.file("a.png"), b = try tmp.file("b.png")
    let report = await runner(Recorder()).run(steps: [.rename(to: "pic %i")], on: [a, b], options: options(tmp))
    #expect(report.files.map { $0.finalFile?.lastPathComponent } == ["pic 1.png", "pic 2.png"])
}

@Test func convertToTheSameFormatDoesNothing() async throws {
    let tmp = try TempDir()
    let jpg = try tmp.file("a.JPG")
    let rec = Recorder()
    let report = await runner(rec).run(steps: [.convert(to: "jpeg")], on: [jpg], options: options(tmp))
    #expect(rec.calls.isEmpty)
    #expect(report.files[0].log[0].outcome == .unchanged)
}

@Test func videoToGifUsesTheVideoGifFormat() async throws {
    let tmp = try TempDir()
    let mov = try tmp.file("clip.mov")
    let rec = Recorder()
    let report = await runner(rec).run(try PipelineParser.parse("[video]\ncrop(longEdge: 800) -> convert(to: gif)"), on: [mov], options: options(tmp))
    #expect(rec.calls == ["crop(clip.mov, inPlace, w0 h0 l800)", "convert(clip.mov, sameFolder, gif-video)"])
    #expect(report.files[0].finalFile?.pathExtension == "gif")
}

// MARK: - Fork

@Test func forkCopiesWhenALaterStepWouldOverwrite() async throws {
    let tmp = try TempDir()
    let png = try tmp.file("a.png")
    let rec = Recorder()
    let report = await runner(rec, host: RecordingHost(recorder: rec)).run(
        steps: try PipelineParser.parseSteps("optimise -> fork -> convert(to: webp, location: inPlace)"), on: [png], options: options(tmp)
    )
    let file = report.files[0]
    #expect(file.status == .completed)
    #expect(file.extraOutputs.count == 1)
    let forked = try #require(file.extraOutputs.first)
    #expect(forked.path.hasPrefix(tmp.url.appendingPathComponent("tmp").path))
    #expect(FileManager.default.fileExists(atPath: forked.path))
    #expect(rec.calls.contains("host presentFork a.png"))
    #expect(file.finalFile?.lastPathComponent == "a.webp")
}

@Test func forkWithoutLaterChangesPointsAtTheFile() async throws {
    let tmp = try TempDir()
    let png = try tmp.file("a.png")
    let report = await runner(Recorder()).run(steps: [.optimise(), .fork(), .copyToClipboard()], on: [png], options: options(tmp))
    #expect(report.files[0].extraOutputs == [png.standardizedFileURL])
}

@Test func forkWithLocationPersistsACopy() async throws {
    let tmp = try TempDir()
    let png = try tmp.file("a.png")
    let report = await runner(Recorder()).run(steps: [.fork(location: .path("keep/%f-orig")), .optimise()], on: [png], options: options(tmp))
    #expect(tmp.exists("keep/a-orig.png"))
    #expect(report.files[0].finalFile?.lastPathComponent == "a.png")
}

// MARK: - Scripts, Shortcuts, host

@Test func scriptsNeedPermission() async throws {
    let tmp = try TempDir()
    let png = try tmp.file("a.png")
    let report = await runner(Recorder()).run(steps: [.runScript(code: "true"), .optimise()], on: [png], options: options(tmp))
    #expect(report.files[0].status == .failed)
    #expect(report.files[0].error?.contains("Not permitted") == true)
    #expect(report.files[0].log.count == 1)
}

@Test func scriptGetsTheFileAndCanHandOnAnother() async throws {
    let tmp = try TempDir()
    let png = try tmp.file("a.png")
    let real = PipelineRunner(engine: FakeEngine(recorder: Recorder()), inspector: FakeInspector(), now: { fixedDate })
    var opts = options(tmp, scripts: true)
    opts.binDirectory = URL(fileURLWithPath: "/opt/esclop-bin")
    let code = #"[ "$ESCLOP_BIN" = /opt/esclop-bin ] && [ "$ESCLOP_INPUT_FILE" = "$1" ] && cp "$1" "${1:r}-copy.png" && echo "${1:r}-copy.png""#
    let report = await real.run(steps: [.runScript(code: code)], on: [png], options: opts)
    #expect(report.files[0].status == .completed, "\(report.files[0].log)")
    #expect(report.files[0].finalFile?.lastPathComponent == "a-copy.png")

    let failing = await real.run(steps: [.runScript(code: "echo nope >&2; exit 3")], on: [png], options: opts)
    #expect(failing.files[0].status == .failed)
    #expect(failing.files[0].error?.contains("nope") == true)
}

@Test func shortcutsRunThroughTheShortcutsCommand() async throws {
    let tmp = try TempDir()
    let png = try tmp.file("a.png")
    let rec = Recorder()
    let report = await runner(rec).run(steps: [.runShortcut(name: "Resize for Web")], on: [png], options: options(tmp))
    #expect(rec.calls == ["shortcuts run Resize for Web --input-path a.png --output-path a.png"])
    #expect(report.files[0].finalFile?.path.hasPrefix(tmp.url.appendingPathComponent("tmp").path) == true)
}

@Test func appStepsAreSkippedWithoutTheApp() async throws {
    let tmp = try TempDir()
    let png = try tmp.file("a.png")
    let steps: [PipelineStep] = [.copyToClipboard(format: .markdown), .shelveWith(app: "yoink"), .uploadWith(app: "dropshare"), .copyLinkForSending(), .openWith(app: "Preview")]
    let report = await runner(Recorder()).run(steps: steps, on: [png], options: options(tmp))
    #expect(report.files[0].status == .completed)
    #expect(report.files[0].log.allSatisfy { $0.outcome == .skipped && $0.message == "needs the esclop app" })

    let rec = Recorder()
    _ = await runner(rec, host: RecordingHost(recorder: rec)).run(steps: [.copyToClipboard(relativeTo: "%P")], on: [png], options: options(tmp))
    #expect(rec.calls == [#"host copyToClipboard(format: EsclopPipelines.ClipboardFormat.path, relativeTo: Optional("\#(tmp.url.path)")) a.png"#])
}

@Test func clipboardTextForPathsAndMarkdown() {
    let file = URL(fileURLWithPath: "/blog/img/my cat.png")
    #expect(clipboardText(file: file, format: .path, relativeTo: nil) == "/blog/img/my cat.png")
    #expect(clipboardText(file: file, format: .path, relativeTo: "/blog") == "img/my cat.png")
    #expect(clipboardText(file: file, format: .markdown, relativeTo: "/blog/") == "![my cat](img/my%20cat.png)")
}

// MARK: - Media operations and fallbacks

@Test func mediaOperationsGoToTheEngine() async throws {
    let tmp = try TempDir()
    let m4a = try tmp.file("song.m4a"), mov = try tmp.file("clip.mov"), logo = try tmp.file("logo.png")
    let rec = Recorder()
    _ = await runner(rec).run(steps: [.lowerBitrate(kbps: 96), .normalize(lufs: -14)], on: [m4a], options: options(tmp))
    _ = await runner(rec).run(steps: [.capFps(fps: 24), .watermark(image: "%P/logo.png", position: .topLeft)], on: [mov], options: options(tmp))
    #expect(rec.calls == [
        "lowerBitrate(song.m4a, inPlace, 96)",
        "normalize(song.m4a, inPlace, -14.0)",
        "capFps(clip.mov, inPlace, 24)",
        "watermark(clip.mov, inPlace, \(logo.lastPathComponent) topLeft 1.0 0.15)",
    ])
}

@Test func extractPagesKeepsThePdfUnlessThereIsOnePage() async throws {
    let tmp = try TempDir()
    let pdf = try tmp.file("doc.pdf")
    let many = await runner(Recorder()).run(steps: [.extractPagesAsImages(quality: .high)], on: [pdf], options: options(tmp))
    #expect(many.files[0].extraOutputs.count == 3)
    #expect(many.files[0].finalFile?.lastPathComponent == "doc.pdf")

    var one = FakeEngine(recorder: Recorder())
    one.pages = 1
    let single = await runner(Recorder(), engine: one).run(steps: [.extractPagesAsImages(format: .png), .optimise()], on: [pdf], options: options(tmp))
    #expect(single.files[0].finalFile?.lastPathComponent == "doc-page1.png")
    #expect(single.files[0].log.last?.outcome == .done)
}

@Test func contractOnlyEnginesFallBackOrSayWhatIsMissing() async throws {
    let tmp = try TempDir()
    let mov = try tmp.file("clip.mov")
    let rec = Recorder()
    let engine = ContractOnlyEngine(inner: FakeEngine(recorder: rec))
    let ok = await runner(rec, engine: engine).run(steps: [.removeAudio, .changeSpeed(factor: 2)], on: [mov], options: options(tmp))
    #expect(rec.calls == ["optimise(clip.mov, inPlace, q30, mute)", "optimise(clip.mov, inPlace, q30, speed 2.0)"])
    #expect(ok.files[0].status == .completed)
    let missing = await runner(rec, engine: engine).run(steps: [.capFps(fps: 30)], on: [mov], options: options(tmp))
    #expect(missing.files[0].status == .failed)
    #expect(missing.files[0].error?.contains("capFps") == true)
}

@Test func unavailableEngineFailsCleanly() async throws {
    let tmp = try TempDir()
    let png = try tmp.file("a.png")
    let report = await runner(Recorder(), engine: UnavailableEngine()).run(steps: [.optimise()], on: [png], options: options(tmp))
    #expect(report.files[0].status == .failed)
    #expect(report.files[0].error == EsclopError.toolMissing("engine").description)
}

// MARK: - Errors and edge cases

@Test func aFailureStopsThatFileOnly() async throws {
    let tmp = try TempDir()
    let a = try tmp.file("a.png"), b = try tmp.file("b.txt"), missing = tmp.url.appendingPathComponent("gone.png")
    let rec = Recorder()
    var engine = FakeEngine(recorder: rec)
    engine.failOn = "downscale"
    let report = await runner(rec, engine: engine).run(steps: [.downscale(factor: 0.5), .optimise()], on: [a, b, missing], options: options(tmp))
    #expect(report.files.map(\.status) == [.failed, .unsupported, .failed])
    #expect(report.files[0].log.count == 1)
    #expect(report.files[0].error?.contains("boom") == true)
    #expect(!report.succeeded)
}

@Test func alreadySmallerIsNotAFailure() async throws {
    let tmp = try TempDir()
    let png = try tmp.file("a.png")
    var engine = FakeEngine(recorder: Recorder())
    engine.alreadySmallerOn = "optimise"
    let report = await runner(Recorder(), engine: engine).run(steps: [.optimise(), .convert(to: "webp")], on: [png], options: options(tmp))
    #expect(report.files[0].log.map(\.outcome) == [.unchanged, .done])
    #expect(report.files[0].status == .completed)
}

@Test func deleteNeedsPermissionAndNeverTouchesFolders() async throws {
    let tmp = try TempDir()
    let png = try tmp.file("a.png")
    var opts = options(tmp)
    opts.allowDelete = false
    let denied = await runner(Recorder()).run(steps: [.delete(path: "sourceFile")], on: [png], options: opts)
    #expect(denied.files[0].status == .failed)
    #expect(FileManager.default.fileExists(atPath: png.path))

    try FileManager.default.createDirectory(at: tmp.url.appendingPathComponent("folder"), withIntermediateDirectories: true)
    let folder = await runner(Recorder()).run(steps: [.delete(path: "%P/folder")], on: [png], options: options(tmp))
    #expect(folder.files[0].status == .failed)
    #expect(tmp.exists("folder"))

    let nothing = await runner(Recorder()).run(steps: [.delete(path: "%P/none.png")], on: [png], options: options(tmp))
    #expect(nothing.files[0].log[0].outcome == .unchanged)
}

@Test func progressIsReported() async throws {
    let tmp = try TempDir()
    let a = try tmp.file("a.png"), b = try tmp.file("b.png")
    let seen = Recorder()
    _ = await runner(Recorder()).run(steps: [.optimise(), .stripExif], on: [a, b], options: options(tmp)) { p in
        seen.record("\(p.fileIndex)/\(p.fileCount) \(p.stepIndex)/\(p.stepCount) \(p.step) \(p.stepFraction)")
    }
    #expect(seen.calls == [
        "0/2 0/2 optimise 0.0", "0/2 0/2 optimise 0.5", "0/2 1/2 stripExif 0.0",
        "1/2 0/2 optimise 0.0", "1/2 0/2 optimise 0.5", "1/2 1/2 stripExif 0.0",
    ])
}

@Test func reportEncodesAsJSON() async throws {
    let tmp = try TempDir()
    let png = try tmp.file("a.png")
    let report = await runner(Recorder()).run(steps: [.optimise()], on: [png], options: options(tmp))
    let data = try JSONEncoder().encode(report)
    let back = try JSONDecoder().decode(PipelineRunReport.self, from: data)
    #expect(back.files[0].log == report.files[0].log)
}
