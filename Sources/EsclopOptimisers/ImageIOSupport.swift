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
            bitDepth: properties[kCGImagePropertyDepth] as? Int ?? 8
        )
    }
}

enum ImageIOCodec {
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

    /// Writes `image` as `type`. `metadataFrom` copies EXIF/GPS/XMP from another file unless
    /// `strip`; the orientation is reset because the pixels are already upright.
    static func write(
        _ image: CGImage, to url: URL, type: UTType, quality: Double?, metadataFrom: URL? = nil, strip: Bool
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
        properties[kCGImagePropertyOrientation] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        if type == .tiff {
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] // LZW
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw EsclopError.other("Could not write \(url.lastPathComponent)")
        }
    }

    /// Decodes anything macOS reads (HEIC, JPEG XL, AVIF, TIFF...) to an upright PNG the engine
    /// can take.
    static func decodeToPNG(_ source: URL, to url: URL) throws {
        let image = try uprightImage(source)
        try write(image, to: url, type: .png, quality: nil, metadataFrom: nil, strip: true)
    }

    /// Rewrites metadata without re-encoding pixels (JPEG, PNG, TIFF, HEIC): drops EXIF, GPS,
    /// XMP and IPTC, keeps the orientation (and the colour profile, which is not metadata here).
    static func stripMetadata(_ source: URL, to url: URL) throws {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil), let typeID = CGImageSourceGetType(input),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, typeID, 1, nil)
        else { throw EsclopError.unsupportedFile(source.lastPathComponent) }
        let orientation = (CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int ?? 1
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
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, input, options as CFDictionary, &error) else {
            let reason = error.map { ($0.takeRetainedValue() as Error).localizedDescription } ?? "unknown error"
            throw EsclopError.other("Could not rewrite the metadata of \(source.lastPathComponent): \(reason)")
        }
    }

    // MARK: HDR

    /// The auxiliary data type of the gain map in `source`, if it has one.
    static func gainMapType(_ source: CGImageSource) -> CFString? {
        var types = [kCGImageAuxiliaryDataTypeHDRGainMap]
        if #available(macOS 15, *) { types.insert(kCGImageAuxiliaryDataTypeISOGainMap, at: 0) }
        return types.first { CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil }
    }

    /// Re-encodes at the same size, carrying the gain map across. JPEG and HEIC hold gain maps.
    static func reencodeKeepingGainMap(_ url: URL, to output: URL, type: UTType, quality: Double, strip: Bool) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil)
        else { throw EsclopError.unsupportedFile(url.lastPathComponent) }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if strip {
            let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            properties[kCGImagePropertyExifDictionary] = kCFNull
            properties[kCGImagePropertyGPSDictionary] = kCFNull
            properties[kCGImagePropertyIPTCDictionary] = kCFNull
            properties[kCGImagePropertyOrientation] = original?[kCGImagePropertyOrientation] ?? 1
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        if let auxType = gainMapType(source), let aux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, auxType) {
            CGImageDestinationAddAuxiliaryDataInfo(destination, auxType, aux)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw EsclopError.other("Could not write \(output.lastPathComponent)")
        }
    }

    /// Crops and scales an HDR photo and writes it with a gain map rebuilt from the HDR pixels.
    @available(macOS 15, *)
    static func renderHDR(_ url: URL, crop: CGRect?, width: Int, height: Int, to output: URL, type: UTType, quality: Double) throws {
        guard var hdr = CIImage(contentsOf: url, options: [.expandToHDR: true, .applyOrientationProperty: true]) else {
            throw EsclopError.unsupportedFile(url.lastPathComponent)
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
        let sdr = hdr.applyingFilter("CIToneMapHeadroom", parameters: ["inputTargetHeadroom": 1.0])
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
