// SPDX-License-Identifier: GPL-3.0-or-later
//
// L'Esclop must never optimise its own clipboard write as a new copy: not through the clipboard
// watcher, not when the marker type is lost on the way, and not through "Optimise Clipboard"
// (⌃⇧C), which used to make a twin result with no saving (UI check, F4).

import AppKit
import EsclopCore
@testable import EsclopAppKit
import EsclopOptimisers
import Foundation
import Testing
import UniformTypeIdentifiers

/// V6: results of dropped files reach the clipboard only when the person turned it on; copied
/// AVIF pixels are read; a download card for an address with no path names the host.
@MainActor
@Suite struct DroppedResultsClipboardTests {
    @Test func droppedResultsGoOnTheClipboardOnlyWhenAsked() async throws {
        let harness = Harness()
        harness.pasteboard.clearContents()
        harness.pasteboard.setString("what I copied", forType: .string)
        harness.model.optimiseDropped([harness.temp.file("a.png")], harder: false)
        #expect(await eventually { harness.model.cards.first?.result != nil })
        await harness.clipboardSettles()
        #expect(harness.pasteboard.string(forType: .string) == "what I copied", "off by default")

        try EsclopSettings.copyDroppedResults.set(true, in: harness.settings.store)
        harness.model.optimiseDropped([harness.temp.file("b.png")], harder: false)
        let output = { harness.model.cards.compactMap(\.result).first { $0.source.lastPathComponent == "b.png" }?.output }
        #expect(await eventually { output() != nil && Clipboard.isOwnWrite(harness.pasteboard) })
        #expect(Clipboard.read(harness.pasteboard, text: false) == .files([try #require(output()).standardizedFileURL]))
    }

    @Test func copiedAVIFPixelsAreRead() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setData(Data([0, 0, 0, 0x1C]), forType: NSPasteboard.PasteboardType("public.avif"))
        #expect(Clipboard.read(board, text: false) == .image(Data([0, 0, 0, 0x1C]), UTType("public.avif")!))
    }

    @Test func aDownloadWithNoPathIsNamedByItsHost() {
        #expect(AppModel.downloadName(URL(string: "https://example.com/")!) == "example.com")
        #expect(AppModel.downloadName(URL(string: "https://example.com")!) == "example.com")
        #expect(AppModel.downloadName(URL(string: "https://example.com/shots/a.png")!) == "a.png")
    }
}

@MainActor
@Suite struct ClipboardOwnWriteTests {
    func watcherSees(_ harness: Harness) -> ClipboardAction {
        let board = harness.pasteboard
        return ClipboardPolicy(factory: harness.model.factory).decide(harness.copyNow(), content: { Clipboard.read(board) })
    }

    @Test func copyUndoDownscaleLeavesOneResult() async throws {
        let harness = Harness()
        harness.model.handleClipboard(harness.copy(image: screenshotPNG()))
        #expect(await eventually { harness.model.cards.first?.result != nil })
        let card = try #require(harness.model.cards.first)
        #expect(await eventually { Clipboard.isOwnWrite(harness.pasteboard) })
        #expect(watcherSees(harness) == .ignore(.ownWrite))
        harness.model.perform(.undo, on: card)
        #expect(await eventually { if case .restored = card.phase { return true } else { return false } })
        await harness.clipboardSettles()
        #expect(watcherSees(harness) == .ignore(.ownWrite), "the restored original on the clipboard is ours too")
        harness.model.perform(.downscale, on: card)
        #expect(await eventually { harness.requests.requests.count == 2 && card.result != nil })
        try await Task.sleep(for: .milliseconds(100))
        await harness.clipboardSettles()
        #expect(watcherSees(harness) == .ignore(.ownWrite))
        #expect(harness.model.cards.count == 1)
    }

    @Test func optimiseClipboardOnOurOwnResultShowsItAgain() async throws {
        let harness = Harness()
        harness.model.handleClipboard(harness.copy(image: screenshotPNG()))
        #expect(await eventually { harness.model.cards.first?.result != nil })
        let card = try #require(harness.model.cards.first)
        #expect(await eventually { Clipboard.isOwnWrite(harness.pasteboard) })
        await harness.model.optimiseClipboard(aggressive: false)
        await harness.model.optimiseClipboard(aggressive: false)
        #expect(harness.model.cards.map(\.id) == [card.id], "no twin result")
        #expect(harness.requests.requests.count == 1, "nothing ran again")

        // Dismissed, it comes back from Recent Results.
        harness.model.dismiss(card)
        await harness.model.optimiseClipboard(aggressive: false)
        #expect(harness.model.cards.count == 1)
        #expect(harness.requests.requests.count == 1)
    }

    @Test func ourBytesWithoutTheMarkerAreStillOurs() async throws {
        let harness = Harness()
        try EsclopSettings.autoCopyToClipboard.set(true, in: harness.settings.store)
        harness.model.handleClipboard(harness.copy(image: screenshotPNG()))
        #expect(await eventually { harness.model.cards.first?.result != nil })
        let output = try #require(harness.model.cards.first?.result?.output)
        #expect(await eventually { Clipboard.isOwnWrite(harness.pasteboard) })
        // Another app copies the same bytes on, without L'Esclop's marker.
        let data = try Data(contentsOf: output)
        harness.model.handleClipboard(harness.copy(image: data))
        harness.model.handleClipboard(harness.copy(files: [output]))
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.model.cards.count == 1)
        #expect(harness.requests.requests.count == 1)
    }

    @Test func aFingerprintIsTheSameFromBytesAndFromTheFile() throws {
        let temp = TempDir()
        for size in [10, 300 * 1024, 600 * 1024] {
            let file = temp.file("f\(size).bin", bytes: size)
            let data = try Data(contentsOf: file)
            #expect(ClipboardFingerprint(file: file) == ClipboardFingerprint(data: data))
        }
        #expect(ClipboardFingerprint(data: Data([1, 2])) != ClipboardFingerprint(data: Data([1, 3])))
    }
}
