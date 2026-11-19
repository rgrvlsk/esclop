// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import EsclopCore
@testable import EsclopOptimisers
import Foundation
import PDFKit
import Testing
import UniformTypeIdentifiers

@Suite(.enabled(if: Harness.hasFFmpeg)) struct VideoEngineTests {
    @Test func optimiseMakesASmallerH264File() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let mov = world.file("recording.mov")
        try await Fixture.video(mov)
        let result = try await world.engine.optimise(mov, request: world.request(mov), progress: { _ in })
        #expect(result.output == mov)
        #expect(result.bytesAfter < result.bytesBefore)
        let info = try await Inspect.media(mov)
        #expect(info.video?.codec == "h264")
        #expect(info.audio != nil)
        #expect(abs((info.duration ?? 0) - 1) < 0.2)
        #expect(result.backup != nil)
    }

    /// A damaged video says so plainly: no ffprobe output, no path (UI check, F3).
    @Test func aDamagedVideoIsUnreadable() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let broken = world.file("broken.mov")
        try Data("not a movie".utf8).write(to: broken)
        await #expect(throws: EsclopError.unreadable(kind: .video)) {
            _ = try await world.engine.optimise(broken, request: world.request(broken), progress: { _ in })
        }
    }

    @Test func convertsBetweenContainersAndCodecs() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let mov = world.file("clip.mov")
        try await Fixture.video(mov)

        let mp4 = try await world.engine.convert(mov, to: .mp4, request: world.request(mov, location: .sameFolder), progress: { _ in })
        #expect(UTType(filenameExtension: mp4.output.pathExtension)?.conforms(to: .mpeg4Movie) == true)
        #expect(try await Inspect.media(mp4.output).video?.codec == "h264")

        let hevc = try await world.engine.convert(mov, to: .hevc, request: world.request(mov, location: .temporary), progress: { _ in })
        #expect(try await Inspect.media(hevc.output).video?.codec == "hevc")

        let webm = try await world.engine.convert(mov, to: .webm, request: world.request(mov, location: .sameFolder), progress: { _ in })
        let webmInfo = try await Inspect.media(webm.output)
        #expect(webmInfo.video?.codec == "vp9")
        #expect(webmInfo.audio?.codec == "opus")

        let av1 = try await world.engine.convert(mov, to: .av1, request: world.request(mov, location: .temporary), progress: { _ in })
        #expect(try await Inspect.media(av1.output).video?.codec == "av1")
    }

    @Test func downscaleCropSpeedFrameRateAndAudio() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let mov = world.file("edit.mov")
        try await Fixture.video(mov, seconds: 2, width: 640, height: 480, fps: 60)

        let half = try await world.engine.downscale(mov, factor: 0.5, request: world.request(mov, location: .temporary), progress: { _ in })
        let halfInfo = try await Inspect.media(half.output)
        #expect(halfInfo.video?.width == 320 && halfInfo.video?.height == 240)

        let square = try await world.engine.crop(mov, to: CropSize(longEdge: 200, aspectRatio: "1:1"), request: world.request(mov, location: .temporary), progress: { _ in })
        let squareInfo = try await Inspect.media(square.output)
        #expect(squareInfo.video?.width == 200 && squareInfo.video?.height == 200)

        let fast = try await world.engine.changeSpeed(mov, factor: 2, request: world.request(mov, location: .temporary), progress: { _ in })
        #expect(abs((try await Inspect.media(fast.output).duration ?? 0) - 1) < 0.2)

        let capped = try await world.engine.capFrameRate(mov, fps: 24, request: world.request(mov, location: .temporary), progress: { _ in })
        #expect((try await Inspect.media(capped.output).video?.fps ?? 99) <= 24.5)

        let muted = try await world.engine.removeAudio(mov, request: world.request(mov, location: .temporary))
        #expect(try await Inspect.media(muted.output).audio == nil)

        var request = world.request(mov, location: .temporary)
        request.removeAudio = true
        let mutedOptimised = try await world.engine.optimise(mov, request: request, progress: { _ in })
        #expect(try await Inspect.media(mutedOptimised.output).audio == nil)

        let lower = try await world.engine.lowerBitrate(mov, kbps: 300, request: world.request(mov, location: .temporary), progress: { _ in })
        #expect(lower.bytesAfter < lower.bytesBefore)
    }

    @Test func fitUnderSize() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let mov = world.file("fit.mov")
        try await Fixture.video(mov, seconds: 2, width: 640, height: 480)
        let target = 120_000
        let result = try await world.engine.fit(mov, underBytes: target, request: world.request(mov, location: .temporary), progress: { _ in })
        #expect(result.bytesAfter <= target)
    }

    @Test func videoToGIF() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let mov = world.file("loop.mov")
        try await Fixture.video(mov, audio: false)
        let result = try await world.engine.convert(mov, to: .gif, request: world.request(mov, location: .sameFolder), progress: { _ in })
        #expect(Inspect.type(result.output) == .gif)
        #expect((ImageInfo.probe(result.output)?.frameCount ?? 0) > 5)
        #expect(result.kind == .image)
    }

    @Test func animatedGIFToMP4() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let gif = world.file("anim.gif")
        try Fixture.gif(gif, frames: 6, size: 95)
        let result = try await world.engine.convert(gif, to: .mp4, request: world.request(gif, location: .sameFolder), progress: { _ in })
        let info = try await Inspect.media(result.output)
        #expect(info.video?.codec == "h264")
        #expect(info.video?.width == 94)
    }

    @Test func stripMetadataAndProgress() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let mov = world.file("meta.mov")
        try await Fixture.video(mov)
        let stripped = try await world.engine.stripMetadata(mov, request: world.request(mov, location: .temporary))
        #expect(try await Inspect.media(stripped.output).video != nil)

        let fractions = Fractions()
        _ = try await world.engine.optimise(mov, request: world.request(mov, location: .temporary), progress: { fractions.add($0.fraction) })
        #expect(fractions.values.first == 0)
        #expect(fractions.values.last == 1)
    }

    @Test func watermarkAVideo() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let mov = world.file("mark.mov")
        let mark = world.file("logo.png")
        try await Fixture.video(mov)
        try Fixture.png(mark, width: 64, height: 32, alpha: true)
        let result = try await world.engine.watermark(mov, image: mark, position: .bottomRight, opacity: 0.7, scale: 0.2, request: world.request(mov, location: .temporary), progress: { _ in })
        let info = try await Inspect.media(result.output)
        #expect(info.video?.width == 320)
        #expect(abs((info.duration ?? 0) - 1) < 0.2)
    }
}

