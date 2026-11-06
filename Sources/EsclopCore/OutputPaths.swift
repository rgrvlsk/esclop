// SPDX-License-Identifier: GPL-3.0-or-later
//
// Turns an `OutputLocation` into a file URL. Shared by the engines, the CLI (to preview where
// things land) and pipelines, so a template means the same thing everywhere.
//
// Templates: `%f` the source name without extension, `%e` the output extension, `%d` the
// source's folder, a leading `~` the home folder. A template ending in `/`, or naming an existing
// folder, receives `<name>.<extension>`; a template without an extension gets one. Relative
// templates are relative to the source's folder.

import CoreFoundation
import CoreGraphics
import Foundation

public extension OutputLocation {
    /// Where the result of processing `source` into a file with extension `ext` goes.
    /// `.sameFolder` never overwrites an existing file; `.path` does (the person named it).
    func destination(
        for source: URL, extension ext: String,
        sameFolderTemplate: String = "%f-optimised", temporaryRoot: URL = Paths.temporary
    ) -> URL {
        let folder = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        switch self {
        case .inPlace:
            return folder.appendingPathComponent(stem).appendingPathExtension(ext)
        case .sameFolder:
            let name = Self.expand(sameFolderTemplate, stem: stem, ext: ext, folder: folder)
            var candidate = folder.appendingPathComponent(name).appendingPathExtension(ext)
            if candidate.standardizedFileURL.path == source.standardizedFileURL.path {
                candidate = folder.appendingPathComponent("\(name)-optimised").appendingPathExtension(ext)
            }
            return Self.unique(candidate)
        case .temporary:
            let unique = String(UUID().uuidString.prefix(8))
            return temporaryRoot.appendingPathComponent("results/\(unique)", isDirectory: true)
                .appendingPathComponent(stem).appendingPathExtension(ext)
        case let .path(template):
            let expanded = Self.expand(template, stem: stem, ext: ext, folder: folder)
            var url = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded)
                : folder.appendingPathComponent(expanded)
            var isDirectory: ObjCBool = false
            if template.hasSuffix("/") || (FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue) {
                url = url.appendingPathComponent(stem).appendingPathExtension(ext)
            } else if url.pathExtension.isEmpty {
                url = url.appendingPathExtension(ext)
            }
            return url.standardizedFileURL
        }
    }

    static func expand(_ template: String, stem: String, ext: String, folder: URL) -> String {
        var text = template
        if text == "~" || text.hasPrefix("~/") {
            text = FileManager.default.homeDirectoryForCurrentUser.path + text.dropFirst()
        }
        return text
            .replacingOccurrences(of: "%f", with: stem)
            .replacingOccurrences(of: "%e", with: ext)
            .replacingOccurrences(of: "%d", with: folder.path)
    }

    /// `name.ext`, else `name 2.ext`, `name 3.ext`...
    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for n in 2 ... 10000 {
            let candidate = folder.appendingPathComponent("\(stem) \(n)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return folder.appendingPathComponent("\(stem) \(UUID().uuidString)").appendingPathExtension(ext)
    }
}

public extension CropSize {
    /// "16:9" -> 1.777..., "1.5" -> 1.5. nil when absent or malformed.
    var aspectRatioValue: Double? {
        guard let text = aspectRatio?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == "/" || $0 == "x" })
        if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 {
            return w / h
        }
        if parts.count == 1, let value = Double(parts[0]), value > 0 { return value }
        return nil
    }

    /// The pixel size this crop produces from an image of `width` x `height`: aspect ratio crops
    /// keep as much of the image as fits, `longEdge` scales the longer side, a single width or
    /// height keeps the aspect, both crop to fill.
    func targetSize(fromWidth width: Int, height: Int) -> (width: Int, height: Int) {
        if let region = region(inWidth: width, height: height) {
            let scaling = CropSize(width: self.width, height: self.height, longEdge: longEdge)
            return scaling.targetSize(fromWidth: Int(region.width), height: Int(region.height))
        }
        let w = Double(width)
        let h = Double(height)
        if let ratio = aspectRatioValue {
            var cw = w
            var ch = w / ratio
            if ch > h {
                ch = h
                cw = h * ratio
            }
            if let longEdge, longEdge > 0 {
                let scale = Double(longEdge) / max(cw, ch)
                if scale < 1 {
                    cw *= scale
                    ch *= scale
                }
            } else if let tw = self.width, tw > 0, Double(tw) < cw {
                ch = ch * Double(tw) / cw
                cw = Double(tw)
            } else if let th = self.height, th > 0, Double(th) < ch {
                cw = cw * Double(th) / ch
                ch = Double(th)
            }
            return (max(1, Int(cw.rounded())), max(1, Int(ch.rounded())))
        }
        if let longEdge, longEdge > 0 {
            let scale = min(1, Double(longEdge) / max(w, h))
            return (max(1, Int((w * scale).rounded())), max(1, Int((h * scale).rounded())))
        }
        switch (self.width, self.height) {
        case let (tw?, th?) where tw > 0 && th > 0:
            return (tw, th)
        case let (tw?, _) where tw > 0:
            return (tw, max(1, Int((h * Double(tw) / w).rounded())))
        case let (_, th?) where th > 0:
            return (max(1, Int((w * Double(th) / h).rounded())), th)
        default:
            return (width, height)
        }
    }

    /// The free crop clamped inside a `width` x `height` image; nil without one or when it
    /// leaves nothing.
    func region(inWidth width: Int, height: Int) -> CGRect? {
        guard let rect else { return nil }
        let clamped = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }
        return clamped.integral
    }

    /// Whether the result changes the aspect ratio (a real crop) rather than only scaling.
    func cropsAspect(fromWidth width: Int, height: Int) -> Bool {
        if let region = region(inWidth: width, height: height) {
            return region.size != CGSize(width: width, height: height)
        }
        let target = targetSize(fromWidth: width, height: height)
        let before = Double(width) / Double(height)
        let after = Double(target.width) / Double(target.height)
        return abs(before - after) > 0.01
    }
}
