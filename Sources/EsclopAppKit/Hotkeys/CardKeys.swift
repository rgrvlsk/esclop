// SPDX-License-Identifier: GPL-3.0-or-later
//
// The keys a result card takes, with Clop's modifiers: ⌘ and a key, Space alone. They work on
// the card under the pointer (`HoverKeys`, without a click and without taking the window from
// the app in front) and on the card that has the keys (a click, or the "Go to the newest result"
// hotkey). DESIGN.md › Keys lists them. Keys are named by the character they type. Clop's ⌘R is
// Rename and its ⌘E opens a chosen editor: here ⌘R is Show in Finder, as in Finder's own search,
// and there is no editor setting, so neither key renames or edits.

import EsclopCore
import Foundation

enum CardKeys {
    enum Command: Equatable {
        case quickLook
        case perform(CardPresentation.Action)
        /// Runs the file again from its original at this scale.
        case downscale(Double)
        /// Runs the file again from its original with aggressive compression.
        case harder
        /// Opens the file in its default app.
        case open
        /// Opens the options where a video's or a sound's playback speed is chosen.
        case speed
    }

    /// Backspace, as a key press and the hotkey see it.
    static let delete: Character = "\u{7F}"

    /// The letters, as Clop's where L'Esclop has the action. The "…" menu shows them too, and
    /// the first letter of an action is the one it shows (Show in Finder ⌘R).
    static let letters: KeyValuePairs<Character, CardPresentation.Action> = [
        "z": .undo, "c": .copy, "r": .reveal, "f": .reveal, "d": .compare, "k": .crop, "s": .save, "u": .upload,
    ]

    /// Clop's letters for what the card does without a button of its own.
    static let commands: KeyValuePairs<Character, Command> = ["a": .harder, "o": .open, "x": .speed]

    /// Space is pressed alone, as in Clop; every other key with ⌘, so a pointer resting on a card
    /// never takes letters typed into the app in front.
    static func needsCommand(_ key: Character) -> Bool { key != " " }

    /// Every key, in DESIGN.md's order.
    static let all: [Character] = [" "] + letters.map(\.key) + commands.map(\.key) + [delete, "-"] + (1...9).map { Character(String($0)) }

    /// What `key` does to `card` now, or nil when it does nothing there (the key then stays with
    /// the app in front).
    @MainActor
    static func command(for key: Character, on card: ResultCard) -> Command? {
        command(for: key, on: card, actions: actions(of: card))
    }

    /// The keys that do something on `card` now.
    @MainActor
    static func keys(on card: ResultCard) -> [Character] {
        let actions = actions(of: card)
        return all.filter { command(for: $0, on: card, actions: actions) != nil }
    }

    /// Everything the card or its detail can do, whatever level shows; nothing for a notice.
    @MainActor
    private static func actions(of card: ResultCard) -> [CardPresentation.Action] {
        if case .notice = card.phase { return [] }
        let info = card.presentation
        return info.actions + FloatingResultView.actions(info, level: .detail)
    }

    @MainActor
    private static func command(for key: Character, on card: ResultCard, actions: [CardPresentation.Action]) -> Command? {
        func offered(_ action: CardPresentation.Action) -> Command? { actions.contains(action) ? .perform(action) : nil }
        let finished = card.machine.stage == .finished && !actions.isEmpty
        // The options popover is where harder compression and the speed are chosen.
        let options = actions.contains(.more) || actions.contains(.convertOptions)
        if let action = letters.first(where: { $0.key == key })?.value {
            // Upload has no button on the card; the Share tab's rows upload to a chosen target.
            guard action == .upload else { return offered(action) }
            let uploading = if case .uploading = card.upload { true } else { false }
            return finished && card.draggableFile != nil && !uploading ? .perform(.upload) : nil
        }
        if let command = commands.first(where: { $0.key == key })?.value {
            guard finished, options else { return nil }
            switch command {
            case .harder: return card.choice.compression == .aggressive ? nil : .harder
            case .open: return actions.contains(.reveal) ? .open : nil
            case .speed:
                let kind = MediaKind.of(card.shownFile)
                return kind == .video || kind == .audio ? .speed : nil
            default: return nil
            }
        }
        switch key {
        case " ": return finished ? .quickLook : nil
        // Off the screen, as Clop's: the file stays (Move to Trash is in the "…" menu).
        case delete: return offered(.stop) ?? offered(.dismiss)
        case "-":
            guard finished, actions.contains(.downscale), let scale = smaller(than: card.downscale) else { return nil }
            return .downscale(scale)
        default:
            guard finished, actions.contains(.downscale), let digit = key.wholeNumberValue, (1...9).contains(digit) else { return nil }
            let scale = Double(digit) / 10
            return abs(scale - card.downscale) < 0.001 ? nil : .downscale(scale)
        }
    }

