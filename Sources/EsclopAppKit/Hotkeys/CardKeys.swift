// SPDX-License-Identifier: GPL-3.0-or-later
//
// The plain keys a result card takes, as in Clop: on the card under the pointer (`HoverKeys`,
// without a click and without taking the keys from the app in front) and on the card that has
// the keys (a click, or the "Go to the newest result" hotkey). DESIGN.md › Keys lists them.

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

    /// Every key, in DESIGN.md's order.
    static let all: [Character] = [" ", "z", "c", "f", "d", "k", "s", delete, "-"] + (1...9).map { Character(String($0)) }

    /// What `key` does to `card` now, or nil when it does nothing there (the key then stays with
    /// the app in front).
    @MainActor
    static func command(for key: Character, on card: ResultCard) -> Command? {
        if case .notice = card.phase { return nil }
        let info = card.presentation
        // Everything the card or its detail can do, whatever level shows.
        let actions = info.actions + FloatingResultView.actions(info, level: .detail)
        func offered(_ action: CardPresentation.Action) -> Command? { actions.contains(action) ? .perform(action) : nil }
        let finished = card.machine.stage == .finished
        switch key {
        case " ": return finished ? .quickLook : nil
        case "z": return offered(.undo)
        case "c": return offered(.copy)
        case "f": return offered(.reveal)
        case "d": return offered(.compare)
        case "k": return offered(.crop)
        case "s": return offered(.save)
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
        switch action {
        case .compare: return "D"
        default: return nil
        }
    }
}

extension AppModel {
    /// Runs a plain key on `card`; false when the key does nothing there.
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
