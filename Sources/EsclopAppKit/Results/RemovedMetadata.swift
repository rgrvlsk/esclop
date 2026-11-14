// SPDX-License-Identifier: GPL-3.0-or-later
//
// What optimising took from a picture's metadata, for the detail's "Removed" strip
// (docs/design/targets: pr2-detail-card). Worked out as a difference: the kinds in the original
// minus the kinds in the result. That stays true whatever path the engine took and whatever the
// strip setting was, and it needs no record from the engine.

import EsclopCore
import Foundation
import ImageIO

/// The person's own facts a picture can carry.
public enum MetadataKind: String, CaseIterable, Sendable {
    /// GPS coordinates.
    case location
    /// The camera's or phone's make and model, or the lens.
    case camera
    /// When the picture was taken.
    case date

    public var symbol: String {
        switch self {
        case .location: return "mappin"
        case .camera: return "camera"
        case .date: return "calendar"
        }
    }
}

enum RemovedMetadata {
    /// The kinds in `original` that `output` no longer carries, in `MetadataKind` order.
    static func between(original: URL, output: URL) -> [MetadataKind] {
        let before = kinds(in: original)
        guard !before.isEmpty else { return [] }
        let after = kinds(in: output)
        return MetadataKind.allCases.filter { before.contains($0) && !after.contains($0) }
    }

    static func kinds(in url: URL) -> Set<MetadataKind> {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return [] }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var kinds: Set<MetadataKind> = []
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any], !gps.isEmpty { kinds.insert(.location) }
        if tiff[kCGImagePropertyTIFFMake] != nil || tiff[kCGImagePropertyTIFFModel] != nil || exif[kCGImagePropertyExifLensModel] != nil {
            kinds.insert(.camera)
        }
        if exif[kCGImagePropertyExifDateTimeOriginal] != nil || exif[kCGImagePropertyExifDateTimeDigitized] != nil { kinds.insert(.date) }
        return kinds
    }

    /// The file to compare a result with: its backup, or its source when the result is a new
    /// file. Pictures only, and never a copied image: L'Esclop wrote that file from pasted pixels,
    /// so nothing of the person's was in it.
    static func original(of result: OptimisationResult, origin: RequestOrigin) -> URL? {
        guard result.kind == .image, origin != .clipboard else { return nil }
        if let backup = result.backup { return backup }
        return result.output.standardizedFileURL == result.source.standardizedFileURL ? nil : result.source
    }
}
