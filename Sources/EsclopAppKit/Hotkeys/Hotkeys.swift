// SPDX-License-Identifier: GPL-3.0-or-later
//
// Global hotkeys, with Clop 3.5's default keys: Control-Shift-P cycles pause, Control-Shift-C
// optimises the clipboard, Control-Shift-A optimises it harder. People change them in Settings.

import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    public static let togglePause = Self("togglePause", default: .init(.p, modifiers: [.control, .shift]))
    public static let optimiseClipboard = Self("optimiseClipboard", default: .init(.c, modifiers: [.control, .shift]))
    public static let optimiseClipboardHarder = Self("optimiseClipboardHarder", default: .init(.a, modifiers: [.control, .shift]))
}

public enum Hotkeys {
    public static let all: [(name: KeyboardShortcuts.Name, title: String)] = [
        (.togglePause, "Pause or resume"),
        (.optimiseClipboard, "Optimise the clipboard"),
        (.optimiseClipboardHarder, "Optimise the clipboard harder"),
    ]

    /// What each hotkey does, apart from the key handling so tests can press them.
    @MainActor
    static func action(for name: KeyboardShortcuts.Name) -> (AppModel) -> Void {
        switch name {
        case .togglePause: return { $0.cyclePause() }
        case .optimiseClipboardHarder: return { $0.optimiseClipboardNow(aggressive: true) }
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
