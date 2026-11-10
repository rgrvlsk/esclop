// SPDX-License-Identifier: GPL-3.0-or-later
//
// Recognises L'Esclop's own clipboard writes by their bytes, not only by the marker type: a
// clipboard manager, Universal Clipboard or an app that copies the clipboard on can drop the
// marker, and the result would come back as a "new" copy to optimise again.

import AppKit
import CryptoKit
import EsclopOptimisers
import Foundation

struct ClipboardFingerprint: Hashable, Sendable {
    let size: Int
    let digest: Data
    /// Bytes hashed from each end: cheap for large videos, exact enough to know our own bytes.
    static let window = 256 * 1024

    /// Size plus a hash of the first 256 KB and of the bytes after them, up to the last 256 KB.
    init(data: Data) {
        let tailStart = max(Self.window, data.count - Self.window)
        self.init(size: data.count, head: data.prefix(Self.window), tail: data.count > tailStart ? data.suffix(from: data.startIndex + tailStart) : Data())
    }

    init?(file: URL) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let size = Int(end)
        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: Self.window)) ?? Data()
        let tailStart = max(Self.window, size - Self.window)
        var tail = Data()
        if size > tailStart {
            try? handle.seek(toOffset: UInt64(tailStart))
            tail = (try? handle.readToEnd()) ?? Data()
        }
        self.init(size: size, head: head, tail: tail)
    }

    private init(size: Int, head: Data, tail: Data) {
        var hasher = SHA256()
        hasher.update(data: head)
        hasher.update(data: tail)
        self.size = size
        digest = Data(hasher.finalize())
    }
}

extension AppModel {
    /// Writes files to the clipboard as L'Esclop's own, remembering their bytes.
    func writeClipboard(files: [URL]) {
        for file in files {
            if let print = ClipboardFingerprint(file: file) { rememberOwnWrite(print) }
        }
        Clipboard.write(files: files, to: pasteboard)
    }

    func rememberOwnWrite(_ print: ClipboardFingerprint) {
        ownWrites.append(print)
        if ownWrites.count > 32 { ownWrites.removeFirst(ownWrites.count - 32) }
    }

    /// The clipboard holds L'Esclop's own write: marked as such, or bytes it wrote.
    func isOwnClipboardContent(_ content: ClipboardContent) -> Bool {
        if Clipboard.isOwnWrite(pasteboard) { return true }
        switch content {
        case let .files(urls): return !urls.isEmpty && urls.allSatisfy { ClipboardFingerprint(file: $0).map(ownWrites.contains) ?? false }
        case let .image(data, _), let .base64Image(data, _): return ownWrites.contains(ClipboardFingerprint(data: data))
        default: return false
        }
    }
}