@Suite(.enabled(if: Harness.hasFFmpeg)) struct AudioEngineTests {
    @Test func wavBecomesASmallerMP3() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let wav = world.file("voice.wav")
        try await Fixture.wav(wav)
        let result = try await world.engine.optimise(wav, request: world.request(wav), progress: { _ in })
        #expect(result.output.pathExtension == "mp3")
        #expect(result.bytesAfter < result.bytesBefore / 4)
        #expect(!FileManager.default.fileExists(atPath: wav.path))
        #expect(try await Inspect.media(result.output).audio?.codec == "mp3")
        #expect(result.kind == .audio)
    }

    @Test func convertAndFitAndLoudness() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let wav = world.file("song.wav")
        try await Fixture.wav(wav, seconds: 4)

        let m4a = try await world.engine.convert(wav, to: .m4a, request: world.request(wav, location: .sameFolder), progress: { _ in })
        #expect(m4a.output.pathExtension == "m4a")
        #expect(try await Inspect.media(m4a.output).audio?.codec == "aac")

        let opus = try await world.engine.convert(wav, to: .opus, request: world.request(wav, location: .sameFolder), progress: { _ in })
        #expect(try await Inspect.media(opus.output).audio?.codec == "opus")

        let target = 40_000
        let fit = try await world.engine.fit(wav, underBytes: target, request: world.request(wav, location: .temporary), progress: { _ in })
        #expect(fit.bytesAfter <= target)

        let loud = try await world.engine.normalizeLoudness(wav, lufs: -16, request: world.request(wav, location: .temporary), progress: { _ in })
        #expect(loud.steps.contains("Normalised loudness to -16 LUFS"))

        let fast = try await world.engine.changeSpeed(wav, factor: 2, request: world.request(wav, location: .temporary), progress: { _ in })
        #expect(abs((try await Inspect.media(fast.output).duration ?? 0) - 2) < 0.2)
    }
}

