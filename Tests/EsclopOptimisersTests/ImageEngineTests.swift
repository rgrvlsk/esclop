// SPDX-License-Identifier: GPL-3.0-or-later
import EsclopCore
@testable import EsclopOptimisers
import Foundation
import CoreImage
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite struct ImageEngineTests {
    @Test func optimisePNGInPlaceKeepsABackupAndMarksTheFile() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let png = world.file("shot.png")
        try Fixture.png(png)
        let before = Inspect.bytes(png)

        let result = try await world.engine.optimise(png, request: world.request(png), progress: { _ in })
        #expect(result.output == png)
        #expect(result.bytesBefore == before)
        #expect(result.bytesAfter < before)
        #expect(Inspect.bytes(png) == result.bytesAfter)
        #expect(Inspect.type(png) == .png)
        #expect(OptimisedMark.isMarked(png))
        let backup = try #require(result.backup)
        #expect(Inspect.bytes(backup) == before)
        #expect(world.backups.entries().first?.output?.path == png.standardizedFileURL.path)
        #expect(result.kind == .image)
        #expect(result.width == 320 && result.height == 240)

        // Undo.
        try world.backups.restore(try #require(world.backups.entry(forBackup: backup)))
        #expect(Inspect.bytes(png) == before)
    }

    @Test func alreadyOptimisedFilesAreLeftAlone() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let png = world.file("twice.png")
        try Fixture.png(png)
        _ = try await world.engine.optimise(png, request: world.request(png), progress: { _ in })
        let once = try Data(contentsOf: png)
        await #expect(throws: EsclopError.alreadySmaller) {
            try await world.engine.optimise(png, request: world.request(png), progress: { _ in })
        }
        #expect(try Data(contentsOf: png) == once)
        #expect(world.backups.entries().count == 1)
    }

    @Test func optimiseJPEGStripsLocationButKeepsOrientation() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let jpeg = world.file("photo.jpg")
        try Fixture.jpeg(jpeg, orientation: 6)
        #expect(Inspect.properties(jpeg)[kCGImagePropertyGPSDictionary] != nil)

        let result = try await world.engine.optimise(jpeg, request: world.request(jpeg, location: .sameFolder), progress: { _ in })
        #expect(result.output.lastPathComponent == "photo-optimised.jpg")
        #expect(result.bytesAfter < result.bytesBefore)
        #expect(result.backup == nil)
        let properties = Inspect.properties(result.output)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(properties[kCGImagePropertyOrientation] as? Int == 6)
        // The original is untouched outside in-place mode.
        #expect(Inspect.properties(jpeg)[kCGImagePropertyGPSDictionary] != nil)
    }

    @Test func metadataSurvivesWhenStrippingIsOff() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        try EsclopSettings.stripMetadata.set(false, in: world.settings)
        let jpeg = world.file("keep.jpg")
        try Fixture.jpeg(jpeg)
        let result = try await world.engine.optimise(jpeg, request: world.request(jpeg), progress: { _ in })
        #expect(Inspect.properties(result.output)[kCGImagePropertyGPSDictionary] != nil)
    }

    @Test func convertProducesTheRightType() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let png = world.file("logo.png")
        try Fixture.png(png)

        let jpeg = try await world.engine.convert(png, to: .jpeg, request: world.request(png, location: .sameFolder), progress: { _ in })
        #expect(jpeg.output.pathExtension == "jpeg")
        #expect(Inspect.type(jpeg.output) == .jpeg)
        #expect(FileManager.default.fileExists(atPath: png.path))

        let heic = try await world.engine.convert(png, to: .heic, request: world.request(png, location: .sameFolder), progress: { _ in })
        #expect(Inspect.type(heic.output) == .heic)

        let tiff = try await world.engine.convert(png, to: .tiff, request: world.request(png, location: .temporary), progress: { _ in })
        #expect(Inspect.type(tiff.output) == .tiff)

        let pdf = try await world.engine.convert(png, to: .pdf, request: world.request(png, location: .sameFolder), progress: { _ in })
        #expect(MediaKind.of(pdf.output) == .pdf)
    }

    @Test func convertInPlaceReplacesTheOriginal() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let heic = world.file("phone.heic")
        try Fixture.heic(heic)
        let result = try await world.engine.convert(heic, to: .jpeg, request: world.request(heic), progress: { _ in })
        #expect(result.output.lastPathComponent == "phone.jpeg")
        #expect(Inspect.type(result.output) == .jpeg)
        #expect(!FileManager.default.fileExists(atPath: heic.path))
        let backup = try #require(result.backup)
        #expect(Inspect.type(backup) == .heic)
    }

    @Test func formatsTheEngineCannotWriteFailClearly() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let png = world.file("a.png")
        try Fixture.png(png)
        do {
            _ = try await world.engine.convert(png, to: .webp, request: world.request(png, location: .sameFolder), progress: { _ in })
            Issue.record("the fake engine does not write WebP")
        } catch let EsclopError.unsupportedFile(message) {
            #expect(message.contains("WEBP"))
        }
        #expect(FileManager.default.fileExists(atPath: png.path))
    }

    @Test func automaticOriginsConvertByTheSettingsLists() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        try EsclopSettings.formatsToConvertToJPEG.set(["heic"], in: world.settings)
        let heic = world.file("auto.heic")
        try Fixture.heic(heic)
        let cli = try await world.engine.optimise(heic, request: world.request(heic, location: .sameFolder), progress: { _ in })
        #expect(Inspect.type(cli.output) == .heic)
        let clipboard = try await world.engine.optimise(heic, request: world.request(heic, origin: .clipboard, location: .sameFolder), progress: { _ in })
        #expect(Inspect.type(clipboard.output) == .jpeg)
    }

    @Test func downscaleHalvesTheSize() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let png = world.file("big.png")
        try Fixture.png(png, width: 400, height: 300)
        let result = try await world.engine.downscale(png, factor: 0.5, request: world.request(png, location: .sameFolder), progress: { _ in })
        #expect(Inspect.size(result.output)! == (200, 150))
        #expect(result.steps.contains("Resized to 200x150"))
    }

    @Test func cropToAspectRatioAndLongEdge() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let jpeg = world.file("wide.jpg")
        try Fixture.jpeg(jpeg, width: 400, height: 300)

        let square = try await world.engine.crop(jpeg, to: CropSize(aspectRatio: "1:1"), request: world.request(jpeg, location: .sameFolder), progress: { _ in })
        #expect(Inspect.size(square.output)! == (300, 300))

        let small = try await world.engine.crop(jpeg, to: CropSize(longEdge: 160, aspectRatio: "16:9"), request: world.request(jpeg, location: .sameFolder), progress: { _ in })
        #expect(Inspect.size(small.output)! == (160, 90))

        let smart = try await world.engine.crop(jpeg, to: CropSize(width: 100, height: 100, smart: true), request: world.request(jpeg, location: .sameFolder), progress: { _ in })
        #expect(Inspect.size(smart.output)! == (100, 100))

        let long = try await world.engine.crop(jpeg, to: CropSize(longEdge: 200), request: world.request(jpeg, location: .sameFolder), progress: { _ in })
        #expect(Inspect.size(long.output)! == (200, 150))
    }

    @Test func freeCropKeepsTheRegionAndScalesIt() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let jpeg = world.file("free.jpg")
        try Fixture.jpeg(jpeg, width: 400, height: 300)
        let region = CropRect(x: 50, y: 40, width: 200, height: 100)

        let kept = try await world.engine.crop(jpeg, to: CropSize(rect: region), request: world.request(jpeg, location: .sameFolder), progress: { _ in })
        #expect(Inspect.size(kept.output)! == (200, 100))

        // A size in pixels scales the region, keeping its shape when only one side is given.
        let scaled = try await world.engine.crop(jpeg, to: CropSize(width: 100, rect: region), request: world.request(jpeg, location: .sameFolder), progress: { _ in })
        #expect(Inspect.size(scaled.output)! == (100, 50))

        // A region running off the picture keeps only what is inside.
        let edge = CropSize(rect: CropRect(x: 300, y: 200, width: 400, height: 400))
        #expect(edge.targetSize(fromWidth: 400, height: 300) == (100, 100))
        #expect(edge.cropsAspect(fromWidth: 400, height: 300))
        #expect(!CropSize(rect: CropRect(x: 0, y: 0, width: 400, height: 300)).cropsAspect(fromWidth: 400, height: 300))
    }

    @Test func orientedPhotosCropInDisplaySpace() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let jpeg = world.file("rotated.jpg")
        try Fixture.jpeg(jpeg, width: 400, height: 300, orientation: 6) // shows as 300x400
        let result = try await world.engine.crop(jpeg, to: CropSize(aspectRatio: "1:2"), request: world.request(jpeg, location: .sameFolder), progress: { _ in })
        #expect(Inspect.size(result.output)! == (200, 400))
    }

    @Test func fitUnderSizeLandsUnderTheTarget() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let jpeg = world.file("fit.jpg")
        try Fixture.jpeg(jpeg, width: 800, height: 600)
        let target = Inspect.bytes(jpeg) / 6
        let result = try await world.engine.fit(jpeg, underBytes: target, request: world.request(jpeg, location: .sameFolder), progress: { _ in })
        #expect(result.bytesAfter <= target)
        #expect(Inspect.bytes(result.output) <= target)
        #expect(result.steps.last?.hasPrefix("Fit under") == true)

        // Already under: nothing to do, the file stays as it is.
        let roomy = try await world.engine.fit(jpeg, underBytes: Inspect.bytes(jpeg) * 2, request: world.request(jpeg), progress: { _ in })
        #expect(roomy.output == jpeg)
        #expect(roomy.bytesAfter == roomy.bytesBefore)

        // Impossible targets fail without touching the file.
        let before = Inspect.bytes(jpeg)
        await #expect(throws: EsclopError.self) {
            try await world.engine.fit(jpeg, underBytes: 200, request: world.request(jpeg), progress: { _ in })
        }
        #expect(Inspect.bytes(jpeg) == before)
    }

    @Test func stripMetadataRemovesGPS() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let jpeg = world.file("gps.jpg")
        try Fixture.jpeg(jpeg)
        let result = try await world.engine.stripMetadata(jpeg, request: world.request(jpeg))
        #expect(Inspect.properties(result.output)[kCGImagePropertyGPSDictionary] == nil)
        #expect(Inspect.type(result.output) == .jpeg)
    }

    @Test func watermarkLandsOnThePicture() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let jpeg = world.file("base.jpg")
        let mark = world.file("mark.png")
        try Fixture.jpeg(jpeg)
        try Fixture.png(mark, width: 64, height: 32, alpha: true)
        let result = try await world.engine.watermark(jpeg, image: mark, position: .topLeft, opacity: 0.5, scale: 0.25, request: world.request(jpeg, location: .sameFolder), progress: { _ in })
        #expect(Inspect.type(result.output) == .jpeg)
        #expect(Inspect.size(result.output)! == (320, 240))
        #expect(result.steps.first == "Added a watermark (topLeft)")
    }

    @Test(.enabled(if: Harness.hasGifsicle)) func animatedGIFsStayAnimated() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let gif = world.file("anim.gif")
        try Fixture.gif(gif, frames: 5, size: 120)
        let result = try await world.engine.optimise(gif, request: world.request(gif, location: .sameFolder), progress: { _ in })
        #expect(ImageInfo.probe(result.output)?.frameCount == 5)
        let half = try await world.engine.downscale(gif, factor: 0.5, request: world.request(gif, location: .sameFolder), progress: { _ in })
        #expect(Inspect.size(half.output)! == (60, 60))
        #expect(ImageInfo.probe(half.output)?.frameCount == 5)
    }

    @Test func agentsMayNotOverwriteOriginalsByDefault() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let png = world.file("agent.png")
        try Fixture.png(png)
        await #expect(throws: EsclopError.self) {
            try await world.engine.optimise(png, request: world.request(png, origin: .mcp), progress: { _ in })
        }
        let elsewhere = try await world.engine.optimise(png, request: world.request(png, origin: .mcp, location: .temporary), progress: { _ in })
        #expect(elsewhere.output != png)
        try EsclopSettings.allowOverwriteOriginals.set(true, in: world.settings)
        let inPlace = try await world.engine.optimise(png, request: world.request(png, origin: .mcp), progress: { _ in })
        #expect(inPlace.output == png)
    }

    @Test func progressGoesFromZeroToOne() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let png = world.file("progress.png")
        try Fixture.png(png)
        let fractions = Fractions()
        _ = try await world.engine.optimise(png, request: world.request(png, location: .temporary), progress: { fractions.add($0.fraction) })
        #expect(fractions.values.first == 0)
        #expect(fractions.values.last == 1)
        #expect(fractions.values.contains(0.5))
    }

    @Test func missingFilesAndUnknownTypes() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let missing = world.file("nope.png")
        await #expect(throws: EsclopError.fileNotFound(missing.path)) {
            try await world.engine.optimise(missing, request: world.request(missing), progress: { _ in })
        }
        let text = world.file("notes.txt")
        try Data("hello".utf8).write(to: text)
        await #expect(throws: EsclopError.unsupportedFile("notes.txt")) {
            try await world.engine.optimise(text, request: world.request(text), progress: { _ in })
        }
        #expect(!world.engine.supports(text))
        #expect(world.engine.supports(world.file("a.heic")))
    }
}

