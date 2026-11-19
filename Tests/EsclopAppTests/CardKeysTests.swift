// SPDX-License-Identifier: GPL-3.0-or-later
//
// The card's keys (DESIGN.md › Keys): what each key does to which card, the resting
// pointer's hotkeys, and a keyboard-only Undo of a copied screenshot. The UI check cannot press
// keys in the app, so these are the evidence that the keys reach the model.

import AppKit
import Carbon.HIToolbox
import EsclopCore
@testable import EsclopAppKit
import KeyboardShortcuts
import Testing

@MainActor
@Suite(.serialized) struct CardKeysTests {
    let cards = RenderTests()

    @Test func eachKeyRunsItsActionOnAFinishedResult() {
        let shot = cards.card(.done(cards.saved()))
        let expected: [Character: CardKeys.Command] = [
            " ": .quickLook, "z": .perform(.undo), "c": .perform(.copy), "f": .perform(.reveal),
            "d": .perform(.compare), "k": .perform(.crop), "s": .perform(.save), CardKeys.delete: .perform(.dismiss),
            "-": .downscale(0.75), "1": .downscale(0.1), "5": .downscale(0.5), "9": .downscale(0.9),
        ]
        for (key, command) in expected {
            #expect(CardKeys.command(for: key, on: shot) == command, "key \(key)")
        }
        #expect(CardKeys.command(for: "q", on: shot) == nil)
    }

    /// Clop's modifiers: Space alone, every other key with ⌘, so a resting pointer never takes
    /// letters typed into the app in front. The "…" menu shows the same chord.
    @Test func onlySpaceGoesWithoutCommand() {
        #expect(CardKeys.all.filter { !CardKeys.needsCommand($0) } == [" "])
        #expect(CardKeys.label(for: .compare) == "⌘D")
        #expect(CardKeys.label(for: .share) == nil)
    }

    /// The hover keys hold only what the card can do: a file at work takes Backspace (Stop) and
    /// leaves every other key with the app in front; a notice takes none.
    @Test func aCardHoldsOnlyTheKeysItCanUse() {
        let working = cards.card(.working(fraction: 0.4))
        #expect(CardKeys.all.filter { CardKeys.command(for: $0, on: working) != nil } == [CardKeys.delete])
        #expect(CardKeys.command(for: CardKeys.delete, on: working) == .perform(.stop))
        let notice = cards.card(.notice(title: "Nothing to optimise", detail: ""))
        #expect(CardKeys.all.allSatisfy { CardKeys.command(for: $0, on: notice) == nil })
        // A PDF has no size to step.
        let pdf = cards.card(.done(cards.saved(URL(fileURLWithPath: "/tmp/Report.pdf"), kind: .pdf)), source: URL(fileURLWithPath: "/tmp/Report.pdf"))
        #expect(CardKeys.command(for: "-", on: pdf) == nil)
        #expect(CardKeys.command(for: "5", on: pdf) == nil)
    }

    @Test func minusStepsDownToATenth() {
        var scale = 1.0
        var steps: [Double] = []
        while let next = CardKeys.smaller(than: scale) {
            steps.append(next)
            scale = next
        }
        #expect(steps == [0.75, 0.5, 0.4, 0.3, 0.2, 0.1])
        let shot = cards.card(.done(cards.saved()))
        shot.downscale = 0.5
        #expect(CardKeys.command(for: "5", on: shot) == nil, "already at that size")
    }

    @Test func theRestingPointerHoldsTheKeysUntilItLeaves() throws {
        let codes = HoverKeys.keyCodes()
        #expect(codes[" "] == UInt32(kVK_Space) && codes[CardKeys.delete] == UInt32(kVK_Delete))
        #expect(["z", "c", "-", "1"].allSatisfy { codes[$0] != nil }, "the layout types every key")
        let keys = HoverKeys.shared
        let card = UUID()
        keys.hold(["z", "c", " "], for: card) { _ in }
        defer { keys.release(from: card) }
        #expect(keys.owner == card)
        #expect(keys.keys == ["z", "c", " "], "registered as Carbon hotkeys")
        // Another card's leave does not take them; its own does.
        keys.release(from: UUID())
        #expect(keys.keys.count == 3)
        keys.release(from: card)
        #expect(keys.keys.isEmpty && keys.owner == nil)
    }

