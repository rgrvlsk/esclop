// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Remove metadata" keeps its promise in every format L'Esclop writes: the location, camera,
// serial numbers, owner and author planted in EXIF, TIFF, GPS and XMP are gone afterwards. Read
// back with ImageIO and, where it is installed, with exiftool as an independent judge.

import CoreGraphics
import EsclopCore
@testable import EsclopOptimisers
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite struct StripPromiseTests {
    /// S1: ImageIO wrote a HEIC back unchanged and the step said "Removed metadata".
    @Test func heicStripRemovesLocationCameraAndSerials() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let heic = world.file("photo.heic")
        try Personal.plant(heic, type: .heic, orientation: 6)
        #expect(!Personal.left(heic).isEmpty, "the fixture carries it")

        let result = try await world.engine.stripMetadata(heic, request: world.request(heic, location: .temporary))
        #expect(try Data(contentsOf: result.output) != Data(contentsOf: heic))
        #expect(Personal.left(result.output) == [])
        #expect(try await Personal.exiftool(result.output) ?? [] == [])
        #expect(Inspect.type(result.output) == .heic)
        #expect(Inspect.properties(result.output)[kCGImagePropertyOrientation] as? Int == 6, "orientation is not personal")
        #expect(result.steps == ["Removed metadata (re-encoded at the highest quality)"])
    }

    /// S2: a TIFF kept Make, Model, OwnerName and the serial numbers; every page and the density stay.
    @Test func tiffStripRemovesCameraAndOwnerOnEveryPage() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let tiff = world.file("scan.tiff")
        try Personal.plant(tiff, type: .tiff, pages: 2, dpi: 300)

        let result = try await world.engine.stripMetadata(tiff, request: world.request(tiff, location: .temporary))
        #expect(Personal.left(result.output) == [])
        #expect(try await Personal.exiftool(result.output) ?? [] == [])
        #expect(ImageInfo.probe(result.output)?.frameCount == 2)
        #expect(ImageInfo.probe(result.output)?.dpi == 300, "the density describes the picture")
    }

    /// S3: a same-size HEIC optimise with strip on kept the XMP serial number.
    @Test func sameSizeHEICOptimiseStripsTheXMPSerial() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let heic = world.file("same.heic")
        try Personal.plant(heic, type: .heic)
        var request = world.request(heic, location: .temporary)
        request.stripMetadata = true
        let result = try await world.engine.optimise(heic, request: request, progress: { _ in })
        #expect(Inspect.type(result.output) == .heic)
        #expect(Personal.left(result.output) == [])
        #expect(try await Personal.exiftool(result.output) ?? [] == [])
    }

    /// S4: AVIF failed with ImageIO's "not supported for lossless metadata modification".
    @Test func avifStripWorksOrSaysWhyInASentence() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let avif = world.file("photo.avif")
        guard ImageIOCodec.canWrite(Personal.avif) else {
            // Without an AVIF writer there is no fixture either; the sentence is in `stripMetadata`.
            return
        }
        try Personal.plant(avif, type: Personal.avif)
        let result = try await world.engine.stripMetadata(avif, request: world.request(avif, location: .temporary))
        #expect(Inspect.type(result.output) == Personal.avif)
        #expect(Personal.left(result.output) == [])
        #expect(try await Personal.exiftool(result.output) ?? [] == [])
    }

    /// The promise: every format L'Esclop writes, through the route each takes in the app (the
    /// real engine for JPEG, PNG and WebP, gifsicle for GIF, ImageIO for the rest).
    @Test(.enabled(if: Harness.hasRealEngine && Harness.hasGifsicle)) func stripKeepsItsPromiseInEveryFormat() async throws {
        let world = try await TestWorld(realEngine: true)
        defer { Task { await world.finish() } }
        var formats: [(String, UTType)] = [("jpg", .jpeg), ("png", .png), ("heic", .heic), ("tiff", .tiff), ("gif", .gif)]
        if ImageIOCodec.canWrite(Personal.avif) { formats.append(("avif", Personal.avif)) }
        for (ext, type) in formats {
            let file = world.file("promise.\(ext)")
            try Personal.plant(file, type: type)
            try await Self.checkStripped(file, world: world)
        }
        // ImageIO cannot write WebP: the engine converts a planted PNG and keeps its EXIF.
        let png = world.file("for-webp.png")
        try Personal.plant(png, type: .png)
        let webp = world.file("promise.webp")
        try await world.client.call("convert", input: png, output: webp, params: ["format": "webp", "quality": 80, "strip": false])
        #expect(!Personal.left(webp).isEmpty, "the WebP fixture carries it")
        try await Self.checkStripped(webp, world: world)
    }

    private static func checkStripped(_ file: URL, world: TestWorld) async throws {
        let planted = Personal.left(file) + (try await Personal.exiftool(file) ?? [])
        #expect(!planted.isEmpty, "\(file.lastPathComponent) fixture carries something to remove")
        let result = try await world.engine.stripMetadata(file, request: world.request(file, location: .temporary))
        #expect(Personal.left(result.output) == [], "\(file.lastPathComponent)")
        #expect(try await Personal.exiftool(result.output) ?? [] == [], "\(file.lastPathComponent)")
        #expect(Inspect.type(result.output) == Inspect.type(file), "\(file.lastPathComponent)")
    }
}

