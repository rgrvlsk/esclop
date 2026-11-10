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

@MainActor
@Suite struct ClipboardOwnWriteTests {
    func watcherSees(_ harness: Harness) -> ClipboardAction {
        let board = harness.pasteboard
        let types = Set((board.types ?? []).map(\.rawValue))
        return ClipboardPolicy(factory: harness.model.factory).decide(types: types, content: { Clipboard.read(board) }, frontmostApp: nil)
    }

    @Test func copyUndoDownscaleLeavesOneResult() async throws {
        let harness = Harness()
        harness.model.handleClipboard(.optimiseImage(screenshotPNG(), .png))
        #expect(await eventually { harness.model.cards.first?.result != nil })
        let card = try #require(harness.model.cards.first)
        #expect(watcherSees(harness) == .ignore(.ownWrite))
        harness.model.perform(.undo, on: card)
        #expect(await eventually { if case .restored = card.phase { return true } else { return false } })
        #expect(watcherSees(harness) == .ignore(.ownWrite), "the restored original on the clipboard is ours too")
        harness.model.perform(.downscale, on: card)
        #expect(await eventually { harness.requests.requests.count == 2 && card.result != nil })
        #expect(watcherSees(harness) == .ignore(.ownWrite))
        #expect(harness.model.cards.count == 1)
    }

    @Test func optimiseClipboardOnOurOwnResultShowsItAgain() async throws {
        let harness = Harness()
        harness.model.handleClipboard(.optimiseImage(screenshotPNG(), .png))
        #expect(await eventually { harness.model.cards.first?.result != nil })
        let card = try #require(harness.model.cards.first)
        harness.model.optimiseClipboardNow(aggressive: false)
        harness.model.optimiseClipboardNow(aggressive: false)
        #expect(harness.model.cards.map(\.id) == [card.id], "no twin result")
        #expect(harness.requests.requests.count == 1, "nothing ran again")

        // Dismissed, it comes back from Recent Results.
        harness.model.dismiss(card)
        harness.model.optimiseClipboardNow(aggressive: false)
        #expect(harness.model.cards.count == 1)
        #expect(harness.requests.requests.count == 1)
    }

    @Test func ourBytesWithoutTheMarkerAreStillOurs() async throws {
        let harness = Harness()
        try EsclopSettings.autoCopyToClipboard.set(true, in: harness.settings.store)
        harness.model.handleClipboard(.optimiseImage(screenshotPNG(), .png))
        #expect(await eventually { harness.model.cards.first?.result != nil })
        let output = try #require(harness.model.cards.first?.result?.output)
        // Another app copies the same bytes on, without L'Esclop's marker.
        let data = try Data(contentsOf: output)
        harness.model.handleClipboard(.optimiseImage(data, .png))
        harness.model.handleClipboard(.optimiseFiles([output]))
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
