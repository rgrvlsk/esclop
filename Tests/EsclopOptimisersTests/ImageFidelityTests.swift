// SPDX-License-Identifier: GPL-3.0-or-later
//
// Images never lose content or metadata: pages, frames, pixels, DPI, colour tags, EXIF and HDR
// gain maps survive, or the file is left as it is with a reason. ImageIO-only cases run on the
// fake engine; the rest need the real Rust engine.

import CoreGraphics
import CoreImage
import EsclopCore
@testable import EsclopOptimisers
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers

extension Fixture {
    /// A TIFF of `pages` different pages, signed by an artist.
    static func tiff(_ url: URL, pages: Int) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, pages, nil) else {
            throw EsclopError.other("tiff destination")
        }
        for index in 0 ..< pages {
            CGImageDestinationAddImage(
                destination, try gradient(width: 200, height: 150, deep: false, alpha: false, phase: Double(index)),
                [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "esclop test"]] as CFDictionary
            )
        }
        guard CGImageDestinationFinalize(destination) else { throw EsclopError.other("tiff write") }
    }

    /// A 300 dpi photo at maximum quality whose EXIF says Adobe RGB the way cameras do
    /// (ColorSpace "uncalibrated", InteroperabilityIndex "R03"). ImageIO writes
    /// neither tag, so its EXIF block is replaced by one made by hand.
    static func printJPEG(_ url: URL) throws {
        try write(gradient(width: 640, height: 480, deep: false, alpha: false, noise: true), to: url, type: .jpeg, properties: [
            kCGImageDestinationLossyCompressionQuality: 1.0, kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 300,
        ])
        func be<T: FixedWidthInteger>(_ value: T) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }
        func entry(_ tag: UInt16, _ type: UInt16, _ count: UInt32, _ value: [UInt8]) -> [UInt8] {
            be(tag) + be(type) + be(count) + value
        }
        let end: [UInt8] = [0, 0, 0, 0]
        // Big-endian TIFF. IFD0 at 8 (4 entries, then two rationals at 62 and 70), EXIF at 78,
        // interoperability at 108.
        var tiff: [UInt8] = Array("MM".utf8) + [0, 42] + be(UInt32(8))
        tiff += be(UInt16(4)) + entry(0x011A, 5, 1, be(UInt32(62))) + entry(0x011B, 5, 1, be(UInt32(70)))
            + entry(0x0128, 3, 1, [0, 2, 0, 0]) + entry(0x8769, 4, 1, be(UInt32(78))) + end
        tiff += be(UInt32(300)) + be(UInt32(1)) + be(UInt32(300)) + be(UInt32(1))
        tiff += be(UInt16(2)) + entry(0xA001, 3, 1, [0xFF, 0xFF, 0, 0]) + entry(0xA005, 4, 1, be(UInt32(108))) + end
        tiff += be(UInt16(1)) + entry(0x0001, 2, 4, Array("R03".utf8) + [0]) + end
        let segment = [0xFF, 0xE1] + be(UInt16(tiff.count + 8)) + Array("Exif".utf8) + [0, 0] + tiff
        // Keep everything but ImageIO's EXIF; ours goes right after the JFIF header.
        let jpeg = [UInt8](try Data(contentsOf: url))
        var out: [UInt8] = [0xFF, 0xD8]
        var at = 2
        while jpeg[at] == 0xFF, jpeg[at + 1] != 0xDA {
            let length = Int(jpeg[at + 2]) << 8 | Int(jpeg[at + 3])
            if jpeg[at + 1] != 0xE1 { out += jpeg[at ..< at + 2 + length] }
            if jpeg[at + 1] == 0xE0 { out += segment }
            at += 2 + length
        }
        try Data(out + jpeg[at...]).write(to: url)
    }

    /// A smooth photo-like JPEG with far more than 256 colours: red across, green down, blue
    /// diagonal. Any palette step shows as dither noise.
    static func colourPlaneJPEG(_ url: URL, width: Int = 640, height: Int = 480) throws {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8(x * 255 / (width - 1))
                pixels[i + 1] = UInt8(y * 255 / (height - 1))
                pixels[i + 2] = UInt8((x + y) * 255 / (width + height - 2))
            }
        }
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        try write(context.makeImage()!, to: url, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 1.0])
    }

    /// A noisy HDR JPEG with a gain map, made with Core Image, big enough to fit under a size.
    @available(macOS 15, *)
    static func hdrPhotoJPEG(_ url: URL) throws {
        let photo = CIImage(cgImage: try gradient(width: 640, height: 480, deep: false, alpha: false, noise: true))
        let hdr = photo.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 3, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 3, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 3, w: 0),
        ])
        let sdr = hdr.applyingFilter("CIToneMapHeadroom", parameters: ["inputTargetHeadroom": 1.0])
        try CIContext().writeJPEGRepresentation(
            of: sdr, to: url, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
            options: [.hdrImage: hdr, CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 1.0]
        )
    }

    /// A HEIC with EXIF and GPS.
    static func taggedHEIC(_ url: URL) throws {
        try write(gradient(width: 320, height: 240, deep: false, alpha: false), to: url, type: .heic, properties: [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "esclop test"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 41.38, kCGImagePropertyGPSLatitudeRef: "N"],
        ])
    }
}

