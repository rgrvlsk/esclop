// SPDX-License-Identifier: GPL-3.0-or-later
//
// The image work that stays in Swift: probing any format macOS reads, HEIC/TIFF/BMP encoding,
// decoding HEIC, JPEG XL and AVIF for the engine, lossless metadata rewrites, and HDR gain maps
// (copied through on re-encodes, rebuilt with Core Image when the size changes, macOS 15+).

import CoreImage
import EsclopCore
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

struct ImageInfo: Sendable {
    var type: UTType
    var format: OutputFormat?
    /// Displayed size (orientation applied).
    var width: Int
    var height: Int
    var orientation: Int
    var hasAlpha: Bool
    var frameCount: Int
    var hasGainMap: Bool
    var bitDepth: Int
    /// Pixels per inch; 72 when the file does not say. 144 is a 2x (Retina) screenshot.
    var dpi: Double = 72
    /// The EXIF `UserComment` "Screenshot" that macOS writes into screenshots, saved or copied.
    // ponytail: screenshots from tools that do not write it are not halved.
    // If people ask for those, also count an image in the watched screenshot folder.
    var isScreenshot = false

    var isAnimated: Bool { frameCount > 1 }

    static func probe(_ url: URL) -> ImageInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let typeID = CGImageSourceGetType(source) as String?, let type = UTType(typeID),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? Int,
              var height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        if orientation >= 5 { swap(&width, &height) }
        return ImageInfo(
            type: type, format: OutputFormat.of(type: type), width: width, height: height, orientation: orientation,
            hasAlpha: properties[kCGImagePropertyHasAlpha] as? Bool ?? false,
            frameCount: CGImageSourceGetCount(source),
            hasGainMap: ImageIOCodec.gainMapType(source) != nil,
            bitDepth: properties[kCGImagePropertyDepth] as? Int ?? 8,
            dpi: (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72,
            isScreenshot: (properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] as? String == "Screenshot"
        )
    }
}

