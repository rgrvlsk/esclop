// SPDX-License-Identifier: GPL-3.0-or-later
//
// The app's main menu. L'Esclop is a menu bar app, so it never shows, but text fields and
// windows find their key equivalents in it: ⌘C, ⌘V and ⌘Z in Settings and the pipeline editor,
// ⌘W to close a window, ⌘Q to quit.

import AppKit

@MainActor
public enum MainMenu {
    public static func make() -> NSMenu {
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            items.forEach(submenu.addItem)
            item.submenu = submenu
            return item
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        let main = NSMenu()
        main.addItem(menu("L'Esclop", [item("Quit L'Esclop", #selector(NSApplication.terminate(_:)), "q")]))
        main.addItem(menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]))
        main.addItem(menu("Window", [item("Close", #selector(NSWindow.performClose(_:)), "w")]))
        return main
    }
}