@Suite(.enabled(if: Harness.hasRealEngine)) struct PDFEngineTests {
    @Test func optimiseDownsamplesImages() async throws {
        let world = try await TestWorld(realEngine: true)
        defer { Task { await world.finish() } }
        let pdf = world.file("scan.pdf")
        try Fixture.pdf(pdf)
        var request = world.request(pdf)
        request.pdfDPI = 100
        let result = try await world.engine.optimise(pdf, request: request, progress: { _ in })
        #expect(result.bytesAfter < result.bytesBefore)
        #expect(PDFDocument(url: pdf)?.pageCount == 1)
        #expect(result.backup != nil)
        #expect(result.steps.contains { $0.contains("100 dpi") })
    }

    @Test func defaultOptimisationProducesAValidSmallerPDF() async throws {
        let world = try await TestWorld(realEngine: true)
        defer { Task { await world.finish() } }
        let pdf = world.file("default.pdf")
        try Fixture.pdf(pdf, pages: 2)
        let result = try await world.engine.optimise(pdf, request: world.request(pdf, location: .sameFolder), progress: { _ in })
        #expect(result.bytesAfter < result.bytesBefore)
        #expect(PDFDocument(url: result.output)?.pageCount == 2)
    }

    @Test func cropUncropAndPages() async throws {
        let world = try await TestWorld(realEngine: true)
        defer { Task { await world.finish() } }
        let pdf = world.file("page.pdf")
        try Fixture.pdf(pdf)
        let cropped = try await world.engine.cropPDF(pdf, aspectRatio: "1:1", request: world.request(pdf, location: .sameFolder))
        let box = try #require(PDFDocument(url: cropped.output)?.page(at: 0)?.bounds(for: .cropBox))
        #expect(abs(box.width - box.height) < 1)
        #expect(abs(box.width - 612) < 1)

        let uncropped = try await world.engine.uncropPDF(cropped.output, request: world.request(cropped.output, location: .temporary))
        let full = try #require(PDFDocument(url: uncropped.output)?.page(at: 0)?.bounds(for: .cropBox))
        #expect(abs(full.height - 792) < 1)

        let pages = try await world.engine.extractPDFPages(pdf, format: .png, dpi: 72, to: world.file("pages"))
        #expect(pages.count == 1)
        #expect(Inspect.size(pages[0])! == (612, 792))
    }

    @Test func fitWalksDownTheDPIStops() async throws {
        let world = try await TestWorld(realEngine: true)
        defer { Task { await world.finish() } }
        let pdf = world.file("fit.pdf")
        try Fixture.pdf(pdf)
        // The fixture's noise keeps the fidelity gate from taking it much below a quarter at the
        // default setting: 150 and 100 dpi miss this target, 72 dpi meets it.
        let target = Inspect.bytes(pdf) / 4
        let result = try await world.engine.fit(pdf, underBytes: target, request: world.request(pdf, location: .temporary), progress: { _ in })
        #expect(result.bytesAfter <= target)
        #expect(PDFDocument(url: result.output) != nil)
    }

    @Test func dpiStopsAndAdaptiveChoice() {
        #expect(EsclopEngine.pdfDPIStops == [300, 250, 200, 150, 100, 72, 48])
        #expect(PDFResolution.stepDown(from: 300) == 250)
        #expect(PDFResolution.stepDown(from: 48) == 48)
        #expect(PDFResolution.snap(160) == 150)
        #expect(PDFResolution.dropLowOutliers([300, 300, 290, 310, 20]) == [300, 300, 290, 310])
    }
}

