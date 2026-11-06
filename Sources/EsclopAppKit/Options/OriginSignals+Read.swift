// SPDX-License-Identifier: GPL-3.0-or-later
//
// Gathers the evidence `OriginClassifier` weighs, from the file itself (ImageIO properties,
// Spotlight attributes, PDF info, audio tags) and from the moment of the copy (the app in front,
// the pasteboard types). Reading is best effort: anything that fails stays unknown.

import AVFoundation
import CoreServices
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

extension OriginSignals {
    /// Reads what is known about `file`. Call it before optimising: stripping metadata removes
    /// the screenshot mark.
    static func read(_ file: URL, sourceApp: String? = nil, pasteboardTypes: Set<String> = []) async -> OriginSignals {
        let type = UTType(filenameExtension: file.pathExtension.lowercased())
        var signals = OriginSignals(inputType: type?.identifier ?? "public.data")
        signals.sourceApp = sourceApp
        signals.pasteboardTypes = pasteboardTypes
        signals.fileName = file.deletingPathExtension().lastPathComponent
        signals.folder = file.deletingLastPathComponent().standardizedFileURL.path
        signals.screenshotFolder = screenshotFolder()
        if let item = MDItemCreateWithURL(nil, file as CFURL) {
            if let capture = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? Bool, capture {
                signals.screenshotMetadata = true
            }
            if let froms = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String] {
                signals.downloadedFromWeb = froms.contains { $0.hasPrefix("http") }
            }
            if let creator = MDItemCopyAttribute(item, kMDItemCreator) as? String { signals.audioEncoder = creator }
        }
        if type?.conforms(to: .image) == true { readImage(file, into: &signals) }
        if type?.conforms(to: .pdf) == true, let document = PDFDocument(url: file) {
            let attributes = document.documentAttributes ?? [:]
            signals.pdfCreator = [attributes[PDFDocumentAttribute.creatorAttribute], attributes[PDFDocumentAttribute.producerAttribute]]
                .compactMap { $0 as? String }.joined(separator: " ")
        }
        if type?.conforms(to: .audio) == true, let encoder = await audioEncoder(file) {
            signals.audioEncoder = encoder
        }
        return signals
    }

    private static func readImage(_ file: URL, into signals: inout OriginSignals) {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return }
        signals.frameCount = CGImageSourceGetCount(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let comment = exif[kCGImagePropertyExifUserComment] as? String, comment == "Screenshot"
        {
            signals.screenshotMetadata = true
        }
        signals.hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        if signals.hasAlpha { signals.flatColour = isFlatColour(source) }
    }

    /// Fewer than 512 colours in a 64 pt thumbnail: drawn, not photographed.
    static func isFlatColour(_ source: CGImageSource) -> Bool {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return false }
        let width = image.width, height = image.height
        var pixels = [UInt32](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        return Set(pixels).count < 512
    }

    /// Where screenshots are saved: the `com.apple.screencapture` location, else the Desktop.
    static func screenshotFolder() -> String {
        let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        let path = (location.map { ($0 as NSString).expandingTildeInPath }) ?? (NSHomeDirectory() as NSString).appendingPathComponent("Desktop")
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func audioEncoder(_ file: URL) async -> String? {
        let asset = AVURLAsset(url: file)
        guard let items = try? await asset.load(.metadata) else { return nil }
        for item in items where item.commonKey == .commonKeySoftware || item.identifier == .iTunesMetadataEncodingTool {
            if let value = try? await item.load(.stringValue) { return value }
        }
        return nil
    }
}
