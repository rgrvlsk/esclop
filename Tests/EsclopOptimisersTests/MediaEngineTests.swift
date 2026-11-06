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

@Suite(.enabled(if: Harness.hasGhostscript)) struct PDFEngineTests {
    @Test func optimiseDownsamplesImages() async throws {
        let world = try await TestWorld()
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
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let pdf = world.file("default.pdf")
        try Fixture.pdf(pdf, pages: 2)
        let result = try await world.engine.optimise(pdf, request: world.request(pdf, location: .sameFolder), progress: { _ in })
        #expect(result.bytesAfter < result.bytesBefore)
        #expect(PDFDocument(url: result.output)?.pageCount == 2)
    }

    @Test func cropUncropAndPages() async throws {
        let world = try await TestWorld()
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
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let pdf = world.file("fit.pdf")
        try Fixture.pdf(pdf)
        let target = Inspect.bytes(pdf) / 5
        let result = try await world.engine.fit(pdf, underBytes: target, request: world.request(pdf, location: .temporary), progress: { _ in })
        #expect(result.bytesAfter <= target)
        #expect(PDFDocument(url: result.output) != nil)
    }

    @Test func dpiStopsAndAdaptiveChoice() {
        #expect(EsclopEngine.pdfDPIStops == [300, 250, 200, 150, 100, 72, 48])
        #expect(Ghostscript.stepDown(from: 300) == 250)
        #expect(Ghostscript.stepDown(from: 48) == 48)
        #expect(Ghostscript.snap(160) == 150)
        #expect(Ghostscript.dropLowOutliers([300, 300, 290, 310, 20]) == [300, 300, 290, 310])
        let args = Ghostscript.arguments(input: "in.pdf", output: "out.pdf", lossy: true, dpi: 72)
        #expect(args.first == "-dSAFER")
        #expect(args.contains("-dColorImageResolution=72"))
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