@Suite(.enabled(if: Harness.hasRealEngine)) struct RealEngineTests {
    @Test func everyImageFormatThroughTheRustEngine() async throws {
        let world = try await TestWorld(realEngine: true)
        defer { Task { await world.finish() } }
        let png = world.file("real.png")
        try Fixture.png(png)
        for format in [OutputFormat.png, .jpeg, .webp, .avif] {
            let result = try await world.engine.convert(png, to: format, request: world.request(png, location: .temporary), progress: { _ in })
            #expect(Inspect.type(result.output) == format.utType, "\(format)")
        }
        let fit = try await world.engine.fit(png, underBytes: Inspect.bytes(png) / 4, request: world.request(png, location: .temporary), progress: { _ in })
        #expect(fit.bytesAfter <= Inspect.bytes(png) / 4)
    }
}

@Suite struct HDRTests {
    /// An HDR HEIC with a gain map, made with Core Image (macOS 15+).
    @available(macOS 15, *)
    static func hdrHEIC(_ url: URL) throws {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let bright = CIImage(color: CIColor(red: 3, green: 2.5, blue: 2, colorSpace: space)!).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 120))
        let dark = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4, colorSpace: space)!).cropped(to: CGRect(x: 160, y: 0, width: 160, height: 120))
        let hdr = bright.composited(over: dark).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 120))
        let sdr = hdr.applyingFilter("CIToneMapHeadroom", parameters: ["inputTargetHeadroom": 1.0])
        try CIContext().writeHEIFRepresentation(
            of: sdr, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, options: [.hdrImage: hdr]
        )
    }

    @Test func gainMapsSurviveOptimiseAndResize() async throws {
        guard #available(macOS 15, *) else { return }
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let heic = world.file("hdr.heic")
        try Self.hdrHEIC(heic)
        try #require(ImageInfo.probe(heic)?.hasGainMap == true)

        let same = try await world.engine.convert(heic, to: .jpeg, request: world.request(heic, location: .temporary), progress: { _ in })
        #expect(ImageInfo.probe(same.output)?.hasGainMap == true)
        #expect(same.steps.contains("Kept the HDR gain map"))

        // A flat test image is tiny, so a pure downscale may not shrink it; resizing via crop may grow.
        let half = try await world.engine.crop(heic, to: CropSize(width: 160), request: world.request(heic, location: .temporary), progress: { _ in })
        #expect(ImageInfo.probe(half.output)?.hasGainMap == true)
        #expect(Inspect.size(half.output)! == (160, 60))

        try EsclopSettings.keepHDR.set(false, in: world.settings)
        let sdr = try await world.engine.convert(heic, to: .jpeg, request: world.request(heic, location: .temporary), progress: { _ in })
        #expect(ImageInfo.probe(sdr.output)?.hasGainMap == false)
    }
}

