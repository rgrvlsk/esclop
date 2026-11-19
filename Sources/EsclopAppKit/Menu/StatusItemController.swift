// SPDX-License-Identifier: GPL-3.0-or-later
//
// The menu bar glyph and its panel. A click on the glyph opens the panel under it; a click on the
// glyph again, a click anywhere else, Esc or a command closes it. The panel never activates the
// app, so the app in front keeps its windows, but it becomes key so its shortcuts work (⌘O, ⌘,).

import AppKit
import SwiftUI

@MainActor
public final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    private let makeActions: (_ close: @escaping () -> Void) -> MenuPanelActions
    private var panel: MenuPanelWindow?
    private var outside: Any?
    private var keys: Any?
    private var resign: NSObjectProtocol?

    public init(model: AppModel, actions: @escaping (_ close: @escaping () -> Void) -> MenuPanelActions) {
        self.model = model
        makeActions = actions
        super.init()
        if let button = item.button {
            button.image = MenuBarLabel.customGlyph ?? NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: nil)
            button.setAccessibilityLabel("L'Esclop")
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
    }

    public var isOpen: Bool { panel?.isVisible ?? false }

    @objc func toggle() {
        isOpen ? close() : open()
    }

    public func open() {
        guard let button = item.button, let buttonWindow = button.window else { return }
        let glyph = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        let panel = MenuPanelWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.title = "L'Esclop"
        panel.contentView = host

        // Lay out once to learn the height, then place the panel under the glyph, inside the
        // screen, with the notch over the glyph's centre.
        let shadow = Self.shadowRoom
        let width = MenuPanel.width + 2 * shadow
        let probe = MenuPanel(model: model, actions: makeActions { [weak self] in self?.close() }, notch: nil)
        host.rootView = AnyView(probe.padding(shadow).designTint())
        let height = host.fittingSize.height
        var x = glyph.midX - width / 2
        x = min(max(x, screen.minX + 4 - shadow), screen.maxX - 4 + shadow - width)
        let frame = NSRect(x: x, y: glyph.minY - 2 - height + shadow, width: width, height: height)
        let notch = glyph.midX - frame.minX - shadow
        host.rootView = AnyView(
            MenuPanel(model: model, actions: makeActions { [weak self] in self?.close() }, notch: notch)
                .padding(shadow)
                // Taller or shorter as rows come and go, from the top edge.
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { [weak panel] height in
                    guard let panel, abs(panel.frame.height - height) > 0.5 else { return }
                    var frame = panel.frame
                    frame.origin.y += frame.height - height
                    frame.size.height = height
                    panel.setFrame(frame, display: true)
                }
                .designTint()
        )
        panel.setFrame(frame, display: false)

        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        item.button?.highlight(true)
        outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard event.window === panel, event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.close() }
            return nil
        }
        resign = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    public func close() {
        if let outside { NSEvent.removeMonitor(outside) }
        if let keys { NSEvent.removeMonitor(keys) }
        if let resign { NotificationCenter.default.removeObserver(resign) }
        outside = nil
        keys = nil
        resign = nil
        panel?.orderOut(nil)
        panel = nil
        item.button?.highlight(false)
    }

    /// Room around the panel for its shadow, inside the window.
    static let shadowRoom: CGFloat = 18
}

/// A borderless panel that can be key, so the shortcuts printed in it work.
final class MenuPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
