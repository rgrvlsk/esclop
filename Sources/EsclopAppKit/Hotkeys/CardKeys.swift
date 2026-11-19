// SPDX-License-Identifier: GPL-3.0-or-later
//
// The keys a result card takes, with Clop's modifiers: ⌘ and a key, Space alone. They work on
// the card under the pointer (`HoverKeys`, without a click and without taking the window from
// the app in front) and on the card that has the keys (a click, or the "Go to the newest result"
// hotkey). DESIGN.md › Keys lists them. Keys are named by the character they type.

import EsclopCore
import Foundation

enum CardKeys {
    enum Command: Equatable {
        case quickLook
        case perform(CardPresentation.Action)
        /// Runs the file again from its original at this scale.
        case downscale(Double)
    }

    /// Backspace, as a key press and the hotkey see it.
    static let delete: Character = "\u{7F}"

    /// The letters, as Clop's where L'Esclop has the action. The "…" menu shows them too.
    static let letters: KeyValuePairs<Character, CardPresentation.Action> = [
        "z": .undo, "c": .copy, "f": .reveal, "d": .compare, "k": .crop, "s": .save,
    ]

    /// Space is pressed alone, as in Clop; every other key with ⌘, so a pointer resting on a card
    /// never takes letters typed into the app in front.
    static func needsCommand(_ key: Character) -> Bool { key != " " }

    /// Every key, in DESIGN.md's order.
    static let all: [Character] = [" "] + letters.map(\.key) + [delete, "-"] + (1...9).map { Character(String($0)) }

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
        if let action = letters.first(where: { $0.key == key })?.value { return offered(action) }
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

    /// The key a "…" menu row shows at its end, as a system menu shows its key.
    static func label(for action: CardPresentation.Action) -> String? {
        letters.first { $0.value == action }.map { "⌘" + $0.key.uppercased() }
    }
}

extension AppModel {
    /// Runs a card key on `card` (its ⌘ already checked); false when it does nothing there.
    @discardableResult
    func press(_ key: Character, on card: ResultCard) -> Bool {
        guard let command = CardKeys.command(for: Character(key.lowercased()), on: card) else { return false }
        switch command {
        case .quickLook: QuickLookPresenter.shared.toggle(card.shownFile)
        case let .perform(action): perform(action, on: card)
        case let .downscale(scale): downscale(card, to: scale)
        }
        return true
    }

    /// The "Go to the newest result" hotkey: the newest card takes the keys and VoiceOver's
    /// cursor, without activating the app.
    func focusNewestResult() {
        let newest = visibleCards.last { card in
            if case .notice = card.phase { return false }
            return true
        }
        guard let newest else { return }
        newest.wantsFocus = true
        onCardsChange?()
    }
}
