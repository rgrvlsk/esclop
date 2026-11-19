// SPDX-License-Identifier: GPL-3.0-or-later
//
// What was copied belongs to the person: a result goes back on the clipboard only while the
// clipboard still holds the copy it came from, every copied file goes back in its place, and a
// copied file is optimised as a copy, never changed on disk.

import AppKit
import EsclopCore
@testable import EsclopAppKit
import EsclopOptimisers
import Foundation
import Testing

@MainActor
@Suite struct ClipboardOwnershipTests {
    /// The clipboard's files, by path.
    func clipboardPaths(_ harness: Harness) -> [String]? {
        guard case let .files(urls) = Clipboard.read(harness.pasteboard) else { return nil }
        return urls.map(\.standardizedFileURL.path)
    }

    /// Where each optimised file went, from the results.
    func outputs(_ harness: Harness) -> [String: String] {
        Dictionary(harness.model.recent.map { ($0.source.standardizedFileURL.path, $0.output.standardizedFileURL.path) }, uniquingKeysWith: { first, _ in first })
    }

    @Test func somethingCopiedWhileItCompressesStaysOnTheClipboard() async throws {
        let harness = Harness(delay: .milliseconds(300))
        harness.model.handleClipboard(harness.copy(image: screenshotPNG()))
        // While the image compresses, the person copies some text.
        harness.pasteboard.clearContents()
        harness.pasteboard.setString("a note", forType: .string)
        #expect(await eventually { harness.model.cards.first?.result != nil })
        try await Task.sleep(for: .milliseconds(200))
        await harness.clipboardSettles()
        #expect(harness.pasteboard.string(forType: .string) == "a note", "the text is not replaced by the image")
        #expect(!Clipboard.isOwnWrite(harness.pasteboard))

        // Copy, asked for, always writes.
        let card = try #require(harness.model.cards.first)
        harness.model.perform(.copy, on: card)
        await harness.clipboardSettles()
        #expect(clipboardPaths(harness) == [card.shownFile.standardizedFileURL.path])
    }

    @Test func optimiseClipboardAfterAStoppedRunPutsItsResultBack() async throws {
        let harness = Harness(delay: .milliseconds(300))
        harness.model.handleClipboard(harness.copy(image: screenshotPNG()))
        #expect(await eventually { harness.model.cards.first?.isWorking == true })
        harness.model.dismiss(try #require(harness.model.cards.first))
        // The same copy, now through the hotkey: saved to a file of its own.
        await harness.model.optimiseClipboard(aggressive: false)
        #expect(await eventually { harness.model.cards.first?.result != nil })
        #expect(await eventually { Clipboard.isOwnWrite(harness.pasteboard) }, "the result is on the clipboard")
    }

    @Test(arguments: [2, 4])
    func everyCopiedFileGoesBackInItsPlace(images: Int) async throws {
        let harness = Harness()
        let media = (0 ..< images).map { harness.temp.file("photo\($0).png") }
        let notes = harness.temp.file("notes.txt")
        // Copied in Finder, a text file among the images; below `batchWindowFrom` as cards, from it in the batch window.
        let copied = [media[0], notes] + media.dropFirst()
        harness.model.handleClipboard(harness.copy(files: copied, optimise: media))
        #expect(await eventually { harness.model.recent.count == images })
        #expect(await eventually { Clipboard.isOwnWrite(harness.pasteboard) })
        await harness.clipboardSettles()
        let outputs = outputs(harness)
        let expected = copied.map { outputs[$0.standardizedFileURL.path] ?? $0.standardizedFileURL.path }
        #expect(expected.filter { $0.hasSuffix(".png") }.allSatisfy { !copied.map(\.standardizedFileURL.path).contains($0) }, "every image was replaced by its result")
        #expect(clipboardPaths(harness) == expected, "all of them, in the order copied")
    }

    @Test func aCopiedFileIsOptimisedAsACopy() async throws {
        let harness = Harness()
        let original = harness.temp.png("photo.png")
        let bytes = try Data(contentsOf: original)
        harness.model.handleClipboard(harness.copy(files: [original]))
        #expect(await eventually { harness.model.cards.first?.result != nil })
        let result = try #require(harness.model.cards.first?.result)
        #expect(try Data(contentsOf: original) == bytes, "the original is untouched")
        #expect(harness.requests.requests.last?.location == .temporary)
        #expect(result.output.standardizedFileURL != original.standardizedFileURL)
        #expect(await eventually { clipboardPaths(harness) == [result.output.standardizedFileURL.path] }, "the clipboard holds the optimised copy")

        // Harder starts from the untouched original, and its result takes the first one's place.
        await harness.model.optimiseClipboard(aggressive: true)
        #expect(await eventually { harness.requests.requests.count == 2 && harness.model.cards.last?.result != nil })
        let harder = try #require(harness.model.cards.last?.result)
        #expect(harness.requests.requests.last?.quality == .aggressive)
        #expect(harder.source.standardizedFileURL == original.standardizedFileURL)
        #expect(try Data(contentsOf: original) == bytes)
        #expect(await eventually { clipboardPaths(harness) == [harder.output.standardizedFileURL.path] })
        #expect(harness.model.cards.count == 1, "the harder result replaces the first")
    }
}