extension Inspect {
    static func frames(_ url: URL) -> Int {
        CGImageSourceCreateWithURL(url as CFURL, nil).map(CGImageSourceGetCount) ?? 0
    }

    /// Mean absolute difference per 8-bit channel between two pictures drawn at `a`'s size.
    static func meanDifference(_ a: CGImage, _ b: CGImage) -> Double {
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: a.width * a.height * 4)
            let context = CGContext(
                data: &data, width: a.width, height: a.height, bitsPerComponent: 8, bytesPerRow: a.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: a.width, height: a.height))
            return data
        }
        let (x, y) = (pixels(a), pixels(b))
        let total = zip(x, y).enumerated().reduce(0) { sum, item in item.offset % 4 == 3 ? sum : sum + abs(Int(item.element.0) - Int(item.element.1)) }
        return Double(total) / Double(a.width * a.height * 3)
    }
}

@Suite struct ImageFidelityTests {
    @Test func multiPageTIFFsKeepEveryPageOrAreLeftAlone() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let tiff = world.file("scan.tiff")
        try Fixture.tiff(tiff, pages: 3)

        // TIFF is on the default "convert to PNG" list: not for a multi-page file.
        let auto = try await world.engine.optimise(tiff, request: world.request(tiff, origin: .clipboard, location: .temporary), progress: { _ in })
        #expect(Inspect.type(auto.output) == .tiff)
        #expect(Inspect.frames(auto.output) == 3)
        #expect((Inspect.properties(auto.output)[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFArtist] == nil)

        await #expect(throws: ImageEngine.keepsOnlyOneFrame) {
            try await world.engine.convert(tiff, to: .png, request: world.request(tiff), progress: { _ in })
        }
        #expect(Inspect.frames(tiff) == 3)

        let pdf = try await world.engine.convert(tiff, to: .pdf, request: world.request(tiff, location: .temporary), progress: { _ in })
        #expect(PDFDocument(url: pdf.output)?.pageCount == 3)
    }

    @Test func theTIFFWriterKeepsTheTIFFTags() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        try EsclopSettings.stripMetadata.set(false, in: world.settings)
        let tiff = world.file("tagged.tiff")
        try Fixture.write(Fixture.gradient(width: 64, height: 48, deep: false, alpha: false), to: tiff, type: .tiff, properties: [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "esclop test"],
        ])
        let result = try await world.engine.optimise(tiff, request: world.request(tiff, location: .temporary), progress: { _ in })
        let tags = Inspect.properties(result.output)[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tags?[kCGImagePropertyTIFFArtist] as? String == "esclop test")
        #expect(tags?[kCGImagePropertyTIFFCompression] as? Int == 5)
    }

    @Test func anExplicitOutputNameMustMatchTheFormat() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let png = world.file("page.png")
        try Fixture.png(png)
        await #expect(throws: EsclopError.self) {
            try await world.engine.convert(png, to: .pdf, request: world.request(png, location: .path("wrong.jpg")), progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: world.file("wrong.jpg").path))
        let tiff = try await world.engine.convert(png, to: .tiff, request: world.request(png, location: .path("scan.tif")), progress: { _ in })
        #expect(tiff.output.lastPathComponent == "scan.tif")
        let named = try await world.engine.convert(png, to: .pdf, request: world.request(png, location: .path("page.v2")), progress: { _ in })
        #expect(named.output.lastPathComponent == "page.v2")
    }

    @Test func convertingInPlaceLeavesAnUnrelatedSiblingAlone() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let png = world.file("photo.png")
        let sibling = world.file("photo.jpeg")
        try Fixture.png(png)
        try Data("an unrelated jpeg".utf8).write(to: sibling)
        let result = try await world.engine.convert(png, to: .jpeg, request: world.request(png), progress: { _ in })
        #expect(result.output == world.file("photo 2.jpeg"))
        #expect(Inspect.type(result.output) == .jpeg)
        #expect(try String(contentsOf: sibling, encoding: .utf8) == "an unrelated jpeg")
        #expect(world.backups.entries().map { $0.original.lastPathComponent } == ["photo.png"])
    }

    @Test func gainMapsFollowKeepHDR() async throws {
        guard #available(macOS 15, *) else { return }
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let heic = world.file("hdr.heic")
        try HDRTests.hdrHEIC(heic)

        let avif = try? await world.engine.convert(heic, to: .avif, request: world.request(heic, location: .temporary), progress: { _ in })
        if let avif { #expect(avif.steps.contains("HDR dropped: AVIF cannot hold the gain map")) }

        try EsclopSettings.keepHDR.set(false, in: world.settings)
        let sdr = try await world.engine.optimise(heic, request: world.request(heic, location: .temporary), progress: { _ in })
        #expect(ImageInfo.probe(sdr.output)?.hasGainMap == false)
    }
}

