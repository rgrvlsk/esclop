// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Settings window, an AppKit window around `SettingsView`, so the menu, `esclop://settings`
// links and other windows can open it at a pane and row. One window, reused.

import AppKit
import EsclopCore
import SwiftUI

@MainActor
public final class SettingsWindowController {
    public let model: SettingsViewModel
    public let agents: AgentsModel
    let actions: SettingsActions
    private var window: NSWindow?

    public init(model: SettingsViewModel, agents: AgentsModel = AgentsModel(), actions: SettingsActions) {
        self.model = model
        self.agents = agents
        self.actions = actions
    }

    public var isVisible: Bool { window?.isVisible ?? false }

    public func show(_ route: SettingsRoute? = nil) {
        if let route { model.open(route) }
        if model.pane == .agents { Task { await agents.refresh() } }
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Opens the window for an `esclop://settings` link. False when the link is not one.
    @discardableResult
    public func open(_ url: URL) -> Bool {
        guard let route = SettingsRoute(url: url, paneOf: model.pane(of:)) else { return false }
        show(route)
        return true
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: SettingsView(model: model, agents: agents, actions: actions))
        host.sceneBridgingOptions = [.title, .toolbars]
        let window = NSWindow(contentViewController: host)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 800, height: 620))
        window.contentMinSize = NSSize(width: 720, height: 480)
        window.center()
        window.setFrameAutosaveName("dev.esclop.settings")
        return window
    }
}
