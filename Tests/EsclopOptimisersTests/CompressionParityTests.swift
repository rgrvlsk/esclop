// SPDX-License-Identifier: GPL-3.0-or-later
//
// Compression that matches Clop at every stop: the palette cap and GIF frame drop of the top
// stops, adaptive PNG/JPEG from the lossless input, transparency judged by pixels, the minimum
// gain of a lossy re-encode, and JPEG XL refused where macOS cannot write it.

import CoreGraphics
import EsclopCore
@testable import EsclopOptimisers
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

extension Fixture {
    /// A photo-like picture in an RGBA buffer: every pixel opaque unless `holes`, which clears a
    /// 2x2 square.
    static func rgba(width: Int, height: Int, holes: Bool = false, noise: Bool = true) throws -> CGImage {
        let photo = try gradient(width: width, height: height, deep: false, alpha: false, noise: noise)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw EsclopError.other("context") }
        context.draw(photo, in: CGRect(x: 0, y: 0, width: width, height: height))
        if holes { context.clear(CGRect(x: 10, y: 10, width: 2, height: 2)) }
        guard let image = context.makeImage() else { throw EsclopError.other("image") }
        return image
    }

    /// A flat graphic: small blocks of six colours, off the 8-pixel JPEG grid so every block
    /// has edges, saved as a high-quality JPEG.
    static func flatJPEG(_ url: URL, width: Int, height: Int) throws {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw EsclopError.other("context") }
        let colours = [(1.0, 1.0, 1.0), (0.1, 0.1, 0.1), (0.9, 0.2, 0.1), (0.1, 0.4, 0.9), (0.2, 0.7, 0.3), (1.0, 0.8, 0.1)]
        for x in stride(from: 0, to: width, by: 5) {
            for y in stride(from: 0, to: height, by: 3) {
                let c = colours[(x / 5 * 7 + y / 3 * 3) % colours.count]
                context.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 5, height: 3))
            }
        }
        try write(context.makeImage()!, to: url, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 1.0])
    }
}

extension Inspect {
    static func colourCount(_ url: URL) throws -> Int {
        let image = try ImageIOCodec.uprightImage(url)
        let context = try #require(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = UnsafeBufferPointer(start: context.data!.bindMemory(to: UInt32.self, capacity: image.width * image.height), count: image.width * image.height)
        return Set(pixels).count
    }
}

@Suite struct CompressionCurveTests {
    @Test func topStopsCapThePaletteAndDropGIFFrames() {
        #expect([79, 80, 90, 100].map { Curves($0).pngColors } == [nil, 224, 144, 64])
        #expect([79, 80, 90, 98].map { Curves($0).gifFrameDropEveryNth } == [nil, 4, 3, 2])
    }

    @Test func droppedFramesHandTheirDelayToTheFrameBefore() throws {
        #expect(Curves.gifFrameDropArgs(delays: Array(repeating: 10, count: 8), everyNth: 2) == nil)
        let args = try #require(Curves.gifFrameDropArgs(delays: [5, 10, 10, 10, 10, 10, 10, 10, 10, 7], everyNth: 3))
        #expect(args == ["-d5", "#0", "-d10", "#1", "-d20", "#2", "-d10", "#4", "-d20", "#5", "-d10", "#7", "-d17", "#8"])
    }

    @Test func aLossyReencodeMustSaveAFewPercent() {
        #expect(ResultWriter.minimumSaving(of: 100_000, lossless: true) == 1)
        #expect(ResultWriter.minimumSaving(of: 100_000, lossless: false) == 3_000)
        #expect(ResultWriter.minimumSaving(of: 10, lossless: false) == 1)
    }
}

@Suite struct TransparencyTests {
    @Test func anAlphaChannelAloneIsNotTransparency() throws {
        let folder = try Harness.folder()
        let opaque = folder.appendingPathComponent("opaque.png")
        let holes = folder.appendingPathComponent("holes.png")
        try Fixture.write(Fixture.rgba(width: 64, height: 48), to: opaque, type: .png, properties: [:])
        try Fixture.write(Fixture.rgba(width: 64, height: 48, holes: true), to: holes, type: .png, properties: [:])
        let info = try #require(ImageInfo.probe(opaque))
        #expect(info.hasAlpha)
        #expect(!ImageEngine.hasTransparentPixels(opaque, info: info))
        #expect(ImageEngine.hasTransparentPixels(holes, info: try #require(ImageInfo.probe(holes))))
        let jpeg = folder.appendingPathComponent("photo.jpg")
        try Fixture.jpeg(jpeg)
        #expect(!ImageEngine.hasTransparentPixels(jpeg, info: try #require(ImageInfo.probe(jpeg))))
    }

