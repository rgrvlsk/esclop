// SPDX-License-Identifier: GPL-3.0-or-later
//
// Test harness: tiny fixtures generated at test time (ImageIO, ffmpeg, Core Graphics), an
// isolated engine per test (own settings suite, backup folder and work folder), and the fake
// `esclop-engine` compiled once from Tests/FakeEngine.

import CoreGraphics
import EsclopCore
@testable import EsclopOptimisers
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

enum Harness {
    static var hasFFmpeg: Bool { ToolLocator.shared.locate(.ffmpeg) != nil && ToolLocator.shared.locate(.ffprobe) != nil }
    static var hasGhostscript: Bool { ToolLocator.shared.locate(.gs) != nil }
    static var hasGifsicle: Bool { ToolLocator.shared.locate(.gifsicle) != nil }
    /// A real Rust engine, for the integration suite.
    static var hasRealEngine: Bool { ToolLocator.shared.locate(.esclopEngine) != nil }

    static func folder(_ name: String = #function) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("esclop-tests", isDirectory: true)
            .appendingPathComponent("\(name.filter(\.isLetter))-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// One test's world: its folder, settings, backups and an engine wired to the fake image engine.
struct TestWorld {
    let folder: URL
    let settings: SettingsStore
    let backups: BackupStore
    let client: EngineClient
    let engine: EsclopEngine

    init(name: String = #function, realEngine: Bool = false) async throws {
        folder = try Harness.folder(name)
        settings = SettingsStore(suiteName: "dev.esclop.tests.\(UUID().uuidString)")
        backups = BackupStore(root: folder.appendingPathComponent("backups", isDirectory: true))
        client = realEngine ? EngineClient() : EngineClient(executable: try await FakeEngine.shared.executable())
        engine = EsclopEngine(
            settings: settings, backups: backups, imageEngine: client,
            workRoot: folder.appendingPathComponent("work", isDirectory: true)
        )
    }

    func request(_ sources: URL..., origin: RequestOrigin = .cli, location: OutputLocation = .inPlace) -> OptimisationRequest {
        OptimisationRequest(sources: sources, origin: origin, location: location)
    }

    func file(_ name: String) -> URL { folder.appendingPathComponent(name) }

    func finish() async {
        await client.shutdown()
        settings.removeAll()
    }
}

/// Builds the fake engine once per test run.
actor FakeEngine {
    static let shared = FakeEngine()
    private var built: Task<URL, Error>?

    func executable() async throws -> URL {
        if let built { return try await built.value }
        let task = Task<URL, Error> {
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("FakeEngine/fake-esclop-engine.swift")
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("esclop-tests/fake-engine-\(UUID().uuidString.prefix(8))/esclop-engine")
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["swiftc", "-o", output.path, source.path],
                options: ProcessOptions(timeout: 300)
            )
            return output
        }
        built = task
        return try await task.value
    }
}

// MARK: - Fixtures

enum Fixture {
    /// A 16-bit gradient PNG with some structure, so 8-bit re-encoding and quantisation shrink it.
    static func png(_ url: URL, width: Int = 320, height: Int = 240, alpha: Bool = false) throws {
        let image = try gradient(width: width, height: height, deep: true, alpha: alpha)
        try write(image, to: url, type: .png, properties: [:])
    }

    /// A JPEG at maximum quality with EXIF and GPS metadata.
    static func jpeg(_ url: URL, width: Int = 320, height: Int = 240, orientation: Int = 1) throws {
        let image = try gradient(width: width, height: height, deep: false, alpha: false)
        try write(image, to: url, type: .jpeg, properties: [
            kCGImageDestinationLossyCompressionQuality: 1.0,
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "esclop test", kCGImagePropertyExifDateTimeOriginal: "2026:01:02 03:04:05"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 41.38, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 2.17, kCGImagePropertyGPSLongitudeRef: "E"],
        ])
    }

    static func heic(_ url: URL) throws {
        let image = try gradient(width: 320, height: 240, deep: false, alpha: false)
        try write(image, to: url, type: .heic, properties: [kCGImageDestinationLossyCompressionQuality: 0.9])
    }

    /// An animated GIF of `frames` frames.
    static func gif(_ url: URL, frames: Int = 4, size: Int = 96) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
            throw EsclopError.other("gif destination")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for index in 0 ..< frames {
            let image = try gradient(width: size, height: size, deep: false, alpha: false, phase: Double(index))
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw EsclopError.other("gif write") }
    }