@Suite(.serialized) struct ClipboardTests {
    func pasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("dev.esclop.tests.\(UUID().uuidString)"))
    }

    @Test func filesRoundTripAndAreMarked() throws {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let folder = try Harness.folder()
        let png = folder.appendingPathComponent("copied.png")
        try Fixture.png(png)
        Clipboard.write(files: [png], to: board)
        #expect(Clipboard.isOwnWrite(board))
        #expect(Clipboard.read(board) == .files([png.standardizedFileURL]))
        #expect(board.data(forType: .png) != nil)
    }

    @Test func imageDataIsSavedToAFile() throws {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let folder = try Harness.folder()
        let png = folder.appendingPathComponent("pixels.png")
        try Fixture.png(png)
        board.clearContents()
        board.setData(try Data(contentsOf: png), forType: .png)
        let content = Clipboard.read(board)
        guard case let .image(_, type) = content else {
            Issue.record("expected image data, got \(content)")
            return
        }
        #expect(type == .png)
        #expect(!Clipboard.isOwnWrite(board))
        let files = try Clipboard.materialise(content, folder: folder)
        #expect(Inspect.type(files[0]) == .png)
    }

    @Test func copiesInTheSameSecondKeepTheirOwnFiles() throws {
        let folder = try Harness.folder()
        let first = try Clipboard.materialise(.image(Data([1, 2, 3]), .png), folder: folder)[0]
        let second = try Clipboard.materialise(.image(Data([4, 5]), .png), folder: folder)[0]
        #expect(first != second)
        #expect(first.lastPathComponent.hasPrefix("Clipboard "), "the readable name stays")
        #expect(try Data(contentsOf: first) == Data([1, 2, 3]))
        #expect(try Data(contentsOf: second) == Data([4, 5]))
    }

    @Test func pathsAndBase64Text() throws {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let folder = try Harness.folder()
        let png = folder.appendingPathComponent("path.png")
        try Fixture.png(png, width: 8, height: 8)
        board.clearContents()
        board.setString(png.path, forType: .string)
        #expect(Clipboard.read(board) == .path(png))

        let base64 = "data:image/png;base64," + (try Data(contentsOf: png)).base64EncodedString()
        board.clearContents()
        board.setString(base64, forType: .string)
        guard case let .base64Image(data, type) = Clipboard.read(board) else {
            Issue.record("expected base64 image")
            return
        }
        #expect(type == .png)
        #expect(data == (try Data(contentsOf: png)))

        board.clearContents()
        board.setString("just words", forType: .string)
        #expect(Clipboard.read(board) == .empty)
    }
}

@Suite(.enabled(if: Harness.hasFFmpeg)) struct VideoRegressionTests {
    @Test(.timeLimit(.minutes(1))) func watermarkOnASilentVideoFinishes() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let mov = world.file("silent.mov")
        let mark = world.file("logo.png")
        try await Fixture.video(mov, audio: false)
        try Fixture.png(mark, width: 64, height: 32, alpha: true)
        let result = try await world.engine.watermark(mov, image: mark, request: world.request(mov, location: .temporary), progress: { _ in })
        #expect(abs((try await Inspect.media(result.output).duration ?? 0) - 1) < 0.2)
    }

    @Test func gifCropsToTheAspectRatio() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let mov = world.file("wide.mov")
        try await Fixture.video(mov, width: 320, height: 180, audio: false)
        var request = world.request(mov, location: .temporary)
        request.crop = CropSize(aspectRatio: "1:1")
        let result = try await world.engine.convert(mov, to: .gif, request: request, progress: { _ in })
        let size = try #require(Inspect.size(result.output))
        #expect(size.0 == size.1)
    }
}

