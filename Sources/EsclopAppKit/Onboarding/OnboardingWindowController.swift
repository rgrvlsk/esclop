// SPDX-License-Identifier: GPL-3.0-or-later
//
// The first-run window. Opens by itself on the first launch; the menu's "Welcome to L'Esclop…"
// opens it again at the first step. Finishing or skipping closes it; closing it finishes it.

import AppKit
import SwiftUI

@MainActor
public final class OnboardingWindowController {
    public let model: OnboardingModel
    let settings: SettingsWindowController
    private var window: NSWindow?
    private var closing: (any NSObjectProtocol)?

    public init(model: OnboardingModel, settings: SettingsWindowController) {
        self.model = model
        self.settings = settings
        model.onFinish = { [weak self] in self?.window?.close() }
    }

    /// On launch: only until the person has finished or skipped it once.
    public func showIfFirstRun() {
        if model.shouldShowAtLaunch { show() }
    }

    public func show() {
        if !(window?.isVisible ?? false) { model.restart() }
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func makeWindow() -> NSWindow {
        let view = OnboardingView(onboarding: model, settings: settings.model) { [weak settings] in settings?.show() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = Strings.text("Welcome to L’Esclop")
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        // The close button and ⌘W end the tour like Skip; it stays in the menu.
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { [weak model] _ in
            MainActor.assumeIsolated { model?.windowClosed() }
        }
        return window
    }
}
