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
            " ": .quickLook, "z": .perform(.undo), "c": .perform(.copy), "f": .perform(.reveal), "r": .perform(.reveal),
            "d": .perform(.compare), "k": .perform(.crop), "s": .perform(.save), CardKeys.delete: .perform(.dismiss),
            "-": .downscale(0.75), "1": .downscale(0.1), "5": .downscale(0.5), "9": .downscale(0.9),
            "a": .harder, "o": .open, "u": .perform(.upload),
        ]
        for (key, command) in expected {
            #expect(CardKeys.command(for: key, on: shot) == command, "key \(key)")
        }
        #expect(CardKeys.command(for: "q", on: shot) == nil)
        #expect(CardKeys.command(for: "x", on: shot) == nil, "a picture has no playback speed")
        let movie = URL(fileURLWithPath: "/tmp/Clip.mov")
        let video = cards.card(.done(cards.saved(movie, kind: .video)), source: movie)
        #expect(CardKeys.command(for: "x", on: video) == .speed)
        shot.choice.compression = .aggressive
        #expect(CardKeys.command(for: "a", on: shot) == nil, "already compressed harder")
    }

    /// Clop's A, O, U and X act on the result: harder from the original, the default app, an
    /// upload (Settings › Uploads while there is no target), the speed in the options.
    @Test func clopsOtherLettersAct() async throws {
        let harness = Harness()
        var opened: [URL] = []
        harness.model.openFile = { opened.append($0) }
        _ = await harness.model.run(harness.job(harness.temp.file("a.png")))
        let card = try #require(harness.model.cards.first)
        #expect(harness.model.press("o", on: card))
        #expect(opened == [card.shownFile])
        #expect(harness.model.press("u", on: card))
        #expect(opened.last == URL(string: "esclop://settings/uploads"), "no target yet: its settings")
        #expect(harness.model.press("a", on: card))
        #expect(await eventually { harness.requests.requests.count == 2 && card.result != nil })
        #expect(harness.requests.requests.last?.quality.tier == .aggressive)
        #expect(card.choice.compression == .aggressive)
        #expect(!harness.model.press("x", on: card), "a picture has no speed")

        let movie = harness.temp.file("b.mov")
        _ = await harness.model.run(harness.job(movie))
        let clip = try #require(harness.model.cards.last)
        #expect(harness.model.press("x", on: clip))
        #expect(clip.optionsTab == .optimise && clip.machine.menuOpen, "the options open where the speed is")
    }

    /// "Card keys under the pointer" off: the resting pointer holds no key, new ones included.
    @Test func theSwitchKeepsEveryKeyWithTheAppInFront() {
        let shot = cards.card(.done(cards.saved()))
        let held = FloatingResultView.hoverKeys(on: shot, switchOn: true, moved: true, taken: false)
        #expect(["a", "o", "u", "r", "f"].allSatisfy(held.contains))
        #expect(FloatingResultView.hoverKeys(on: shot, switchOn: false, moved: true, taken: false).isEmpty)
    }

    /// ⌘S on a result with no Save to Downloads (a dropped file) beeps instead of doing nothing;
    /// a key that is not the card's goes on to the window.
    @Test func aCardKeyThatDoesNothingBeeps() async throws {
        let harness = Harness()
        var beeps = 0
        harness.model.beep = { beeps += 1 }
        _ = await harness.model.run(harness.job(harness.temp.file("a.png")))
        let card = try #require(harness.model.cards.first)
        #expect(CardKeys.command(for: "s", on: card) == nil)
        #expect(harness.model.pressOrBeep("s", on: card))
        #expect(beeps == 1)
        #expect(!harness.model.pressOrBeep("q", on: card))
        #expect(beeps == 1)
        #expect(harness.model.pressOrBeep("r", on: card), "Show in Finder")
        #expect(beeps == 1)
    }

    /// Clop's modifiers: Space alone, every other key with ⌘, so a resting pointer never takes
    /// letters typed into the app in front. The "…" menu shows the same chord.
    @Test func onlySpaceGoesWithoutCommand() {
        #expect(CardKeys.all.filter { !CardKeys.needsCommand($0) } == [" "])
        #expect(CardKeys.label(for: .compare) == "⌘D")
        #expect(CardKeys.label(for: .reveal) == "⌘R", "Finder's own key, shown everywhere; ⌘F works too")
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

    /// The keyboard alone reaches a result: ⌃⇧N out of the box, beside ⌃⇧C, ⌃⇧A and ⌃⇧P (pause).
    /// "Show the last result" waits for a key.
    @Test func goToTheNewestResultHasAKeyAndShowLastResultIsInSettings() {
        #expect(KeyboardShortcuts.Name.focusNewestResult.defaultShortcut == .init(.n, modifiers: [.control, .shift]))
        let defaults = Hotkeys.all.compactMap(\.name.defaultShortcut)
        #expect(Set(defaults.map(\.description)).count == defaults.count, "no two hotkeys share a key")
        #expect(KeyboardShortcuts.Name.showLastResult.defaultShortcut == nil)
        #expect(Hotkeys.all.map(\.name) == [.optimiseClipboard, .optimiseClipboardHarder, .focusNewestResult, .togglePause, .showLastResult])
    }

    /// "Show floating results" off: a drop's results go to Recent only, a big drop opens no batch
    /// window, and "Show the last result" brings up the newest result not on screen; with no
    /// result at all it beeps.
    @Test func showLastResultBringsBackWhatIsNotOnScreen() async throws {
        let harness = Harness()
        var beeps = 0
        harness.model.beep = { beeps += 1 }
        try EsclopSettings.showFloatingResults.set(false, in: harness.settings.store)
        Hotkeys.action(for: .showLastResult)(harness.model)
        #expect(beeps == 1 && harness.model.cards.isEmpty, "nothing to show yet")
        let many = (1...harness.model.batchThreshold).map { harness.temp.file("b\($0).png") }
        harness.model.optimise(many, origin: .dropZone)
        #expect(await eventually { harness.model.recent.count == many.count })
        #expect(harness.model.batch == nil, "no batch window either")
        harness.model.optimise([harness.temp.file("a.png")], origin: .dropZone)
        #expect(await eventually { harness.model.recent.count == many.count + 1 })
        #expect(harness.model.cards.isEmpty)
        Hotkeys.action(for: .showLastResult)(harness.model)
        let card = try #require(harness.model.cards.first)
        #expect(card.result?.id == harness.model.recent.first?.id)
        Hotkeys.action(for: .showLastResult)(harness.model)
        #expect(harness.model.cards.count == 2, "the newest is on screen: the next one comes")
        #expect(harness.model.cards.last?.result?.id == harness.model.recent[1].id)
        harness.model.dismiss(card)
        Hotkeys.action(for: .showLastResult)(harness.model)
        #expect(harness.model.cards.last?.result?.id == card.result?.id, "the card that went comes back")
        #expect(beeps == 1)
    }

    /// With the three places full, each press goes further back through Recent instead of
    /// bringing back the result the last press pushed off; at the oldest it beeps.
    @Test func showLastResultWalksBackWithoutCircling() async throws {
        let harness = Harness()
        var beeps = 0
        harness.model.beep = { beeps += 1 }
        try EsclopSettings.showFloatingResults.set(false, in: harness.settings.store)
        for index in 1...5 {
            harness.model.optimise([harness.temp.file("r\(index).png")], origin: .dropZone)
            #expect(await eventually { harness.model.recent.count == index })
        }
        let newestFirst = harness.model.recent.map(\.id)
        var brought: [UUID] = []
        for _ in 0..<5 {
            Hotkeys.action(for: .showLastResult)(harness.model)
            if let id = harness.model.cards.last?.result?.id { brought.append(id) }
        }
        #expect(brought == newestFirst, "each press one further back")
        #expect(beeps == 0)
        Hotkeys.action(for: .showLastResult)(harness.model)
        #expect(beeps == 1, "past the oldest it beeps")
        Hotkeys.action(for: .showLastResult)(harness.model)
        #expect(harness.model.cards.last?.result?.id == newestFirst[0], "and starts again from the newest")
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
