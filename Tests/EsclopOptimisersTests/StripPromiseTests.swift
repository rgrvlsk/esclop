// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Remove metadata" keeps its promise in every format L'Esclop writes: the location, camera,
// serial numbers, owner and author planted in EXIF, TIFF, GPS and XMP are gone afterwards. Read
// back with ImageIO and, where it is installed, with exiftool as an independent judge.

import CoreGraphics
import CoreVideo
import EsclopCore
@testable import EsclopOptimisers
import Foundation
import ImageIO
import PDFKit
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
        #expect(result.steps == ["Removed metadata"], "without re-encoding")
    }

    /// HC-46 H2: the HEIC and AVIF strip re-encoded the picture and made photos 4 to 7 times
    /// larger. Blanking the Exif and XMP items keeps the coded image, its colour profile,
    /// orientation and density, and the size.
    @Test func heifStripKeepsThePictureAndTheSize() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        var types: [UTType] = [.heic]
        if ImageIOCodec.canWrite(Personal.avif) { types.append(Personal.avif) }
        for type in types {
            let photo = world.file("photo.\(type.preferredFilenameExtension ?? "heif")")
            try Personal.plant(photo, type: type, orientation: 6, dpi: 300, noise: true, width: 640, height: 480)
            let result = try await world.engine.stripMetadata(photo, request: world.request(photo, location: .temporary))
            let label = type.identifier
            #expect(result.steps == ["Removed metadata"], "\(label)")
            #expect(Personal.left(result.output) == [], "\(label)")
            #expect(Personal.inBytes(result.output) == [], "\(label)")
            #expect(try await Personal.exiftool(result.output) ?? [] == [], "\(label)")
            #expect(Inspect.bytes(result.output) <= Inspect.bytes(photo), "\(label) grew")
            #expect(Personal.pixels(result.output) == Personal.pixels(photo), "\(label) pixels")
            #expect(Personal.pixels(photo) != nil)
            #expect(Personal.icc(result.output) == Personal.icc(photo), "\(label) colour profile")
            // ImageIO's AVIF writer turns the pixels upright and writes 1.
            let orientation = Inspect.properties(photo)[kCGImagePropertyOrientation] as? Int
            #expect(Inspect.properties(result.output)[kCGImagePropertyOrientation] as? Int == orientation, "\(label)")
            #expect(ImageInfo.probe(result.output)?.dpi == 300, "\(label) density")
        }
    }

    /// An HDR HEIC loses its location and keeps its gain map, untouched.
    @Test func heifStripKeepsTheGainMap() async throws {
        guard #available(macOS 15, *) else { return }
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let heic = world.file("hdr.heic")
        try HDRTests.hdrHEIC(heic, properties: [
            kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude: 41.38, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake: "PlantMake", kCGImagePropertyTIFFHostComputer: "PlantHost"],
        ])
        try #require(ImageInfo.probe(heic)?.hasGainMap == true)
        try #require(!Personal.left(heic).isEmpty)
        let result = try await world.engine.stripMetadata(heic, request: world.request(heic, location: .temporary))
        #expect(result.steps == ["Removed metadata"])
        #expect(Personal.left(result.output) == [])
        #expect(ImageInfo.probe(result.output)?.hasGainMap == true)
        #expect(Inspect.bytes(result.output) == Inspect.bytes(heic))
        #expect(Personal.pixels(result.output) == Personal.pixels(heic))
        let gainMap = { (url: URL) in
            CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { source in
                ImageIOCodec.gainMapType(source).flatMap { CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) as? [CFString: Any] }
            }?[kCGImageAuxiliaryDataInfoData] as? Data
        }
        #expect(gainMap(result.output) != nil)
        #expect(gainMap(result.output) == gainMap(heic))
    }

    /// A portrait keeps its depth map and the XMP that describes it (that XMP belongs to the
    /// depth image, not to the person).
    @Test func heifStripKeepsTheDepthMap() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let heic = world.file("portrait.heic")
        let destination = try #require(CGImageDestinationCreateWithURL(heic as CFURL, UTType.heic.identifier as CFString, 1, nil))
        let gps = [kCGImagePropertyGPSLatitude: 41.38, kCGImagePropertyGPSLatitudeRef: "N"] as [CFString: Any]
        CGImageDestinationAddImage(
            destination, try Fixture.gradient(width: 64, height: 48, deep: false, alpha: false), [kCGImagePropertyGPSDictionary: gps] as CFDictionary
        )
        let disparity = Data(repeating: 0x3C, count: 32 * 24 * 2) // half-float values
        let depthXMP = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(depthXMP, "http://ns.apple.com/depthData/1.0/" as CFString, "depthData" as CFString, nil)
        CGImageMetadataSetValueWithPath(depthXMP, nil, "depthData:Accuracy" as CFString, "relative" as CFString)
        CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeDisparity, [
            kCGImageAuxiliaryDataInfoData: disparity,
            kCGImageAuxiliaryDataInfoDataDescription: [
                kCGImagePropertyWidth: 32, kCGImagePropertyHeight: 24, kCGImagePropertyBytesPerRow: 64,
                kCGImagePropertyPixelFormat: kCVPixelFormatType_DisparityFloat16,
            ] as [CFString: Any],
            kCGImageAuxiliaryDataInfoMetadata: depthXMP,
        ] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        func depth(_ url: URL) -> [CFString: Any]? {
            CGImageSourceCreateWithURL(url as CFURL, nil).flatMap {
                CGImageSourceCopyAuxiliaryDataInfoAtIndex($0, 0, kCGImageAuxiliaryDataTypeDisparity) as? [CFString: Any]
            }
        }
        try #require(depth(heic) != nil)
        let result = try await world.engine.stripMetadata(heic, request: world.request(heic, location: .temporary))
        #expect(result.steps == ["Removed metadata"])
        #expect(Personal.left(result.output) == [])
        #expect(depth(result.output)?[kCGImageAuxiliaryDataInfoData] as? Data == disparity)
        let accuracy = (depth(result.output)?[kCGImageAuxiliaryDataInfoMetadata]).map { $0 as! CGImageMetadata }
            .flatMap { CGImageMetadataCopyStringValueWithPath($0, nil, "depthData:Accuracy" as CFString) }
        #expect(accuracy as String? == "relative")
    }

    /// A structure the item parser does not read is left to the re-encode, never half-written.
    @Test func heifParserRefusesWhatItCannotRead() throws {
        #expect(HEIFMetadata.blanked(Data("not a heif file at all".utf8), orientation: nil, dpi: nil) == nil)
        let heic = try Harness.folder().appendingPathComponent("plain.heic")
        try Fixture.write(Fixture.gradient(width: 64, height: 48, deep: false, alpha: false), to: heic, type: .heic, properties: [:])
        let data = try Data(contentsOf: heic)
        // Cut inside the `meta` box.
        #expect(HEIFMetadata.blanked(data.prefix(200), orientation: nil, dpi: nil) == nil)
        #expect(HEIFMetadata.blanked(data, orientation: nil, dpi: nil) == data, "nothing to blank, nothing changes")
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
        var formats: [(String, UTType)] = [("jpg", .jpeg), ("png", .png), ("heic", .heic), ("tiff", .tiff)]
        if ImageIOCodec.canWrite(Personal.avif) { formats.append(("avif", Personal.avif)) }
        for (ext, type) in formats {
            let file = world.file("promise.\(ext)")
            try Personal.plant(file, type: type)
            try await Self.checkStripped(file, world: world)
        }
        // ImageIO on macOS 15 writes no XMP into a GIF: the comment and XMP blocks go in by hand.
        let gif = world.file("promise.gif")
        try Personal.plantGIF(gif)
        try await Self.checkStripped(gif, world: world)
        // ImageIO cannot write WebP: the engine converts a planted PNG and keeps its EXIF.
        let png = world.file("for-webp.png")
        try Personal.plant(png, type: .png)
        let webp = world.file("promise.webp")
        try await world.client.call("convert", input: png, output: webp, params: ["format": "webp", "quality": 80, "strip": false])
        #expect(!Personal.left(webp).isEmpty, "the WebP fixture carries it")
        try await Self.checkStripped(webp, world: world)
    }

    /// HC-46 H1: with strip on (the default), a picture that could not get smaller ended as
    /// "unchanged" and kept its location and camera. The strip is now the result.
    @Test(.enabled(if: Harness.hasRealEngine && Harness.hasGifsicle)) func unchangedWithStripOnStillStrips() async throws {
        let world = try await TestWorld(realEngine: true)
        defer { Task { await world.finish() } }
        var formats: [(String, UTType)] = [("jpg", .jpeg), ("png", .png), ("heic", .heic)]
        if ImageIOCodec.canWrite(Personal.avif) { formats.append(("avif", Personal.avif)) }
        for (ext, type) in formats {
            let file = world.file("small.\(ext)")
            try Personal.plant(file, type: type, noise: true, width: 400, height: 300)
            let result = try await Self.checkStripsWhenUnchanged(file, world: world)
            // Removing the metadata is often saving enough for the optimiser's own result. A
            // HEIC's never is: its strip saves nothing.
            if type == .heic { #expect(result.steps == ["Removed metadata"]) }
        }
        // Large enough that the XMP is less than the 3 % a lossy GIF has to save.
        let gif = world.file("small.gif")
        try Personal.plantGIF(gif, frames: 4, size: 240)
        #expect(try await Self.checkStripsWhenUnchanged(gif, world: world).steps == ["Removed metadata"])
    }

    /// HC-46 H4: the same for a video (an iPhone MOV keeps its location), a song whose strip is
    /// asked for, and a PDF, which keeps its title.
    @Test(.enabled(if: Harness.hasFFmpeg)) func unchangedVideoAndAudioStillStrip() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let tags = ["-metadata", "title=Secret Title", "-metadata", "artist=Secret Person", "-metadata", "location=+41.3800+002.1700/"]
        // Apple Lossless stays as it is: never smaller.
        let noise = world.file("noise.wav")
        try Fixture.noiseWAV(noise)
        let cover = world.file("cover.png")
        try Fixture.png(cover, width: 64, height: 64)
        let song = world.file("song.m4a")
        try await ProcessRunner.run(.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y", "-i", noise.path, "-i", cover.path, "-map", "0", "-map", "1",
            "-c:a", "alac_at", "-c:v", "png", "-disposition:v:0", "attached_pic",
        ] + tags + [song.path])
        try #require(try await Inspect.media(song).hasCoverArt)
        var song2 = world.request(song, location: .temporary)
        song2.stripMetadata = true
        let stripped = try await Self.checkStripsUnchangedMedia(song, request: song2, world: world)
        // The cover follows the cover-art setting, as when the song re-encodes.
        #expect(stripped.steps == ["Removed metadata"])
        #expect(try await Inspect.media(stripped.output).hasCoverArt)
        // Without asking, a song keeps its tags (the setting is for pictures, video and PDF).
        await #expect(throws: EsclopError.alreadySmaller) { try await world.engine.optimise(song, request: world.request(song), progress: { _ in }) }

        let fat = world.file("fat.mov")
        try await Fixture.video(fat)
        var clip = fat
        var keep = world.request(fat, location: .temporary)
        keep.stripMetadata = false
        // Optimised until it cannot get smaller, then given its location and author back.
        for _ in 0 ..< 3 {
            guard let once = try? await world.engine.optimise(clip, request: keep, progress: { _ in }) else { break }
            clip = world.file("clip-\(UUID().uuidString.prefix(4)).\(once.output.pathExtension)")
            try FileManager.default.copyItem(at: once.output, to: clip)
        }
        let tagged = world.file("tagged.\(clip.pathExtension)")
        try await ProcessRunner.run(.ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", clip.path, "-map", "0", "-c", "copy"] + tags + [tagged.path])
        var strip = world.request(tagged, location: .temporary)
        strip.stripMetadata = true
        #expect(try await Self.checkStripsUnchangedMedia(tagged, request: strip, world: world).steps == ["Removed metadata"])
    }

    @Test(.enabled(if: Harness.hasRealEngine)) func unchangedPDFStillStripsAndKeepsItsTitle() async throws {
        let world = try await TestWorld(realEngine: true)
        defer { Task { await world.finish() } }
        var pdf = world.file("letter.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let info = [kCGPDFContextTitle: "Quarterly report", kCGPDFContextAuthor: "Secret Person"] as CFDictionary
        let context = try #require(CGContext(pdf as CFURL, mediaBox: &box, info))
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 36, y: 60, width: 540, height: 20))
        context.endPDFPage()
        context.closePDF()
        var keep = world.request(pdf, location: .temporary)
        keep.stripMetadata = false
        for _ in 0 ..< 3 {
            guard let once = try? await world.engine.optimise(pdf, request: keep, progress: { _ in }) else { break }
            pdf = world.file("letter-\(UUID().uuidString.prefix(4)).pdf")
            try FileManager.default.copyItem(at: once.output, to: pdf)
        }
        func attributes(_ url: URL) -> [AnyHashable: Any] { PDFDocument(url: url)?.documentAttributes ?? [:] }
        try #require(attributes(pdf)[PDFDocumentAttribute.authorAttribute] != nil, "the optimised PDF keeps its author with strip off")
        var strip = world.request(pdf, location: .temporary)
        strip.stripMetadata = true
        let result = try await Self.checkStripsUnchangedMedia(pdf, request: strip, world: world)
        #expect(result.steps == ["Removed document metadata"])
        #expect(attributes(result.output)[PDFDocumentAttribute.authorAttribute] == nil)
        #expect(attributes(result.output)[PDFDocumentAttribute.titleAttribute] as? String == "Quarterly report")
    }

    /// `file` cannot get smaller with strip off; with `request` (strip on) it comes back
    /// stripped and no larger. Video and audio are checked here for tags left; a PDF's
    /// document information is checked by its test, since its title stays.
    private static func checkStripsUnchangedMedia(_ file: URL, request: OptimisationRequest, world: TestWorld) async throws -> OptimisationResult {
        var keep = request
        keep.stripMetadata = false
        await #expect(throws: EsclopError.alreadySmaller, "\(file.lastPathComponent) cannot get smaller") {
            try await world.engine.optimise(file, request: keep, progress: { _ in })
        }
        let result = try await world.engine.optimise(file, request: request, progress: { _ in })
        #expect(result.bytesAfter <= result.bytesBefore + result.bytesBefore / 100, "\(file.lastPathComponent)")
        if MediaKind.of(file) != .pdf {
            try #require(try await !Inspect.mediaTags(file).isEmpty, "\(file.lastPathComponent) carries tags")
            #expect(try await Inspect.mediaTags(result.output) == [], "\(file.lastPathComponent)")
        }
        return result
    }

    /// Optimises `file` with strip off until it cannot get smaller (the metadata stays), then
    /// with strip on.
    @discardableResult
    private static func checkStripsWhenUnchanged(_ file: URL, world: TestWorld) async throws -> OptimisationResult {
        let name = file.lastPathComponent
        var keep = world.request(file, location: .temporary)
        keep.stripMetadata = false
        var unchanged = false
        for _ in 0 ..< 3 where !unchanged {
            do {
                let once = try await world.engine.optimise(file, request: keep, progress: { _ in })
                try FileManager.default.removeItem(at: file)
                try FileManager.default.copyItem(at: once.output, to: file)
            } catch EsclopError.alreadySmaller {
                unchanged = true
            }
        }
        try #require(unchanged, "\(name) gets as small as it gets")
        try #require(!(Personal.left(file) + Personal.inBytes(file)).isEmpty, "\(name) still carries something to remove")
        var strip = world.request(file, location: .temporary)
        strip.stripMetadata = true
        let result = try await world.engine.optimise(file, request: strip, progress: { _ in })
        #expect(Personal.left(result.output) == [], "\(name)")
        #expect(Personal.inBytes(result.output) == [], "\(name)")
        #expect(try await Personal.exiftool(result.output) ?? [] == [], "\(name)")
        #expect(result.bytesAfter <= result.bytesBefore, "\(name)")
        return result
    }

    private static func checkStripped(_ file: URL, world: TestWorld) async throws {
        let planted = Personal.left(file) + Personal.inBytes(file) + (try await Personal.exiftool(file) ?? [])
        #expect(!planted.isEmpty, "\(file.lastPathComponent) fixture carries something to remove")
        let result = try await world.engine.stripMetadata(file, request: world.request(file, location: .temporary))
        #expect(Personal.left(result.output) == [], "\(file.lastPathComponent)")
        #expect(Personal.inBytes(result.output) == [], "\(file.lastPathComponent)")
        #expect(try await Personal.exiftool(result.output) ?? [] == [], "\(file.lastPathComponent)")
        #expect(Inspect.type(result.output) == Inspect.type(file), "\(file.lastPathComponent)")
    }
}

