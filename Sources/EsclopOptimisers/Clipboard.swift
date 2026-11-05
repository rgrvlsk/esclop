// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reading what was copied and putting results back. The engines own the pasteboard formats, so
// the app's clipboard watcher, the CLI (`esclop optimise --clipboard`) and pipelines'
// `copyToClipboard` agree on them. Every write carries `dev.esclop.optimised`, a private type the
// watcher checks so it never optimises its own writes.

import AppKit
import EsclopCore
import Foundation
import UniformTypeIdentifiers

public enum ClipboardContent: Sendable, Equatable {
    /// Files copied in Finder (or a file URL from any app).
    case files([URL])
    /// Image bytes with their type (screenshots copied with ⌃⇧⌘4, images copied in browsers).
    case image(Data, UTType)
    /// Text that is a path to an existing file.
    case path(URL)
    /// Text that is a `data:image/...;base64,` URL.
    case base64Image(Data, UTType)
    case empty
}

public enum Clipboard {
    /// Marks pasteboard items esclop wrote.
    public static let optimisedType = NSPasteboard.PasteboardType("dev.esclop.optimised")

    /// Image types in preference order. GIF first: an animated GIF often travels with a still
    /// PNG or TIFF preview, and the preview would lose the animation.
    static let imageTypes: [(NSPasteboard.PasteboardType, UTType)] = [
        (NSPasteboard.PasteboardType(UTType.gif.identifier), .gif),
        (.png, .png),
        (NSPasteboard.PasteboardType(UTType.jpeg.identifier), .jpeg),
        (NSPasteboard.PasteboardType(UTType.heic.identifier), .heic),
        (NSPasteboard.PasteboardType(UTType.webP.identifier), .webP),
        (.tiff, .tiff),
    ]

    /// Whether the current contents were written by esclop.
    public static func isOwnWrite(_ pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.types?.contains(optimisedType) ?? false
    }

    /// What is on the pasteboard, most specific first: files, image data, a path, base64.
    public static func read(_ pasteboard: NSPasteboard = .general) -> ClipboardContent {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty
        {
            return .files(urls.map(\.standardizedFileURL))
        }
        for (type, utType) in imageTypes {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                return .image(data, utType)
            }
        }
        if let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if let image = decodeBase64Image(text) {
                return .base64Image(image.data, image.type)
            }
            if let url = existingFile(from: text) {
                return .path(url)
            }
        }
        return .empty
    }

    /// Saves pasted image bytes to a file esclop can work on (in `Paths.temporary/clipboard`).
    public static func materialise(_ content: ClipboardContent, folder: URL = Paths.temporary.appendingPathComponent("clipboard", isDirectory: true)) throws -> [URL] {
        switch content {
        case let .files(urls): return urls
        case let .path(url): return [url]
        case let .image(data, type), let .base64Image(data, type):
            try Paths.ensure(folder)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: ".")
            let url = folder.appendingPathComponent("Clipboard \(stamp)").appendingPathExtension(type.preferredFilenameExtension ?? "png")
            try data.write(to: url, options: .atomic)
            return [url]
        case .empty:
            return []
        }
    }

    /// Puts files back: the file URLs, plus the image bytes for a single image so apps that only
    /// paste pixels (chat, mail) get the optimised image too.
    public static func write(files urls: [URL], to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = urls.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            item.setString(url.path, forType: .string)
            item.setString("1", forType: optimisedType)
            if urls.count == 1, let type = UTType(filenameExtension: url.pathExtension.lowercased()), type.conforms(to: .image),
               let data = try? Data(contentsOf: url)
            {
                item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
                if type != .png, type != .tiff, let image = NSImage(data: data), let tiff = image.tiffRepresentation {
                    // Apps that only read TIFF still get pixels; they read the original type first.
                    item.setData(tiff, forType: .tiff)
                }
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    /// Puts image bytes back without a file (for pasting into apps that take pixels).
    public static func write(image data: Data, type: UTType, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        item.setString("1", forType: optimisedType)
        pasteboard.writeObjects([item])
    }

    /// Writes an `OptimisationResult`'s output back.
    public static func write(_ result: OptimisationResult, to pasteboard: NSPasteboard = .general) {
        write(files: [result.output], to: pasteboard)
    }

    // MARK: Text forms

    /// `data:image/png;base64,...`, also inside `url(...)` as CSS writes it.
    static func decodeBase64Image(_ text: String) -> (data: Data, type: UTType)? {
        var text = text
        if text.hasPrefix("url("), text.hasSuffix(")") {
            text = String(text.dropFirst(4).dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        }
        guard text.hasPrefix("data:image/"), let comma = text.firstIndex(of: ","),
              text[..<comma].hasSuffix(";base64")
        else { return nil }
        let mime = String(text[text.index(text.startIndex, offsetBy: 5) ..< comma].dropLast(7))
        guard let data = Data(base64Encoded: String(text[text.index(after: comma)...]), options: .ignoreUnknownCharacters),
              let type = UTType(mimeType: mime)
        else { return nil }
        return (data, type)
    }

    /// A path (`/...`, `~/...` or `file://...`) to a file that exists.
    static func existingFile(from text: String) -> URL? {
        guard !text.contains("\n") else { return nil }
        var path = text
        if path.hasPrefix("file://"), let url = URL(string: path) {
            path = url.path
        }
        path = (path as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path)
    }
}
