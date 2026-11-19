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

final class ClipboardKeeper: @unchecked Sendable {
    static let queue = DispatchQueue(label: "dev.esclop.app.clipboard", qos: .userInitiated)

    // Everything below is touched only on `queue`.
    private let pasteboard: NSPasteboard
    /// The files on the clipboard at change count `count`: a copy being optimised, or the last write.
    private var held: (count: Int, files: [URL])?
    /// What L'Esclop wrote, by bytes (`ClipboardFingerprint`), the last 32 files.
    private var ownWrites: [ClipboardFingerprint] = []

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