@Suite struct VideoArgumentTests {
    func settings(_ codec: VideoEngine.Codec, container: OutputFormat = .mp4) -> VideoEngine.EncodeSettings {
        VideoEngine.EncodeSettings(
            container: container, codec: codec, factor: 50, videoBitrate: nil, filters: [], fpsCap: nil, speed: nil,
            removeAudio: false, audioBitrate: nil, reencodeAudio: false, strip: true, hdr: nil, width: 1280, height: 720
        )
    }

    @Test func videoToolboxFallsBackToSoftware() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let video = VideoEngine(env: world.engine.env)
        let hardware = video.encoderArgs(settings(.h264VT), softwareFallback: false)
        #expect(hardware.starts(with: ["-c:v", "h264_videotoolbox", "-q:v"]))
        #expect(!hardware.contains("-allow_sw"))
        let software = video.encoderArgs(settings(.h264VT), softwareFallback: true)
        #expect(software.contains("-allow_sw"))
        #expect(software.contains("-b:v"))
        #expect(!software.contains("-q:v"))
        #expect(video.encoderArgs(settings(.hevcVT), softwareFallback: false).contains("hvc1"))
        #expect(video.encoderArgs(settings(.av1), softwareFallback: false).starts(with: ["-c:v", "libsvtav1"]))
        #expect(VideoEngine.atempoChain(0.25) == "atempo=0.5,atempo=0.5000")
        #expect(VideoEngine.atempoChain(2) == "atempo=2.0000")
    }

    @Test func noSoftwareH264WithoutX264() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let video = VideoEngine(env: world.engine.env)
        let request = OptimisationRequest(sources: [], origin: .cli, videoEncoder: .h264Software)
        let stream = MediaInfo.Video(codec: "h264", width: 640, height: 480, fps: 30)
        let codec = try await video.chooseCodec(container: .mp4, request: request, video: stream, keepHDR: true)
        let encoders = await FFmpegCapabilities.shared.encoders(tools: .shared)
        #expect(codec == (encoders.contains("libx264") ? .h264x264 : .h264VT))
        let hdr = MediaInfo.Video(codec: "hevc", width: 640, height: 480, fps: 30, colorTransfer: "smpte2084")
        let hdrCodec = try await video.chooseCodec(container: .mp4, request: OptimisationRequest(sources: [], origin: .cli), video: hdr, keepHDR: true)
        #expect(hdrCodec == .hevcVT)
    }
}