@Suite(.enabled(if: Harness.hasRealEngine)) struct RealEngineFidelityTests {
    /// A four-frame animated WebP, made by the engine from a GIF.
    static func animatedWebP(_ world: TestWorld) async throws -> URL {
        let gif = world.file("anim.gif")
        try Fixture.gif(gif, frames: 4, size: 96)
        let made = try await world.engine.convert(gif, to: .webp, request: world.request(gif, location: .temporary), progress: { _ in })
        let webp = world.file("anim.webp")
        try FileManager.default.copyItem(at: made.output, to: webp)
        try #require(Inspect.frames(webp) == 4)
        return webp
    }

    @Test func animationsKeepTheirFramesOrAreLeftAlone() async throws {
        let world = try await TestWorld(realEngine: true)
        defer { Task { await world.finish() } }
        let webp = try await Self.animatedWebP(world)

        let cropped = try await world.engine.crop(webp, to: CropSize(aspectRatio: "1:2"), request: world.request(webp, location: .temporary), progress: { _ in })
        #expect(Inspect.frames(cropped.output) == 4)
        #expect(Inspect.size(cropped.output)! == (48, 96))
        let half = try await world.engine.downscale(webp, factor: 0.5, request: world.request(webp, location: .temporary), progress: { _ in })
        #expect(Inspect.frames(half.output) == 4)

        // WebP is on the default "convert to JPEG" list: not for an animation.
        let auto = try? await world.engine.optimise(webp, request: world.request(webp, origin: .clipboard, location: .temporary), progress: { _ in })
        if let auto { #expect(Inspect.type(auto.output) == UTType.webP && Inspect.frames(auto.output) == 4) }

        await #expect(throws: ImageEngine.keepsOnlyOneFrame) {
            try await world.engine.convert(webp, to: .jpeg, request: world.request(webp), progress: { _ in })
        }
        #expect(Inspect.frames(webp) == 4)
    }

    @Test func resizingAPhotoIsLosslessUntilTheLastEncode() async throws {
        let world = try await TestWorld(realEngine: true)
        defer { Task { await world.finish() } }
        let jpeg = world.file("photo.jpg")
        try Fixture.colourPlaneJPEG(jpeg)
        let result = try await world.engine.downscale(jpeg, factor: 0.5, request: world.request(jpeg, location: .temporary), progress: { _ in })
        let reference = try ImageIOCodec.render(ImageIOCodec.uprightImage(jpeg), crop: nil, width: 320, height: 240)
        let difference = Inspect.meanDifference(reference, try ImageIOCodec.uprightImage(result.output))
        // A palette-quantised intermediate measured 1.8, a lossless one 0.6.
        #expect(difference < 1.0, "mean difference \(difference)")
    }

    @Test func fittingAnHDRPhotoKeepsTheGainMap() async throws {
        guard #available(macOS 15, *) else { return }
        let world = try await TestWorld(realEngine: true)
        defer { Task { await world.finish() } }
        let jpeg = world.file("hdr.jpeg")
        try Fixture.hdrPhotoJPEG(jpeg)
        try #require(ImageInfo.probe(jpeg)?.hasGainMap == true)
        let fit = try await world.engine.fit(jpeg, underBytes: Inspect.bytes(jpeg) * 7 / 10, request: world.request(jpeg, location: .temporary), progress: { _ in })
        #expect(ImageInfo.probe(fit.output)?.hasGainMap == true)
    }

    @Test func strippingKeepsDPIAndColourSpace() async throws {
        let world = try await TestWorld(realEngine: true)
        defer { Task { await world.finish() } }
        let jpeg = world.file("print.jpg")
        try Fixture.printJPEG(jpeg)
        let result = try await world.engine.optimise(jpeg, request: world.request(jpeg, location: .temporary), progress: { _ in })
        let properties = Inspect.properties(result.output)
        #expect(properties[kCGImagePropertyDPIWidth] as? Int == 300)
        #expect(properties[kCGImagePropertyDPIHeight] as? Int == 300)
        let colourSpace = { (url: URL) in (Inspect.properties(url)[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifColorSpace] as? Int }
        #expect(colourSpace(jpeg) == 0xFFFF)
        #expect(colourSpace(result.output) == 0xFFFF)
    }

    @Test func metadataReachesWebPFromFormatsTheEngineCannotRead() async throws {
        let world = try await TestWorld(realEngine: true)
        defer { Task { await world.finish() } }
        try EsclopSettings.stripMetadata.set(false, in: world.settings)
        let heic = world.file("tagged.heic")
        try Fixture.taggedHEIC(heic)
        let result = try await world.engine.convert(heic, to: .webp, request: world.request(heic, location: .temporary), progress: { _ in })
        #expect(Inspect.properties(result.output)[kCGImagePropertyGPSDictionary] != nil)
    }
}