    /// A one-page PDF with a large noisy photo-like image, so downsampling shrinks it.
    static func pdf(_ url: URL, pages: Int = 1) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextAuthor: "esclop tests"] as CFDictionary) else {
            throw EsclopError.other("pdf context")
        }
        let image = try gradient(width: 1600, height: 1600, deep: false, alpha: false, noise: true)
        for _ in 0 ..< pages {
            context.beginPDFPage(nil)
            context.draw(image, in: CGRect(x: 36, y: 126, width: 540, height: 540))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 36, y: 60, width: 540, height: 20))
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// One second of a test pattern with a tone, in a deliberately fat format (MJPEG + PCM).
    static func video(_ url: URL, seconds: Int = 1, width: Int = 320, height: Int = 240, fps: Int = 30, audio: Bool = true) async throws {
        var args = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=d=\(seconds):s=\(width)x\(height):r=\(fps)"]
        if audio { args += ["-f", "lavfi", "-i", "sine=f=440:d=\(seconds)"] }
        args += ["-c:v", "mjpeg", "-q:v", "2", "-pix_fmt", "yuvj420p"]
        if audio { args += ["-c:a", "pcm_s16le", "-shortest"] }
        args.append(url.path)
        try await ProcessRunner.run(.ffmpeg, args)
    }

    static func wav(_ url: URL, seconds: Int = 2) async throws {
        try await ProcessRunner.run(.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=f=440:d=\(seconds):sample_rate=44100",
            "-ac", "2", "-c:a", "pcm_s16le", url.path,
        ])
    }

    // MARK: helpers

    static func gradient(width: Int, height: Int, deep: Bool, alpha: Bool, phase: Double = 0, noise: Bool = false) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let bits = deep ? 16 : 8
        let info: UInt32 = (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue
            | (deep ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: bits, bytesPerRow: 0, space: space, bitmapInfo: info) else {
            throw EsclopError.other("context")
        }
        let colors = [CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1), CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        context.setFillColor(CGColor(red: 1, green: 1, blue: 0.2, alpha: alpha ? 0.6 : 1))
        let r = Double(min(width, height)) / 4
        context.fillEllipse(in: CGRect(x: Double(width) * 0.6 - r + phase * 4, y: Double(height) * 0.55 - r, width: r * 2, height: r * 2))
        if noise {
            var generator = SystemRandomNumberGenerator()
            for _ in 0 ..< (width * height / 40) {
                let x = Double.random(in: 0 ..< Double(width), using: &generator)
                let y = Double.random(in: 0 ..< Double(height), using: &generator)
                context.setFillColor(CGColor(gray: Double.random(in: 0 ... 1, using: &generator), alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 3, height: 3))
            }
        }
        guard let image = context.makeImage() else { throw EsclopError.other("image") }
        return image
    }

    static func write(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any]) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw EsclopError.other("destination")
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EsclopError.other("finalize") }
    }
}

// MARK: - Inspecting results

enum Inspect {
    static func type(_ url: URL) -> UTType? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let id = CGImageSourceGetType(source) as String? else { return nil }
        return UTType(id)
    }

    static func size(_ url: URL) -> (Int, Int)? {
        ImageInfo.probe(url).map { ($0.width, $0.height) }
    }

    static func properties(_ url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    static func bytes(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    static func media(_ url: URL) async throws -> MediaInfo {
        try await MediaInfo.probe(url, tools: .shared)
    }
}