/// Video and audio keep what they carry (HC-10, HC-21). Fixtures use only what the bundled ffmpeg
/// can write; subtitles and chapters need Homebrew's readers (srt, ffmetadata) and are checked there.
@Suite(.enabled(if: Harness.hasFFmpeg)) struct MediaKeepsWhatItCarriesTests {
    func ffprobe(_ url: URL) async throws -> JSONValue {
        let result = try await ProcessRunner.run(.ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", "-show_chapters", url.path])
        return JSONValue(parsing: result.stdoutString)
    }

    func ffmpegLists(_ list: String, _ name: String) async -> Bool {
        let output = (try? await ProcessRunner.run(.ffmpeg, ["-hide_banner", list]))?.stdoutString ?? ""
        return output.split(separator: "\n").contains { $0.split(separator: " ").dropFirst().first == Substring(name) }
    }

    /// An MKV with a video, two audio tracks (cat, eng), two SubRip subtitles (cat, spa) and two
    /// chapters, all with language tags, and a title.
    func richMKV(_ world: TestWorld, ffmpeg: URL) async throws -> URL {
        let mkv = world.file("film.mkv")
        let srt = world.file("film.srt"), chapters = world.file("film.txt")
        try "1\n00:00:00,000 --> 00:00:01,500\nHola\n".write(to: srt, atomically: true, encoding: .utf8)
        try ";FFMETADATA1\ntitle=Holiday\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=Intro\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=1000\nEND=2000\ntitle=Main\n"
            .write(to: chapters, atomically: true, encoding: .utf8)
        try await ProcessRunner.run(executable: ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=d=2:s=320x240:r=30",
            "-f", "lavfi", "-i", "sine=d=2", "-f", "lavfi", "-i", "sine=f=660:d=2", "-i", srt.path, "-i", srt.path, "-i", chapters.path,
            "-map", "0", "-map", "1", "-map", "2", "-map", "3", "-map", "4", "-map_metadata", "5", "-map_chapters", "5",
            "-c:v", "mjpeg", "-q:v", "2", "-pix_fmt", "yuvj420p", "-c:a", "aac", "-c:s", "copy",
            "-metadata:s:a:0", "language=cat", "-metadata:s:a:1", "language=eng",
            "-metadata:s:s:0", "language=cat", "-metadata:s:s:1", "language=spa", mkv.path,
        ])
        return mkv
    }

    func languages(_ json: JSONValue, _ type: String) -> [String?] {
        (json["streams"]?.arrayValue ?? []).filter { $0["codec_type"]?.stringValue == type }.map { $0["tags"]?["language"]?.stringValue }
    }

    func chapterTitles(_ json: JSONValue) -> [String] {
        json["chapters"]?.arrayValue?.compactMap { $0["tags"]?["title"]?.stringValue } ?? []
    }

    /// `strip` removes what describes the person and nothing else: every track, language and
    /// chapter stays (it used to keep only video and audio).
    @Test func strippingAVideoKeepsEveryTrackLanguageAndChapter() async throws {
        guard let ffmpeg = await Fixture.richFFmpeg() else { return }
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let mkv = try await richMKV(world, ffmpeg: ffmpeg)
        let result = try await world.engine.stripMetadata(mkv, request: world.request(mkv, location: .temporary))
        let json = try await ffprobe(result.output)
        #expect(languages(json, "audio") == ["cat", "eng"])
        #expect(languages(json, "subtitle") == ["cat", "spa"])
        #expect(chapterTitles(json) == ["Intro", "Main"])
        #expect(json["format"]?["tags"]?["title"] == nil)
    }

    /// MKV to MP4 rewrites text subtitles as mov_text instead of dropping them.
    @Test func convertingToMP4KeepsTextSubtitles() async throws {
        guard let ffmpeg = await Fixture.richFFmpeg() else { return }
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let mkv = try await richMKV(world, ffmpeg: ffmpeg)
        let result = try await world.engine.convert(mkv, to: .mp4, request: world.request(mkv, location: .temporary), progress: { _ in })
        let json = try await ffprobe(result.output)
        let subtitles = (json["streams"]?.arrayValue ?? []).filter { $0["codec_type"]?.stringValue == "subtitle" }
        #expect(subtitles.map { $0["codec_name"]?.stringValue } == ["mov_text", "mov_text"])
        #expect(languages(json, "subtitle") == ["cat", "spa"])
        #expect(!result.steps.contains { $0.hasPrefix("Left out") })
    }

    /// Chapter times do not follow a speed change, so the chapters go, and a step says so.
    @Test func aSpeedChangeLeavesOutTheChaptersAndSaysSo() async throws {
        guard let ffmpeg = await Fixture.richFFmpeg() else { return }
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let mkv = try await richMKV(world, ffmpeg: ffmpeg)
        var request = world.request(mkv, location: .temporary)
        request.playbackSpeed = 2
        let result = try await world.engine.optimise(mkv, request: request, progress: { _ in })
        #expect(chapterTitles(try await ffprobe(result.output)).isEmpty)
        #expect(result.steps.contains("Left out 2 chapters: their times do not follow a speed change"))
    }

    @Test func optimisingKeepsEveryTrackLanguageSubtitleAndChapter() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let mp4 = world.file("tracks.mp4")
        let richFFmpeg = await Fixture.richFFmpeg()
        let rich = richFFmpeg != nil
        var args = ["-hide_banner", "-loglevel", "error", "-y",
                    "-f", "lavfi", "-i", "testsrc2=d=2:s=320x240:r=30", "-f", "lavfi", "-i", "color=c=blue:d=2:s=160x120:r=30",
                    "-f", "lavfi", "-i", "sine=d=2"]
        if rich {
            let srt = world.file("sub.srt"), chapters = world.file("chapters.txt")
            try "1\n00:00:00,000 --> 00:00:01,500\nHola\n".write(to: srt, atomically: true, encoding: .utf8)
            try ";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=Intro\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=1000\nEND=2000\ntitle=Main\n"
                .write(to: chapters, atomically: true, encoding: .utf8)
            args += ["-i", srt.path, "-i", chapters.path, "-map", "3", "-map_chapters", "4", "-c:s", "mov_text"]
        }
        args += ["-map", "0", "-map", "1", "-map", "2", "-c:v", "mjpeg", "-q:v", "2", "-pix_fmt", "yuvj420p", "-c:a", "aac",
                 "-metadata", "title=Holiday", "-metadata:s:a:0", "language=cat", mp4.path]
        if let richFFmpeg { try await ProcessRunner.run(executable: richFFmpeg, arguments: args) } else { try await ProcessRunner.run(.ffmpeg, args) }

        var request = world.request(mp4)
        request.stripMetadata = true
        let result = try await world.engine.optimise(mp4, request: request, progress: { _ in })
        let json = try await ffprobe(result.output)
        let streams = json["streams"]?.arrayValue ?? []
        let video = streams.filter { $0["codec_type"]?.stringValue == "video" }
        #expect(video.map { $0["width"]?.intValue } == [320, 160])
        let audio = streams.filter { $0["codec_type"]?.stringValue == "audio" }
        #expect(audio.map { $0["tags"]?["language"]?.stringValue } == ["cat"])
        #expect(json["format"]?["tags"]?["title"] == nil)
        if rich {
            #expect(streams.contains { $0["codec_name"]?.stringValue == "mov_text" })
            #expect(json["chapters"]?.arrayValue?.compactMap { $0["tags"]?["title"]?.stringValue } == ["Intro", "Main"])
        }
    }

    @Test func aCropLargerThanTheVideoDoesNotUpscale() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let mov = world.file("small.mov")
        try await Fixture.video(mov, width: 640, height: 360, audio: false)
        let result = try await world.engine.crop(mov, to: CropSize(width: 2560, height: 1440), request: world.request(mov, location: .temporary), progress: { _ in })
        let video = try await Inspect.media(result.output).video
        #expect(video?.width == 640)
        #expect(video?.height == 360)
        #expect(result.steps.contains("Not enlarged to 2560x1440; kept 640x360"))
        // An aspect crop whose width rounds odd (640x360 at 9:16 is 203x360) is no enlargement.
        let portrait = try await world.engine.crop(mov, to: CropSize(aspectRatio: "9:16"), request: world.request(mov, location: .temporary), progress: { _ in })
        #expect(!portrait.steps.contains { $0.hasPrefix("Not enlarged") }, "\(portrait.steps)")
    }

    @Test func gifFollowsThePlaybackSpeedAndIsNeverFittedAsAnMP4() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let mov = world.file("clip.mov")
        try await Fixture.video(mov, seconds: 2, audio: false)
        var request = world.request(mov, location: .temporary)
        request.playbackSpeed = 2
        let gif = try await world.engine.convert(mov, to: .gif, request: request, progress: { _ in })
        let seconds = try await ffprobe(gif.output)["format"]?["duration"]?.stringValue.flatMap(Double.init) ?? 0
        #expect(abs(seconds - 1) < 0.2)

        var fit = world.request(mov, location: .temporary)
        fit.format = .gif
        await #expect(throws: EsclopError.self) { try await world.engine.fit(mov, underBytes: 50_000, request: fit, progress: { _ in }) }
    }

    @Test func losslessAudioKeepsItsDepthAndRateAndCodecChangesAreNamed() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let alac = world.file("album.m4a")
        let noise = world.file("noise.wav")
        try Fixture.noiseWAV(noise)
        try await ProcessRunner.run(.ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", noise.path, "-c:a", "alac_at", alac.path])
        // Apple Lossless stays lossless unless the Convert to AAC list names it.
        await #expect(throws: EsclopError.alreadySmaller) { try await world.engine.optimise(alac, request: world.request(alac), progress: { _ in }) }
        #expect(try await Inspect.media(alac).audio?.codec == "alac")
        try EsclopSettings.formatsToConvertToAAC.set(["aiff", "aif", "flac", "alac"], in: world.settings)
        let aac = try await world.engine.optimise(alac, request: world.request(alac), progress: { _ in })
        #expect(aac.steps.contains("Converted Apple Lossless to AAC"))
        #expect(try await Inspect.media(aac.output).audio?.codec == "aac")

        let flac = world.file("master.flac")
        try await ProcessRunner.run(.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=d=2:sample_rate=96000", "-c:a", "flac", "-sample_fmt", "s32", flac.path,
        ])
        let wav = try await world.engine.convert(flac, to: .wav, request: world.request(flac, location: .temporary), progress: { _ in })
        let wavAudio = try await Inspect.media(wav.output).audio
        #expect(wavAudio?.codec == "pcm_s24le")
        #expect(wavAudio?.sampleRate == 96000)

        let aiff = try await world.engine.convert(flac, to: .aiff, request: world.request(flac, location: .temporary), progress: { _ in })
        #expect(aiff.output.pathExtension == "aiff")
        let aiffCodec = try await Inspect.media(aiff.output).audio?.codec
        #expect(aiffCodec == "pcm_s24be" || aiff.steps.contains { $0.hasPrefix("Reduced to 16 bits") })

        var aggressive = world.request(flac, location: .temporary)
        aggressive.quality = .aggressive
        let adpcm = try await world.engine.convert(flac, to: .wav, request: aggressive, progress: { _ in })
        #expect(adpcm.steps.contains("Encoded as IMA ADPCM, which is lossy"))
    }

    /// A song keeps its title and artist on a plain optimise, whatever the strip setting says;
    /// only an explicit strip removes them.
    @Test func songsKeepTheirTagsUnlessStripIsAsked() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let mp3 = world.file("song.mp3")
        let noise = world.file("noise.wav")
        try Fixture.noiseWAV(noise)
        try await ProcessRunner.run(.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y", "-i", noise.path,
            "-c:a", "libmp3lame", "-b:a", "320k", "-metadata", "title=Cançó", "-metadata", "artist=Grup", mp3.path,
        ])
        try EsclopSettings.stripMetadata.set(true, in: world.settings)
        let kept = try await world.engine.optimise(mp3, request: world.request(mp3, location: .temporary), progress: { _ in })
        #expect(try await ffprobe(kept.output)["format"]?["tags"]?["title"]?.stringValue == "Cançó")
        #expect(kept.steps.contains { $0.hasPrefix("Encoded VBR, about ") })

        var strip = world.request(mp3, location: .temporary)
        strip.stripMetadata = true
        let stripped = try await world.engine.optimise(mp3, request: strip, progress: { _ in })
        #expect(try await ffprobe(stripped.output)["format"]?["tags"]?["title"] == nil)
    }

    /// Audio downscale scales the source's bitrate (it used to ignore the factor).
    @Test func audioDownscaleScalesTheBitrate() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let m4a = world.file("talk.m4a")
        let noise = world.file("noise.wav")
        try Fixture.noiseWAV(noise)
        try await ProcessRunner.run(.ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", noise.path, "-c:a", "aac", "-b:a", "256k", m4a.path])
        let input = try #require(try await Inspect.media(m4a).audio?.bitrate)
        let result = try await world.engine.downscale(m4a, factor: 0.25, request: world.request(m4a, location: .temporary), progress: { _ in })
        let kbps = try #require(result.steps.compactMap { step -> Int? in
            guard step.hasPrefix("Encoded at ") else { return nil }
            return Int(step.dropFirst("Encoded at ".count).prefix { $0.isNumber })
        }.first)
        #expect(kbps <= max(56, input / 4))
        #expect(kbps >= 56, "never under AAC's lowest step")
    }
}