enum ImageIOCodec {
    /// Sets the density of a PNG, JPEG or TIFF without re-encoding it: a PNG's `pHYs` (added
    /// when missing) and the resolution in its `eXIf`, else the resolution tags through ImageIO.
    /// ponytail: HEIC, WebP, AVIF and BMP keep theirs (ImageIO cannot rewrite it without
    /// re-encoding; WebP and AVIF have none outside EXIF); `write` gives HEIC its density. One
    /// value for both axes, whole dots per inch: a 204x196 dpi fax scan comes out 204x204.
    static func setDensity(_ url: URL, dpi: Double) {
        guard var data = try? Data(contentsOf: url) else { return }
        guard data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return setDensityThroughImageIO(url, dpi: dpi) }
        let perMetre = UInt32((dpi / 0.0254).rounded())
        let phys = withUnsafeBytes(of: perMetre.bigEndian, Array.init) + withUnsafeBytes(of: perMetre.bigEndian, Array.init) + [1]
        var offset = 8
        var hasPhys = false
        var changed = false
        while offset + 12 <= data.count {
            let length = data[offset ..< offset + 4].reduce(0) { $0 << 8 | Int($1) }
            let name = String(decoding: data[offset + 4 ..< offset + 8], as: UTF8.self)
            guard name != "IDAT", offset + 12 + length <= data.count else { break }
            let body = offset + 8 ..< offset + 8 + length
            if name == "pHYs", length == 9 {
                data.replaceSubrange(body, with: phys)
                hasPhys = true
                changed = true
            } else if name == "eXIf" {
                var exif = Data(data[body])
                if setTIFFResolution(&exif, dpi: UInt32(dpi.rounded())) { data.replaceSubrange(body, with: exif); changed = true }
            }
            let crc = crc32(data[offset + 4 ..< body.upperBound])
            data.replaceSubrange(body.upperBound ..< body.upperBound + 4, with: withUnsafeBytes(of: crc.bigEndian, Array.init))
            offset += 12 + length
        }
        if !hasPhys, data.count > 33 {
            // After IHDR (8 bytes of signature, then 25 of IHDR), before any IDAT.
            let chunk = Data(withUnsafeBytes(of: UInt32(9).bigEndian, Array.init) + Array("pHYs".utf8) + phys)
            data.insert(contentsOf: chunk + withUnsafeBytes(of: crc32(chunk.dropFirst(4)).bigEndian, Array.init), at: 33)
            changed = true
        }
        if changed { try? data.write(to: url, options: .atomic) }
    }

    /// XResolution and YResolution of a TIFF/EXIF block's first directory set to `dpi`/1, in place.
    static func setTIFFResolution(_ tiff: inout Data, dpi: UInt32) -> Bool {
        guard tiff.count >= 8 else { return false }
        let little = tiff[0] == 0x49
        func read(_ at: Int, _ size: Int) -> Int? {
            guard at >= 0, at + size <= tiff.count else { return nil }
            let bytes = tiff[at ..< at + size]
            return (little ? bytes.reversed() : Array(bytes)).reduce(0) { $0 << 8 | Int($1) }
        }
        func write32(_ value: UInt32, at: Int) {
            tiff.replaceSubrange(at ..< at + 4, with: withUnsafeBytes(of: little ? value.littleEndian : value.bigEndian, Array.init))
        }
        guard let ifd = read(4, 4), let count = read(ifd, 2) else { return false }
        var changed = false
        for index in 0 ..< count {
            let entry = ifd + 2 + index * 12
            guard let tag = read(entry, 2), let type = read(entry + 2, 2), let value = read(entry + 8, 4) else { break }
            guard tag == 0x011A || tag == 0x011B, type == 5, value + 8 <= tiff.count else { continue }
            write32(dpi, at: value)
            write32(1, at: value + 4)
            changed = true
        }
        return changed
    }

    private static func setDensityThroughImageIO(_ url: URL, dpi: Double) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else { return }
        let staging = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).dpi")
        guard let destination = CGImageDestinationCreateWithURL(staging as CFURL, type, 1, nil) else { return }
        let metadata = CGImageMetadataCreateMutable()
        let value = "\(Int(dpi.rounded()))"
        for (key, value) in [(kCGImagePropertyTIFFXResolution, value), (kCGImagePropertyTIFFYResolution, value), (kCGImagePropertyTIFFResolutionUnit, "2")] {
            CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, key, value as CFString)
        }
        let options = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true] as CFDictionary
        if CGImageDestinationCopyImageSource(destination, source, options, nil) {
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: staging)
        }
        try? FileManager.default.removeItem(at: staging)
    }

    static func crc32(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    /// Formats the system can write.
    static func canWrite(_ type: UTType) -> Bool {
        let identifiers = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return identifiers.contains(type.identifier)
    }

    /// The upright, full-size image (EXIF orientation applied).
    static func uprightImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let info = ImageInfo.probe(url)
        else { throw EsclopError.unsupportedFile(url.lastPathComponent) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(info.width, info.height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw EsclopError.unsupportedFile("Could not decode \(url.lastPathComponent)")
        }
        return image
    }

    /// Crops (in displayed pixels) and scales an image with high-quality interpolation.
    static func render(_ image: CGImage, crop: CGRect?, width: Int, height: Int) throws -> CGImage {
        var image = image
        if let crop {
            let rect = crop.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let cropped = image.cropping(to: rect) else {
                throw EsclopError.invalidArgument("Crop rectangle outside the image")
            }
            image = cropped
        }
        if image.width == width, image.height == height { return image }
        let space = image.colorSpace.flatMap { $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let deep = image.bitsPerComponent > 8
        let info = deep
            ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: deep ? 16 : 8, bytesPerRow: 0,
            space: space, bitmapInfo: info
        ) else { throw EsclopError.other("Could not create a \(width)x\(height) canvas") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw EsclopError.other("Could not scale the image") }
        return scaled
    }

    /// Writes `image` as `type` at `dpi` when given. `metadataFrom` copies EXIF/GPS/IPTC from
    /// another file unless `strip`; the orientation is reset because the pixels are already upright.
    static func write(
        _ image: CGImage, to url: URL, type: UTType, quality: Double?, metadataFrom: URL? = nil, strip: Bool, dpi: Double? = nil
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw EsclopError.unsupportedFile("This Mac cannot write \(type.preferredFilenameExtension ?? type.identifier)")
        }
        var properties: [CFString: Any] = [:]
        if !strip, let metadataFrom, let source = CGImageSourceCreateWithURL(metadataFrom as CFURL, nil),
           let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary] {
                if let value = original[key] { properties[key] = value }
            }
        }
        // The density describes the picture, not the person: it stays when stripping.
        if let dpi {
            properties[kCGImagePropertyDPIWidth] = dpi
            properties[kCGImagePropertyDPIHeight] = dpi
        }
        properties[kCGImagePropertyOrientation] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        if type == .tiff {
            var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = 5 // LZW
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw EsclopError.other("Could not write \(url.lastPathComponent)")
        }
    }

    /// Decodes anything macOS reads (HEIC, JPEG XL, AVIF, TIFF...) to an upright PNG the engine
    /// can take, with the EXIF (GPS included) in its eXIf chunk unless `strip`, so the engine
    /// carries it into WebP and AVIF.
    static func decodeToPNG(_ source: URL, to url: URL, strip: Bool, dpi: Double) throws {
        let image = try uprightImage(source)
        try write(image, to: url, type: .png, quality: nil, metadataFrom: source, strip: strip, dpi: dpi)
    }

    /// Removes EXIF, GPS, XMP and IPTC, keeping the orientation, density, colour profile, every
    /// page, the gain map and a portrait's depth and mattes, without touching pixels: HEIC and
    /// AVIF by blanking their Exif and XMP items (`HEIFMetadata`), the rest with ImageIO. ImageIO
    /// cannot do it for HEIC, TIFF or AVIF (it writes the HEIC back unchanged and reports
    /// success), so when anything personal is still there it re-encodes at the highest quality.
    /// Returns whether it re-encoded; the caller reads the result back with `personalMetadata`.
    @discardableResult
    static func stripMetadata(_ source: URL, to url: URL) throws -> Bool {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil), let typeID = CGImageSourceGetType(input),
              let type = UTType(typeID as String)
        else { throw EsclopError.unsupportedFile(source.lastPathComponent) }
        let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        if heifTypes.contains(type), let data = try? Data(contentsOf: source),
           let blanked = HEIFMetadata.blanked(
               data, orientation: (properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFOrientation] as? Int,
               dpi: properties[kCGImagePropertyDPIWidth] as? Double
           )
        {
            try blanked.write(to: url)
            if personalMetadata(url).isEmpty { return false }
        }
        let metadata = CGImageMetadataCreateMutable()
        if orientation != 1 {
            CGImageMetadataSetValueMatchingImageProperty(
                metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation as CFNumber
            )
        }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeXMP: true,
            kCGImageMetadataShouldExcludeGPS: true,
        ]
        if CGImageSourceGetCount(input) == 1, let destination = CGImageDestinationCreateWithURL(url as CFURL, typeID, 1, nil),
           CGImageDestinationCopyImageSource(destination, input, options as CFDictionary, nil), personalMetadata(url).isEmpty
        {
            return false
        }
        guard canWrite(type) else {
            let name = (type.preferredFilenameExtension ?? source.pathExtension).uppercased()
            throw EsclopError.unsupportedFile("This Mac cannot remove the metadata of \(name) files")
        }
        // ImageIO's AVIF writer refuses quality 1 ("Could not write").
        try reencode(source, to: url, type: type, quality: type.identifier == "public.avif" ? 0.99 : 1, strip: true, keepGainMap: true, keepDepth: true)
        return true
    }

    /// The ISO base media formats whose metadata `HEIFMetadata` removes.
    static let heifTypes: [UTType] = [.heic, .heif] + [UTType("public.avif")].compactMap { $0 }

    /// What in `url` tells where, with what, when or by whom a picture was taken, on any page:
    /// any GPS, IPTC, maker note or EXIF aux tag, and any EXIF, TIFF or XMP tag that is not purely
    /// technical (`technicalTags`). An allowlist, so a tag nobody thought of counts as personal.
    /// Empty when there is none. Reads the result of every strip.
    static func personalMetadata(_ url: URL) -> [String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        var found: [String] = []
        func note(_ name: String) { if !found.contains(name) { found.append(name) } }
        func check(_ dictionary: [CFString: Any], _ group: String, technical: Set<String>) {
            for key in (dictionary.keys.map { $0 as String }).sorted() where !technical.contains(key) {
                note(personalTagNames[key] ?? "\(group) \(key)")
            }
        }
        for index in 0 ..< CGImageSourceGetCount(source) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any], !gps.isEmpty { note("location") }
            check(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:], "TIFF", technical: technicalTags["tiff"]!)
            check(properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:], "EXIF", technical: technicalTags["exif"]!)
            check(properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:], "EXIF", technical: [])
            if makerDictionaries.contains(where: { properties[$0] != nil }) { note("maker notes") }
            if let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any], !iptc.isEmpty { note("IPTC") }
            // XMP shows the EXIF and TIFF tags again under their own prefixes, and ImageIO's
            // `iio` flags say which blocks it read.
            let tags = CGImageSourceCopyMetadataAtIndex(source, index, nil).flatMap { CGImageMetadataCopyTags($0) as? [CGImageMetadataTag] } ?? []
            for tag in tags {
                let prefix = CGImageMetadataTagCopyPrefix(tag) as String? ?? ""
                let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
                if prefix != "iio", technicalTags[prefix]?.contains(name) != true { note("XMP") }
            }
        }
        return found
    }

    /// The EXIF and TIFF tags (by XMP prefix) that describe only how the pixels are stored and
    /// shown: dimensions, orientation, colour space, density, compression, bits.
    static let technicalTags: [String: Set<String>] = [
        "tiff": Set([
            kCGImagePropertyTIFFOrientation, kCGImagePropertyTIFFXResolution, kCGImagePropertyTIFFYResolution,
            kCGImagePropertyTIFFResolutionUnit, kCGImagePropertyTIFFCompression, kCGImagePropertyTIFFPhotometricInterpretation,
            kCGImagePropertyTIFFTileWidth, kCGImagePropertyTIFFTileLength, kCGImagePropertyTIFFPrimaryChromaticities,
            kCGImagePropertyTIFFWhitePoint, kCGImagePropertyTIFFTransferFunction,
        ].map { $0 as String }),
        "exif": Set([
            kCGImagePropertyExifColorSpace, kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension,
            kCGImagePropertyExifVersion, kCGImagePropertyExifFlashPixVersion, kCGImagePropertyExifComponentsConfiguration,
            kCGImagePropertyExifGamma, kCGImagePropertyExifCompressedBitsPerPixel,
        ].map { $0 as String }),
    ]

    /// Plain names for the personal tags people know, in the read-back's message.
    static let personalTagNames: [String: String] = [
        "Make": "camera", "Model": "camera", "LensMake": "camera", "LensModel": "camera", "HostComputer": "camera",
        "Artist": "author", "Copyright": "author",
        "BodySerialNumber": "serial number", "LensSerialNumber": "serial number", "SerialNumber": "serial number",
        "CameraOwnerName": "owner", "OwnerName": "owner", "UserComment": "comment",
    ]

    /// The camera makers' own dictionaries.
    static var makerDictionaries: [CFString] { [
        kCGImagePropertyMakerAppleDictionary, kCGImagePropertyMakerCanonDictionary, kCGImagePropertyMakerNikonDictionary,
        kCGImagePropertyMakerMinoltaDictionary, kCGImagePropertyMakerFujiDictionary, kCGImagePropertyMakerOlympusDictionary,
        kCGImagePropertyMakerPentaxDictionary,
    ] }

    // MARK: HDR

    /// The auxiliary data type of the gain map in `source`, if it has one.
    static func gainMapType(_ source: CGImageSource) -> CFString? {
        var types = [kCGImageAuxiliaryDataTypeHDRGainMap]
        if #available(macOS 15, *) { types.insert(kCGImageAuxiliaryDataTypeISOGainMap, at: 0) }
        return types.first { CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil }
    }

    /// Re-encodes every image at the same size (all pages of a multi-page TIFF, LZW), carrying
    /// the gain map across when `keepGainMap`, and a portrait's depth and mattes when `keepDepth`.
    /// JPEG and HEIC hold gain maps.
    static func reencode(_ url: URL, to output: URL, type: UTType, quality: Double, strip: Bool, keepGainMap: Bool, keepDepth: Bool = false) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw EsclopError.unsupportedFile(url.lastPathComponent) }
        let count = CGImageSourceGetCount(source)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, count, nil) else {
            throw EsclopError.unsupportedFile(url.lastPathComponent)
        }
        for index in 0 ..< count {
            let original = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
            if strip {
                for key in [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary]
                    + makerDictionaries
                { properties[key] = kCFNull }
                properties[kCGImagePropertyOrientation] = original?[kCGImagePropertyOrientation] ?? 1
            }
            var tiff = original?[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            if type == .tiff { tiff[kCGImagePropertyTIFFCompression] = 5 } // LZW
            if strip {
                // The camera and author tags of every type (HEIC and JPEG carry them too).
                // `personalMetadata` reads what stays after a strip.
                for tag in [
                    kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright, kCGImagePropertyTIFFDateTime,
                    kCGImagePropertyTIFFDocumentName, kCGImagePropertyTIFFHostComputer, kCGImagePropertyTIFFImageDescription,
                    kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware,
                ] { tiff[tag] = kCFNull }
            }
            if type == .tiff || strip { properties[kCGImagePropertyTIFFDictionary] = tiff }
            CGImageDestinationAddImageFromSource(destination, source, index, properties as CFDictionary)
        }
        if keepGainMap, let auxType = gainMapType(source), let aux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, auxType) {
            CGImageDestinationAddAuxiliaryDataInfo(destination, auxType, aux)
        }
        if keepDepth {
            for auxType in [
                kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypePortraitEffectsMatte,
                kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,
                kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte,
                kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte,
            ] {
                if let aux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, auxType) {
                    CGImageDestinationAddAuxiliaryDataInfo(destination, auxType, aux)
                }
            }
        }
        guard CGImageDestinationFinalize(destination) else {
            throw EsclopError.other("Could not write \(output.lastPathComponent)")
        }
    }

    /// Crops and scales an HDR photo and writes it with a gain map rebuilt from the HDR pixels.
    /// Core Image writes the source's metadata as it comes: GPS, EXIF and camera tags go unless
    /// `strip` says otherwise; the pixels are upright, so the orientation is 1.
    @available(macOS 15, *)
    static func renderHDR(_ url: URL, crop: CGRect?, width: Int, height: Int, to output: URL, type: UTType, quality: Double, strip: Bool) throws {
        guard var hdr = CIImage(contentsOf: url, options: [.expandToHDR: true, .applyOrientationProperty: true]) else {
            throw EsclopError.unsupportedFile(url.lastPathComponent)
        }
        var properties = strip ? [:] : hdr.properties
        properties[kCGImagePropertyOrientation as String] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if let crop {
            // Core Image's origin is bottom-left.
            let flipped = CGRect(x: crop.minX, y: hdr.extent.height - crop.maxY, width: crop.width, height: crop.height)
            hdr = hdr.cropped(to: flipped).transformed(by: CGAffineTransform(translationX: -flipped.minX, y: -flipped.minY))
        }
        let sx = Double(width) / hdr.extent.width
        let sy = Double(height) / hdr.extent.height
        hdr = hdr.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
        hdr = hdr.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let sdr = hdr.applyingFilter("CIToneMapHeadroom", parameters: ["inputTargetHeadroom": 1.0]).settingProperties(properties)
        let context = CIContext()
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        let options: [CIImageRepresentationOption: Any] = [
            .hdrImage: hdr,
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
        ]
        if type == .heic {
            try context.writeHEIFRepresentation(of: sdr, to: output, format: .RGBA8, colorSpace: space, options: options)
        } else {
            try context.writeJPEGRepresentation(of: sdr, to: output, colorSpace: space, options: options)
        }
    }

    // MARK: Smart crop

    /// A crop of `aspect` (width / height) inside a `width` x `height` image, centred on what
    /// Vision finds salient when `smart`, else centred.
    static func cropRect(for url: URL?, width: Int, height: Int, aspect: Double, smart: Bool) -> CGRect {
        let w = Double(width)
        let h = Double(height)
        var cw = w
        var ch = w / aspect
        if ch > h {
            ch = h
            cw = h * aspect
        }
        var center = CGPoint(x: w / 2, y: h / 2)
        if smart, let url, let focus = salientCenter(url) {
            center = CGPoint(x: focus.x * w, y: focus.y * h)
        }
        let x = min(max(0, center.x - cw / 2), w - cw)
        let y = min(max(0, center.y - ch / 2), h - ch)
        return CGRect(x: x.rounded(), y: y.rounded(), width: cw.rounded(), height: ch.rounded())
    }

    /// Centre of the salient objects, normalised with the origin at the top left.
    static func salientCenter(_ url: URL) -> CGPoint? {
        guard let image = try? uprightImage(url) else { return nil }
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first,
              let objects = observation.salientObjects, !objects.isEmpty
        else { return nil }
        let union = objects.map(\.boundingBox).reduce(CGRect.null) { $0.union($1) }
        // Vision's origin is bottom-left.
        return CGPoint(x: union.midX, y: 1 - union.midY)
    }
}