/// Planting and reading back what tells who took a picture, where and with what.
enum Personal {
    static let avif = UTType("public.avif")!
    static var auxNamespace: CFString { "http://ns.adobe.com/exif/1.0/aux/" as CFString }
    static var dcNamespace: CFString { "http://purl.org/dc/elements/1.1/" as CFString }

    /// A small picture of `type` with GPS, camera make and model, body, lens and XMP serial
    /// numbers, owner, artist, a comment and an XMP creator, on every one of `pages`.
    static func plant(_ url: URL, type: UTType, pages: Int = 1, orientation: Int = 1, dpi: Double = 72) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, pages, nil) else {
            throw EsclopError.other("destination")
        }
        let xmp = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(xmp, dcNamespace, "dc" as CFString, nil)
        CGImageMetadataRegisterNamespaceForPrefix(xmp, auxNamespace, "aux" as CFString, nil)
        CGImageMetadataSetValueWithPath(xmp, nil, "dc:creator" as CFString, "Secret Person" as CFString)
        CGImageMetadataSetValueWithPath(xmp, nil, "aux:SerialNumber" as CFString, "AUX789" as CFString)
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "PlantMake", kCGImagePropertyTIFFModel: "PlantModel", kCGImagePropertyTIFFArtist: "Secret Artist",
                kCGImagePropertyTIFFOrientation: orientation,
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifBodySerialNumber: "BODY123", kCGImagePropertyExifLensSerialNumber: "LENS456",
                kCGImagePropertyExifCameraOwnerName: "Owner Name", kCGImagePropertyExifUserComment: "a comment",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 41.38, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 2.17, kCGImagePropertyGPSLongitudeRef: "E",
            ],
        ]
        for page in 0 ..< pages {
            let image = try Fixture.gradient(width: 160, height: 120, deep: false, alpha: false, phase: Double(page))
            CGImageDestinationAddImageAndMetadata(destination, image, xmp, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw EsclopError.other("finalize") }
    }

    /// What ImageIO still reads, named by tag. Its own reading, not `ImageIOCodec.personalMetadata`.
    static func left(_ url: URL) -> [String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return ["unreadable"] }
        var found: [String] = []
        for index in 0 ..< CGImageSourceGetCount(source) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let aux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
            if properties[kCGImagePropertyGPSDictionary] != nil { found.append("GPS") }
            for (name, value) in [
                ("Make", tiff[kCGImagePropertyTIFFMake]), ("Model", tiff[kCGImagePropertyTIFFModel]), ("Artist", tiff[kCGImagePropertyTIFFArtist]),
                ("BodySerialNumber", exif[kCGImagePropertyExifBodySerialNumber]), ("LensSerialNumber", exif[kCGImagePropertyExifLensSerialNumber]),
                ("OwnerName", exif[kCGImagePropertyExifCameraOwnerName]), ("UserComment", exif[kCGImagePropertyExifUserComment]),
                ("aux.SerialNumber", aux[kCGImagePropertyExifAuxSerialNumber]),
            ] where value != nil { found.append(name) }
            if let xmp = CGImageSourceCopyMetadataAtIndex(source, index, nil) {
                for path in ["dc:creator", "aux:SerialNumber"] where CGImageMetadataCopyTagWithPath(xmp, nil, path as CFString) != nil {
                    found.append(path)
                }
            }
        }
        return found
    }

    static let exiftoolURL = ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool", "/usr/bin/exiftool"]
        .map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }

    /// The location, camera, serial, owner and author tags exiftool finds; nil without exiftool.
    static func exiftool(_ url: URL) async throws -> [String]? {
        guard let exiftoolURL else { return nil }
        let result = try await ProcessRunner.run(executable: exiftoolURL, arguments: ["-j", "-G1", "-a", "-s", url.path])
        let tags = (try JSONSerialization.jsonObject(with: result.stdout) as? [[String: Any]])?.first ?? [:]
        let names: Set<String> = ["Make", "Model", "SerialNumber", "LensSerialNumber", "OwnerName", "Artist", "Creator", "UserComment"]
        return tags.keys.filter { key in
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return false }
            return parts[1].hasPrefix("GPS") || names.contains(parts[1])
        }.sorted()
    }
}
