// SPDX-License-Identifier: GPL-3.0-or-later
//
// Global hotkeys, with Clop 3.5's default keys: Control-Shift-C optimises the clipboard,
// Control-Shift-A optimises it harder, Control-Shift-P pauses automatic optimisation or resumes
// it (the same setting as Settings, Shortcuts and the CLI) and says so in a notice. "Go to the
// newest result" has no key until one is set: it gives the newest card the keys. People change
// them in Settings.
// A pipeline's `hotkey:` (front matter) runs that pipeline on the clipboard; those keys follow the
// pipeline files and are registered again whenever they change.

import AppKit
import EsclopPipelines
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    public static let optimiseClipboard = Self("optimiseClipboard", default: .init(.c, modifiers: [.control, .shift]))
    public static let optimiseClipboardHarder = Self("optimiseClipboardHarder", default: .init(.a, modifiers: [.control, .shift]))
    public static let focusNewestResult = Self("focusNewestResult")
    public static let togglePause = Self("togglePause", default: .init(.p, modifiers: [.control, .shift]))
}

public enum Hotkeys {
    public static var all: [(name: KeyboardShortcuts.Name, title: String)] {
        [
            (.optimiseClipboard, Strings.text("Optimise the clipboard")),
            (.optimiseClipboardHarder, Strings.text("Optimise the clipboard harder")),
            (.focusNewestResult, Strings.text("Go to the newest result")),
            (.togglePause, Strings.text("Pause or resume automatic optimisation")),
        ]
    }

    /// What each hotkey does, apart from the key handling so tests can press them.
    @MainActor
    static func action(for name: KeyboardShortcuts.Name) -> (AppModel) -> Void {
        switch name {
        case .optimiseClipboardHarder: return { $0.optimiseClipboardNow(aggressive: true) }
        case .focusNewestResult: return { $0.focusNewestResult() }
        case .togglePause: return { $0.togglePause(announcing: KeyboardShortcuts.Name.togglePause.shortcut.map { "\($0)" } ?? "⌃⇧P") }
        default: return { $0.optimiseClipboardNow(aggressive: false) }
        }
    }

    // MARK: Pipelines

    /// The names registered for pipelines now, to take back when the pipelines change.
    // ponytail: KeyboardShortcuts cannot list names, so a pipeline deleted while the app was closed
    // leaves its `KeyboardShortcuts_pipeline.<name>` default behind, with no handler; clear stale
    // keys at launch if they ever matter.
    @MainActor private(set) static var pipelineNames: [KeyboardShortcuts.Name] = []

    /// The key name of a pipeline's hotkey.
    static func name(for pipeline: String) -> KeyboardShortcuts.Name { .init("pipeline." + pipeline) }

    /// Registers each pipeline's hotkey in place of the ones registered before. A hotkey that does
    /// not read is left out.
    @MainActor
    public static func register(_ pipelines: [Pipeline], model: AppModel) {
        for name in pipelineNames {
            KeyboardShortcuts.removeHandler(for: name)
            KeyboardShortcuts.setShortcut(nil, for: name)
        }
        pipelineNames = []
        for pipeline in pipelines {
            guard let shortcut = shortcut(pipeline.hotkey) else { continue }
            let name = name(for: pipeline.name)
            KeyboardShortcuts.setShortcut(shortcut, for: name)
            KeyboardShortcuts.onKeyUp(for: name) { [weak model] in model?.runOnClipboard(pipeline) }
            pipelineNames.append(name)
        }
    }

    /// `ctrl+alt+cmd+b`: modifiers (`ctrl`, `alt` or `opt`, `cmd`, `shift`, also ⌃ ⌥ ⌘ ⇧) and one
    /// key: a letter, a digit, `f1`…`f20`, `space`, `return`, `tab`, `escape` or `delete`. Nil
    /// when it does not read or has no modifier.
    static func shortcut(_ text: String?) -> KeyboardShortcuts.Shortcut? {
        guard let text else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        var key: KeyboardShortcuts.Key?
        for part in text.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "ctrl", "control", "⌃": modifiers.insert(.control)
            case "alt", "opt", "option", "⌥": modifiers.insert(.option)
            case "cmd", "command", "⌘": modifiers.insert(.command)
            case "shift", "⇧": modifiers.insert(.shift)
            default:
                guard key == nil, let found = keys[part] else { return nil }
                key = found
            }
        }
        guard let key, !modifiers.isEmpty else { return nil }
        return .init(key, modifiers: modifiers)
    }

    private static let keys: [String: KeyboardShortcuts.Key] = {
        let letters: [KeyboardShortcuts.Key] = [.a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z]
        let digits: [KeyboardShortcuts.Key] = [.zero, .one, .two, .three, .four, .five, .six, .seven, .eight, .nine]
        let functions: [KeyboardShortcuts.Key] = [.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20]
        var keys: [String: KeyboardShortcuts.Key] = ["space": .space, "return": .return, "tab": .tab, "escape": .escape, "delete": .delete]
        for (i, key) in letters.enumerated() { keys[String(UnicodeScalar(UInt8(97 + i)))] = key }
        for (i, key) in digits.enumerated() { keys[String(i)] = key }
        for (i, key) in functions.enumerated() { keys["f\(i + 1)"] = key }
        return keys
    }()

    @MainActor
    static func register(_ model: AppModel) {
        for (name, _) in all {
            let run = action(for: name)
            KeyboardShortcuts.onKeyUp(for: name) { [weak model] in if let model { run(model) } }
        }
    }
}
