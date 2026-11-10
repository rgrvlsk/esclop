// SPDX-License-Identifier: GPL-3.0-or-later
//
// The hotkeys without the key handling: their default keys and what each one does to the
// clipboard. The UI check could not deliver key presses to the app, so these are the evidence
// that ⌃⇧C and ⌃⇧A reach the model and do the right thing.

import AppKit
import EsclopCore
@testable import EsclopAppKit
import EsclopOptimisers
import KeyboardShortcuts
import Testing

@MainActor
@Suite struct HotkeyTests {
    @Test func defaultKeysAreClops() {
        #expect(KeyboardShortcuts.Name.togglePause.defaultShortcut == .init(.p, modifiers: [.control, .shift]))
        #expect(KeyboardShortcuts.Name.optimiseClipboard.defaultShortcut == .init(.c, modifiers: [.control, .shift]))
        #expect(KeyboardShortcuts.Name.optimiseClipboardHarder.defaultShortcut == .init(.a, modifiers: [.control, .shift]))
    }

    @Test func optimiseClipboardTakesWhatWasCopied() async throws {
        let harness = Harness()
        harness.pasteboard.clearContents()
        harness.pasteboard.setData(pngData(), forType: .png)
        Hotkeys.action(for: .optimiseClipboard)(harness.model)
        #expect(await eventually { harness.model.cards.first?.result != nil })
        #expect(harness.requests.requests.first?.quality == .normal)
        #expect(harness.requests.requests.first?.origin == .clipboard)

        // Pressed again on the result it wrote: no second run, no twin result.
        Hotkeys.action(for: .optimiseClipboard)(harness.model)
        #expect(harness.model.cards.count == 1)
        #expect(harness.requests.requests.count == 1)
    }

    @Test func harderRunsTheOriginalAgainAggressively() async throws {
        let harness = Harness()
        harness.pasteboard.clearContents()
        harness.pasteboard.setData(pngData(), forType: .png)
        Hotkeys.action(for: .optimiseClipboard)(harness.model)
        #expect(await eventually { harness.model.cards.first?.result != nil })
        Hotkeys.action(for: .optimiseClipboardHarder)(harness.model)
        #expect(await eventually { harness.requests.requests.count == 2 && harness.model.cards.last?.result != nil })
        #expect(harness.requests.requests.last?.quality == .aggressive)
        #expect(harness.model.cards.count == 1, "the harder result replaces the first")
    }

    @Test func anEmptyClipboardSaysSo() {
        let harness = Harness()
        harness.pasteboard.clearContents()
        Hotkeys.action(for: .optimiseClipboard)(harness.model)
        guard case let .notice(title, _) = harness.model.cards.first?.phase else {
            Issue.record("expected a notice")
            return
        }
        #expect(title == "Nothing to optimise")
    }

    @Test func pauseCyclesLikeClop() {
        let harness = Harness()
        let press = Hotkeys.action(for: .togglePause)
        press(harness.model)
        #expect(harness.model.skipNextCopy)
        press(harness.model)
        #expect(harness.model.paused)
        press(harness.model)
        #expect(!harness.model.paused)
    }
}
