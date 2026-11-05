// SPDX-License-Identifier: GPL-3.0-or-later
//
// Evaluating `if(...)` / `ifNot(...)` conditions against a file.

import AVFoundation
import EsclopCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads what filters ask about a file. Swappable so tests need no real media.
public protocol MediaInspector: Sendable {
    func fileSize(_ url: URL) -> Int?
    func pixelSize(_ url: URL) async -> (width: Int, height: Int)?
    func dpi(_ url: URL) -> Int?
    /// Seconds, for video and audio.
    func duration(_ url: URL) async -> Double?
}

/// ImageIO for images, AVFoundation for video and audio.
public struct SystemMediaInspector: MediaInspector {
    public init() {}

    public func fileSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    public func pixelSize(_ url: URL) async -> (width: Int, height: Int)? {
        if let props = imageProperties(url),
           let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        {
            return (w, h)
        }
        guard MediaKind.of(url) == .video else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform)
        else { return nil }
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        return (Int(abs(rect.width).rounded()), Int(abs(rect.height).rounded()))
    }

    public func dpi(_ url: URL) -> Int? {
        guard let props = imageProperties(url) else { return nil }
        for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let dpi = (props[key] as? NSNumber)?.intValue, dpi > 0 { return dpi }
        }
        return nil
    }

    public func duration(_ url: URL) async -> Double? {
        guard let kind = MediaKind.of(url), kind == .video || kind == .audio else { return nil }
        guard let time = try? await AVURLAsset(url: url).load(.duration), time.isNumeric else { return nil }
        return time.seconds
    }

    private func imageProperties(_ url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }
}

extension FilterCondition {
    /// Whether the file meets every set key, and the regex capture groups when it does.
    /// `sourceApp` is the name or bundle id of the app the clipboard content came from.
    public func evaluate(_ file: URL, inspector: any MediaInspector, sourceApp: String? = nil) async -> (matches: Bool, captures: [String]) {
        let name = file.lastPathComponent
        let no: (Bool, [String]) = (false, [])
        var captures: [String] = []

        if let types, !types.isEmpty {
            guard types.contains(where: { Self.file(file, isOfType: $0) }) else { return no }
        }
        if let regex, !regex.isEmpty {
            // Smart case: case-insensitive unless the pattern has an upper-case letter outside an escape.
            let literals = regex.replacingOccurrences(of: #"\\."#, with: "", options: .regularExpression)
            let options: NSRegularExpression.Options = literals.contains(where: \.isUppercase) ? [] : [.caseInsensitive]
            guard let re = try? NSRegularExpression(pattern: regex, options: options),
                  let match = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name))
            else { return no }
            for i in 1 ..< match.numberOfRanges {
                captures.append(Range(match.range(at: i), in: name).map { String(name[$0]) } ?? "")
            }
        }
        if let nameContains, !nameContains.isEmpty, !name.localizedCaseInsensitiveContains(nameContains) { return no }
        if let nameIs, !nameIs.isEmpty, name != nameIs { return no }

        if fileSizeGreaterThan != nil || fileSizeLowerThan != nil || minFileSize != nil {
            guard let size = inspector.fileSize(file) else { return no }
            if let v = fileSizeGreaterThan, !(size > v) { return no }
            if let v = fileSizeLowerThan, !(size < v) { return no }
            if let v = minFileSize, !(size >= v) { return no }
        }
        if widthGreaterThan != nil || widthLowerThan != nil || heightGreaterThan != nil || heightLowerThan != nil || minResolution != nil {
            guard let (w, h) = await inspector.pixelSize(file) else { return no }
            if let v = widthGreaterThan, !(w > v) { return no }
            if let v = widthLowerThan, !(w < v) { return no }
            if let v = heightGreaterThan, !(h > v) { return no }
            if let v = heightLowerThan, !(h < v) { return no }
            if let v = minResolution, !(w >= v && h >= v) { return no }
        }
        if dpiGreaterThan != nil || dpiLowerThan != nil {
            guard let dpi = inspector.dpi(file) else { return no }
            if let v = dpiGreaterThan, !(dpi > v) { return no }
            if let v = dpiLowerThan, !(dpi < v) { return no }
        }
        if durationGreaterThan != nil || durationLowerThan != nil {
            guard let d = await inspector.duration(file) else { return no }
            if let v = durationGreaterThan, !(d > v) { return no }
            if let v = durationLowerThan, !(d < v) { return no }
        }
        if let copiedBy, !copiedBy.isEmpty {
            guard let sourceApp, sourceApp.lowercased().contains(copiedBy.lowercased()) else { return no }
        }
        return (true, captures)
    }

    /// `image`, `video`, `pdf`, `audio`, an extension (`png`) or a UTType identifier (`public.jpeg`).
    static func file(_ url: URL, isOfType type: String) -> Bool {
        if let kind = MediaKind(rawValue: type.lowercased()) { return MediaKind.of(url) == kind }
        guard let fileType = UTType(filenameExtension: url.pathExtension.lowercased()),
              let wanted = UTType(type) ?? UTType(filenameExtension: type.lowercased())
        else { return false }
        return fileType.conforms(to: wanted)
    }
}