/// Planting and reading back what tells who took a picture, where and with what.
enum Personal {
    static let avif = UTType("public.avif")!
    static var auxNamespace: CFString { "http://ns.adobe.com/exif/1.0/aux/" as CFString }
    static var dcNamespace: CFString { "http://purl.org/dc/elements/1.1/" as CFString }

    /// A small picture of `type` with GPS, camera make and model, the host computer, body, lens
    /// and XMP serial numbers, a unique image ID, owner, artist, a comment and an XMP creator, on
    /// every one of `pages`. `noise` makes it photo-like, `quality` sets a lossy encoder's.
    static func plant(
        _ url: URL, type: UTType, pages: Int = 1, orientation: Int = 1, dpi: Double = 72,
        noise: Bool = false, width: Int = 160, height: Int = 120, quality: Double? = nil
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, pages, nil) else {
            throw EsclopError.other("destination")
        }
        let xmp = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(xmp, dcNamespace, "dc" as CFString, nil)
        CGImageMetadataRegisterNamespaceForPrefix(xmp, auxNamespace, "aux" as CFString, nil)
        CGImageMetadataSetValueWithPath(xmp, nil, "dc:creator" as CFString, "Secret Person" as CFString)
        CGImageMetadataSetValueWithPath(xmp, nil, "aux:SerialNumber" as CFString, "AUX789" as CFString)
        var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "PlantMake", kCGImagePropertyTIFFModel: "PlantModel", kCGImagePropertyTIFFArtist: "Secret Artist",
                kCGImagePropertyTIFFHostComputer: "PlantHost", kCGImagePropertyTIFFOrientation: orientation,
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifBodySerialNumber: "BODY123", kCGImagePropertyExifLensSerialNumber: "LENS456",
                kCGImagePropertyExifCameraOwnerName: "Owner Name", kCGImagePropertyExifUserComment: "a comment",
                kCGImagePropertyExifImageUniqueID: "UNIQUE42",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 41.38, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 2.17, kCGImagePropertyGPSLongitudeRef: "E",
            ],
        ]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        for page in 0 ..< pages {
            let image = try Fixture.gradient(width: width, height: height, deep: false, alpha: false, phase: Double(page), noise: noise)
            CGImageDestinationAddImageAndMetadata(destination, image, xmp, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw EsclopError.other("finalize") }
    }

    /// The planted values found as plain bytes anywhere in `url`: a judge that needs no reader.
    static func inBytes(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return ["unreadable"] }
        return ["Secret Person", "Secret Artist", "Owner Name", "PlantMake", "PlantModel", "PlantHost", "BODY123", "LENS456", "AUX789", "UNIQUE42"]
            .filter { data.range(of: Data($0.utf8)) != nil }
    }

    /// An animated GIF with a comment block and an XMP application block (creator, serial).
    static func plantGIF(_ url: URL, frames: Int = 2, size: Int = 32) throws {
        try Fixture.gif(url, frames: frames, size: size)
        var data = try Data(contentsOf: url)
        guard data.last == 0x3B else { throw EsclopError.other("gif trailer") }
        func subBlocks(_ text: String) -> Data {
            var blocks = Data()
            for chunk in stride(from: 0, to: text.utf8.count, by: 255).map({ Data(text.utf8.dropFirst($0).prefix(255)) }) {
                blocks.append(UInt8(chunk.count))
                blocks.append(chunk)
            }
            return blocks + [0]
        }
        // Short, so every value sits inside the first 255-byte sub-block.
        // An RDF root ImageIO reads (as it reads a real GIF's XMP).
        let xmp = #"<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/""#
            + #" xmlns:aux="http://ns.adobe.com/exif/1.0/aux/" aux:SerialNumber="AUX789"><dc:creator>Secret Person</dc:creator>"#
            + "</rdf:Description></rdf:RDF>"
        let blocks = Data([0x21, 0xFE]) + subBlocks("Taken by Owner Name with BODY123")
            + Data([0x21, 0xFF, 0x0B]) + Data("XMP DataXMP".utf8) + subBlocks(xmp)
        data.insert(contentsOf: blocks, at: data.endIndex - 1)
        try data.write(to: url)
        // A sub-block length byte inside a value would hide it from `inBytes`.
        try #require(Set(inBytes(url)) == ["Secret Person", "Owner Name", "BODY123", "AUX789"], "every planted value is plain bytes")
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
                ("HostComputer", tiff[kCGImagePropertyTIFFHostComputer]), ("ImageUniqueID", exif[kCGImagePropertyExifImageUniqueID]),
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

    /// The decoded pixels of the first image: the same bytes when the coded image is untouched.
    static func pixels(_ url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return image.dataProvider?.data as Data?
    }

    static func icc(_ url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return image.colorSpace?.copyICCData() as Data?
    }

    static let exiftoolURL = ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool", "/usr/bin/exiftool"]
        .map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }

    /// The location, camera, serial, owner and author tags exiftool finds; nil without exiftool.
    static func exiftool(_ url: URL) async throws -> [String]? {
        guard let exiftoolURL else { return nil }
        let result = try await ProcessRunner.run(executable: exiftoolURL, arguments: ["-j", "-G1", "-a", "-s", url.path])
        let tags = (try JSONSerialization.jsonObject(with: result.stdout) as? [[String: Any]])?.first ?? [:]
        let names: Set<String> = [
            "Make", "Model", "SerialNumber", "LensSerialNumber", "OwnerName", "Artist", "Creator", "UserComment", "HostComputer", "ImageUniqueID",
        ]
        return tags.keys.filter { key in
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return false }
            return parts[1].hasPrefix("GPS") || names.contains(parts[1])
        }.sorted()
    }
}