    /// `-` steps down a quarter at a time to half, then a tenth at a time to 10 %.
    static func smaller(than scale: Double) -> Double? {
        guard scale > 0.1 + 0.001 else { return nil }
        let next = scale > 0.5 + 0.001 ? scale - 0.25 : scale - 0.1
        return max(0.1, (next * 100).rounded() / 100)
    }

    /// The key a "…" menu row shows at its end, as a system menu shows its key, and a button's
    /// tooltip after its name.
    static func label(for action: CardPresentation.Action) -> String? {
        if action == .dismiss || action == .stop { return "⌘⌫" }
        return letters.first { $0.value == action }.map { "⌘" + $0.key.uppercased() }
    }

    /// A button's tooltip: its name, then its key where it has one ("Undo  ⌘Z").
    static func help(for action: CardPresentation.Action) -> String {
        label(for: action).map { action.accessibilityName + "  " + $0 } ?? action.accessibilityName
    }

    /// The tooltip of a control in the options whose key works on the result, not in the
    /// options (⌘A would take Select All from their fields): "Optimise harder (⌘A on the result)".
    static func onTheResult(_ name: String, key: String) -> String {
        Strings.format("%@ (%@ on the result)", name, key)
    }

    /// After these the hotkey's lent keys go back to the app in front: the person came to undo,
    /// copy or save the newest result, and goes back to work.
    static func givesKeysBack(_ action: CardPresentation.Action) -> Bool {
        [.undo, .copy, .save].contains(action)
    }
}

extension AppModel {
    /// Runs a card key on `card` (its ⌘ already checked); false when it does nothing there.
    @discardableResult
    func press(_ key: Character, on card: ResultCard) -> Bool {
        guard let command = CardKeys.command(for: Character(key.lowercased()), on: card) else { return false }
        switch command {
        case .quickLook: QuickLookPresenter.shared.toggle(card.shownFile)
        // With no target yet, the key opens Settings › Uploads, as the Share tab's row does.
        case .perform(.upload) where uploadTargets.isEmpty: openFile(URL(string: "esclop://settings/uploads")!)
        case let .perform(action): perform(action, on: card)
        case let .downscale(scale): downscale(card, to: scale)
        case .harder: apply(card.choice.with(compression: .aggressive), to: card)
        case .open: openFile(card.shownFile)
        case .speed:
            card.optionsTab = MediaKind.of(card.shownFile) == .audio ? .sound : .optimise
            openOptions(card)
        }
        return true
    }

    /// A card key pressed on the card that has the keys, or in its options: a key that does
    /// nothing there beeps (⌘S where there is no Save to Downloads) instead of passing silently.
    /// False for a key that is not a card key, which goes on to the window.
    @discardableResult
    func pressOrBeep(_ key: Character, on card: ResultCard) -> Bool {
        if press(key, on: card) { return true }
        guard CardKeys.all.contains(Character(key.lowercased())) else { return false }
        beep()
        return true
    }

    /// The keys the hotkey lent go back to the app in front; the card stays.
    func returnKeys(from card: ResultCard) {
        card.lentKeys = false
        onReturnKeys?()
    }

    /// The "Show last result" hotkey: the newest result in Recent that is not on screen comes
    /// back (the card that hid last, or one that "Show floating results" kept off the screen).
    /// Pressed again it goes further back, past the results it pushed off the three places, so it
    /// never goes round in a circle; at the oldest it beeps.
    func showLastResult() {
        let shown = Set(visibleCards.compactMap(\.result?.id))
        // A new walk once none of the results it brought back is on screen.
        if walk.broughtBack.isDisjoint(with: shown) { walk = ([], []) }
        guard let result = recent.first(where: { !shown.contains($0.id) && !walk.pushedOff.contains($0.id) }) else {
            // The end: the next press starts again from the newest.
            walk = ([], [])
            return beep()
        }
        show(result)
        walk.broughtBack.insert(result.id)
        walk.pushedOff.formUnion(shown.subtracting(visibleCards.compactMap(\.result?.id)))
    }

    /// The "Go to the newest result" hotkey: the newest card, or notice with an action (a copied
    /// address's offer, "Optimise anyway"), takes the keys and VoiceOver's cursor, without
    /// activating the app.
    func focusNewestResult() {
        let newest = visibleCards.last { card in
            if case .notice = card.phase { return card.noticeAction != nil }
            return true
        }
        guard let newest else { return }
        for card in cards { card.lentKeys = false }
        newest.wantsFocus = true
        newest.lentKeys = true
        onCardsChange?()
    }
}