    @Test(.enabled(if: !ImageIOCodec.canWrite(UTType("public.jpeg-xl")!)))
    func jpegXLIsRefusedWhereMacOSCannotWriteIt() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let png = world.file("photo.png")
        try Fixture.png(png)
        await #expect(throws: EsclopError.unsupportedFile("This Mac cannot write JPEG XL")) {
            try await world.engine.convert(png, to: .jxl, request: world.request(png, location: .temporary), progress: { _ in })
        }
    }
}

@Suite(.enabled(if: Harness.hasRealEngine)) struct RealEngineCompressionTests {
    static func request(_ world: TestWorld, _ source: URL, factor: Int = 30, adaptive: Bool = false, location: OutputLocation = .temporary) -> OptimisationRequest {
        var request = world.request(source, location: location)
        request.quality = CompressionQuality(tier: .custom, factor: factor)
        request.stripMetadata = true
        request.adaptiveImageFormat = adaptive
        return request
    }

    /// An opaque RGBA photo PNG becomes the JPEG the engine makes from the PNG itself, not from
    /// the quantised PNG; with a transparent pixel it stays PNG.
    @Test func adaptivePNGBecomesTheJPEGOfTheSource() async throws {
        let world = try await TestWorld(realEngine: true)
        defer { Task { await world.finish() } }
        let png = world.file("photo.png")
        try Fixture.write(Fixture.rgba(width: 1200, height: 900, noise: false), to: png, type: .png, properties: [:])
        let result = try await world.engine.optimise(png, request: Self.request(world, png, adaptive: true), progress: { _ in })
        #expect(Inspect.type(result.output) == .jpeg)
        let direct = world.file("direct.jpeg")
        try await world.client.call("convert", input: png, output: direct, params: [
            "format": "jpeg", "quality": .int(Curves(30).jpegQuality), "progressive": true, "strip": true,
        ])
        #expect(try Data(contentsOf: result.output) == Data(contentsOf: direct))

        let holes = world.file("holes.png")
        try Fixture.write(Fixture.rgba(width: 1200, height: 900, holes: true, noise: false), to: holes, type: .png, properties: [:])
        let kept = try await world.engine.optimise(holes, request: Self.request(world, holes, adaptive: true), progress: { _ in })
        #expect(Inspect.type(kept.output) == .png)
    }

    /// An explicit `.png` output keeps the PNG instead of failing after the work.
    @Test func adaptiveKeepsTheFormatAnOutputPathNames() async throws {
        let world = try await TestWorld(realEngine: true)
        defer { Task { await world.finish() } }
        let png = world.file("photo.png")
        try Fixture.write(Fixture.rgba(width: 1200, height: 900, noise: false), to: png, type: .png, properties: [:])
        let out = world.file("out/shot.png")
        let result = try await world.engine.optimise(png, request: Self.request(world, png, adaptive: true, location: .path(out.path)), progress: { _ in })
        #expect(result.output.standardizedFileURL.path == out.standardizedFileURL.path)
        #expect(Inspect.type(result.output) == .png)
    }

    @Test func adaptiveFlatJPEGBecomesPNG() async throws {
        let world = try await TestWorld(realEngine: true)
        defer { Task { await world.finish() } }
        let jpeg = world.file("chart.jpg")
        try Fixture.flatJPEG(jpeg, width: 1600, height: 1000)
        #expect(Inspect.bytes(jpeg) > 400_000, "\(Inspect.bytes(jpeg))")
        #expect(try #require(ImageIOCodec.entropy(jpeg)) < 5)
        let result = try await world.engine.optimise(jpeg, request: Self.request(world, jpeg, adaptive: true), progress: { _ in })
        #expect(Inspect.type(result.output) == .png)
    }

    @Test func theTopStopCapsThePalette() async throws {
        let world = try await TestWorld(realEngine: true)
        defer { Task { await world.finish() } }
        let png = world.file("photo.png")
        try Fixture.write(Fixture.rgba(width: 320, height: 240), to: png, type: .png, properties: [:])
        let result = try await world.engine.optimise(png, request: Self.request(world, png, factor: 100), progress: { _ in })
        #expect(try Inspect.colourCount(result.output) <= 64)
    }

    @Test(.enabled(if: Harness.hasGifsicle)) func theTopStopsDropGIFFramesAndKeepTheDuration() async throws {
        let world = try await TestWorld(realEngine: true)
        defer { Task { await world.finish() } }
        let gif = world.file("anim.gif")
        try Fixture.gif(gif, frames: 12)
        let result = try await world.engine.optimise(gif, request: Self.request(world, gif, factor: 90), progress: { _ in })
        let delays = ImageEngine.gifDelays(result.output)
        #expect(delays.count == 9, "every 3rd of 12 frames dropped")
        #expect(delays.reduce(0, +) == 120)
    }
}
