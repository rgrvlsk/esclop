// SPDX-License-Identifier: GPL-3.0-or-later
//
// Global hotkeys, with Clop 3.5's default keys: Control-Shift-C optimises the clipboard,
// Control-Shift-A optimises it harder. "Go to the newest result" has no key until one is set: it
// gives the newest card the keys. People change them in Settings. There is no pause key:
// pausing is a setting (Settings, Shortcuts, the CLI), with no state of its own on screen.

import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    public static let optimiseClipboard = Self("optimiseClipboard", default: .init(.c, modifiers: [.control, .shift]))
    public static let optimiseClipboardHarder = Self("optimiseClipboardHarder", default: .init(.a, modifiers: [.control, .shift]))
    public static let focusNewestResult = Self("focusNewestResult")
}

public enum Hotkeys {
    public static var all: [(name: KeyboardShortcuts.Name, title: String)] {
        [
            (.optimiseClipboard, Strings.text("Optimise the clipboard")),
            (.optimiseClipboardHarder, Strings.text("Optimise the clipboard harder")),
            (.focusNewestResult, Strings.text("Go to the newest result")),
        ]
    }

    /// What each hotkey does, apart from the key handling so tests can press them.
    @MainActor
    static func action(for name: KeyboardShortcuts.Name) -> (AppModel) -> Void {
        switch name {
        case .optimiseClipboardHarder: return { $0.optimiseClipboardNow(aggressive: true) }
        case .focusNewestResult: return { $0.focusNewestResult() }
        default: return { $0.optimiseClipboardNow(aggressive: false) }
        }
    }

    @MainActor
    static func register(_ model: AppModel) {
        for (name, _) in all {
            let run = action(for: name)
            KeyboardShortcuts.onKeyUp(for: name) { [weak model] in if let model { run(model) } }
        }
    }
}