@Suite struct PlacementSafetyTests {
    @Test func fitAlreadyUnderWithATemplateNamingTheSourceLeavesItAlone() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let png = world.file("small.png")
        try Fixture.png(png)
        let bytes = Inspect.bytes(png)
        for template in ["%d/", "%d/%f", png.path] {
            let result = try await world.engine.fit(png, underBytes: bytes * 2, request: world.request(png, location: .path(template)), progress: { _ in })
            #expect(result.output == png)
            #expect(Inspect.bytes(png) == bytes, "template \(template)")
        }
    }

    @Test func templatesThatResolveToTheSourceAreInPlaceWrites() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let png = world.file("same.png")
        try Fixture.png(png)
        let result = try await world.engine.optimise(png, request: world.request(png, location: .path("%d/%f")), progress: { _ in })
        #expect(result.output == png)
        #expect(world.backups.entries().count == 1)
        let again = world.file("agent.png")
        try Fixture.png(again)
        await #expect(throws: EsclopError.notPermitted(ResultWriter.agentOverwriteMessage)) {
            try await world.engine.optimise(again, request: world.request(again, origin: .mcp, location: .path("%d/%f.%e")), progress: { _ in })
        }
    }

    @Test func convertingInPlaceBacksUpTheSiblingItReplaces() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let png = world.file("photo.png")
        let sibling = world.file("photo.jpeg")
        try Fixture.png(png)
        try Data("an unrelated jpeg".utf8).write(to: sibling)
        let result = try await world.engine.convert(png, to: .jpeg, request: world.request(png), progress: { _ in })
        #expect(result.output == sibling)
        let originals = world.backups.entries().map { $0.original.lastPathComponent }.sorted()
        #expect(originals == ["photo.jpeg", "photo.png"])
        let siblingBackup = try #require(world.backups.entries().first { $0.original.lastPathComponent == "photo.jpeg" })
        #expect(try String(contentsOf: siblingBackup.backup, encoding: .utf8) == "an unrelated jpeg")
    }
}
