// SPDX-License-Identifier: GPL-3.0-or-later
//
// The clipboard as L'Esclop knows it, and the pasteboard reads and writes the app makes for its
// results. They all run on `queue`, which the clipboard watcher polls on too: NSPasteboard is not
// safe to use from two threads, and the pasteboard server answers over XPC, which can be slow.
//
// What was copied belongs to the person. A result goes back on the clipboard only while the
// clipboard still holds the copy it came from, or L'Esclop's own write of that copy: the change
// count has not moved since. Whatever was copied in the meantime stays.

import AppKit
import EsclopOptimisers
import Foundation
import UniformTypeIdentifiers

final class ClipboardKeeper: @unchecked Sendable {
    static let queue = DispatchQueue(label: "dev.esclop.app.clipboard", qos: .userInitiated)

    // Everything below is touched only on `queue`.
    private let pasteboard: NSPasteboard
    /// The files on the clipboard at change count `count`: a copy being optimised, or the last write.
    private var held: (count: Int, files: [URL])?
    /// What L'Esclop wrote, by bytes (`ClipboardFingerprint`), the last 32 files.
    private var ownWrites: [ClipboardFingerprint] = []
    /// The change count of L'Esclop's own last write.
    private var ownCount: Int?

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    /// Runs `body` on the queue.
    func run<T: Sendable>(_ body: @escaping @Sendable (ClipboardKeeper) -> T) async -> T {
        await withCheckedContinuation { continuation in
            Self.queue.async { continuation.resume(returning: body(self)) }
        }
    }

    // MARK: On the queue

    /// The clipboard holds `files` since change `count`. An older change never wins, so copies
    /// handled out of order cannot go back in time; at the same change the latest hold does
    /// ("Optimise Clipboard" on pixels saves them to a new file).
    func hold(_ files: [URL], at count: Int) {
        if let held, held.count > count { return }
        held = (count, files)
    }

    /// Writes files as L'Esclop's own, whatever the clipboard holds (the person asked for them).
    func write(_ files: [URL]) {
        for file in files {
            if let print = ClipboardFingerprint(file: file) { ownWrites.append(print) }
        }
        if ownWrites.count > 32 { ownWrites.removeFirst(ownWrites.count - 32) }
        Clipboard.write(files: files, to: pasteboard)
        held = (pasteboard.changeCount, files)
        ownCount = pasteboard.changeCount
    }

    /// Text (a pipeline's `copyToClipboard`, a link, a path from Settings), marked as L'Esclop's
    /// own; a single `link` also as a URL. Nothing is held, so no result goes back over it. With
    /// `since` (an automatic upload's link) it is written only while the clipboard still holds
    /// what it held at that change count, or L'Esclop's own last write: a copy made meanwhile
    /// stays. False when nothing was written.
    @discardableResult
    func write(text: String, link: Bool = false, since count: Int? = nil) -> Bool {
        if let count, pasteboard.changeCount != count, pasteboard.changeCount != ownCount { return false }
        pasteboard.clearContents()
        pasteboard.declareTypes(link ? [.string, .URL, Clipboard.optimisedType] : [.string, Clipboard.optimisedType], owner: nil)
        pasteboard.setString(text, forType: .string)
        if link { pasteboard.setString(text, forType: .URL) }
        pasteboard.setString("1", forType: Clipboard.optimisedType)
        held = nil
        ownCount = pasteboard.changeCount
        return true
    }

    func changeCount() -> Int { pasteboard.changeCount }

    func write(imageData data: Data, type: UTType) {
        ownWrites.append(ClipboardFingerprint(data: data))
        if ownWrites.count > 32 { ownWrites.removeFirst(ownWrites.count - 32) }
        Clipboard.write(image: data, type: type, to: pasteboard)
        held = nil
        ownCount = pasteboard.changeCount
    }

    /// Puts each new file in the place of the old one, the other files kept in order, while the
    /// clipboard still holds what L'Esclop last saw there. False when nothing was written.
    @discardableResult
    func swap(_ replacements: [(old: URL, new: URL)]) -> Bool {
        guard let held, held.count == pasteboard.changeCount else { return false }
        let new = Dictionary(replacements.map { ($0.old.standardizedFileURL.path, $0.new) }, uniquingKeysWith: { first, _ in first })
        guard held.files.contains(where: { new[$0.standardizedFileURL.path] != nil }) else { return false }
        write(held.files.map { new[$0.standardizedFileURL.path] ?? $0 })
        return true
    }

    /// The content is bytes L'Esclop wrote: its own write back without the marker (a clipboard
    /// manager or another app copied it on).
    func isOwnBytes(_ content: ClipboardContent) -> Bool {
        switch content {
        case let .files(urls): return !urls.isEmpty && urls.allSatisfy { ClipboardFingerprint(file: $0).map(ownWrites.contains) ?? false }
        case let .image(data, _), let .base64Image(data, _): return ownWrites.contains(ClipboardFingerprint(data: data))
        case .path, .empty: return false
        }
    }

    /// What the clipboard holds now, for "Optimise Clipboard": the content, its change count,
    /// whether it carries L'Esclop's marker, and whether it is L'Esclop's (marker or bytes).
    func snapshot() -> (content: ClipboardContent, count: Int, marked: Bool, own: Bool) {
        let content = Clipboard.read(pasteboard)
        let marked = Clipboard.isOwnWrite(pasteboard)
        return (content, pasteboard.changeCount, marked, marked || isOwnBytes(content))
    }
}

extension AppModel {
    /// Copy: puts files on the clipboard as L'Esclop's own, whatever it holds.
    func writeClipboard(files: [URL]) {
        let keeper = clipboard
        ClipboardKeeper.queue.async { keeper.write(files) }
    }

    /// A pipeline step's or Settings' copy, as L'Esclop's own.
    func copyToClipboard(text: String) async {
        await clipboard.run { $0.write(text: text) }
    }

    /// Links on the clipboard, one per line; with `since`, only if nothing was copied after it
    /// (`ClipboardKeeper.write(text:link:since:)`). False when the clipboard kept what was copied.
    @discardableResult
    func copyToClipboard(links: [URL], since: Int? = nil) async -> Bool {
        let text = links.map(\.absoluteString).joined(separator: "\n")
        return await clipboard.run { $0.write(text: text, link: links.count == 1, since: since) }
    }

    func copyToClipboard(imageData: Data, type: UTType) async {
        await clipboard.run { $0.write(imageData: imageData, type: type) }
    }

    /// Results back in the places of the files they came from, if the clipboard still holds those.
    func putBackOnClipboard(_ replacements: [(old: URL, new: URL)]) async {
        _ = await clipboard.run { $0.swap(replacements) }
    }

    /// Remembers what a copy put on the clipboard, so its results can go back in place.
    func holdOnClipboard(_ files: [URL], at count: Int) {
        let keeper = clipboard
        ClipboardKeeper.queue.async { keeper.hold(files, at: count) }
    }
}