    /// A card that appears or moves under a still pointer takes no keys; the pointer moving on
    /// it does (a parked pointer must not take ⌘Z from the editor in front).
    @Test func onlyAPointerThatMovesOnTheCardTakesTheKeys() {
        var rest = PointerRest()
        rest.pointer(at: CGPoint(x: 900, y: 120))
        rest.pointer(at: CGPoint(x: 900, y: 120))
        #expect(!rest.moved, "the card came to a parked pointer")
        rest.pointer(at: CGPoint(x: 903, y: 121))
        #expect(rest.moved)
        // The stack moved the card from under it: it has to move again.
        rest.reset()
        rest.pointer(at: CGPoint(x: 903, y: 121))
        #expect(!rest.moved)
    }

    /// The hotkey lends the keys; Undo, Copy or Save (and Esc, `.returnKeys`) give them back to
    /// the app in front, and the card stays.
    @Test func theLentKeysGoBackAfterCopy() async throws {
        let harness = Harness()
        harness.pasteboard.clearContents()
        harness.pasteboard.setData(pngData(), forType: .png)
        Hotkeys.action(for: .optimiseClipboard)(harness.model)
        #expect(await eventually { harness.model.cards.first?.result != nil })
        let card = try #require(harness.model.cards.first)
        var returned = 0
        harness.model.onReturnKeys = { returned += 1 }
        Hotkeys.action(for: .focusNewestResult)(harness.model)
        #expect(card.lentKeys)
        #expect(harness.model.press("f", on: card), "Show in Finder keeps the keys")
        #expect(card.lentKeys && returned == 0)
        #expect(harness.model.press("c", on: card))
        #expect(!card.lentKeys && returned == 1)
        Hotkeys.action(for: .focusNewestResult)(harness.model)
        harness.model.interact(card, .returnKeys)
        #expect(!card.lentKeys && returned == 2)
        #expect(harness.model.cards.contains { $0 === card })
    }

    @Test func buttonsNameTheirKey() {
        #expect(CardKeys.help(for: .undo) == CardPresentation.Action.undo.accessibilityName + "  ⌘Z")
        #expect(CardKeys.help(for: .dismiss).hasSuffix("⌘⌫"))
        #expect(CardKeys.help(for: .share) == CardPresentation.Action.share.accessibilityName)
    }

    @Test func goToTheNewestResultIsInSettingsWithNoKey() {
        #expect(KeyboardShortcuts.Name.focusNewestResult.defaultShortcut == nil)
        #expect(Hotkeys.all.map(\.name).contains(.focusNewestResult))
    }

    /// Copy, the result, the hotkey, Z: a copied screenshot is undone from the keyboard alone.
    @Test func aCopiedScreenshotIsUndoneFromTheKeyboard() async throws {
        let harness = Harness()
        harness.pasteboard.clearContents()
        harness.pasteboard.setData(pngData(), forType: .png)
        Hotkeys.action(for: .optimiseClipboard)(harness.model)
        #expect(await eventually { harness.model.cards.first?.result != nil })
        let card = try #require(harness.model.cards.first)
        // A notice after it is not a result to go to.
        harness.model.add(cards.card(.notice(title: "Nothing to optimise", detail: "")))
        Hotkeys.action(for: .focusNewestResult)(harness.model)
        #expect(card.wantsFocus)
        #expect(harness.model.press("z", on: card))
        #expect(await eventually { if case .restored = card.phase { return true } else { return false } })
    }
}
