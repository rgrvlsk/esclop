// SPDX-License-Identifier: GPL-3.0-or-later
//
// The one compare window, opened from a result (the detail card, the options popover, a batch
// row, the menu's recent results) and by `esclop://compare/<result id>`. Opening another result
// reuses the window.

import AppKit
import EsclopCore
import SwiftUI

@MainActor
public final class CompareWindowController {
    public let model: CompareModel
    private(set) var window: NSWindow?

    public init(model: CompareModel) {
        self.model = model
        model.onClose = { [weak self] in self?.window?.close() }
    }

    public var isVisible: Bool { window?.isVisible ?? false }

    public func show(_ result: OptimisationResult) {
        model.open(result)
        present()
    }

    /// Opens an `esclop://compare/<id>` link. False when the link is not one; an unknown id
    /// shows a notice instead of an empty window.
    @discardableResult
    public func open(_ url: URL) -> Bool {
        guard let id = Self.route(url) else { return false }
        if model.open(id: id) {
            present()
        } else {
            model.app.notice(Strings.text("Nothing to compare"), Strings.text("That result is no longer in the recent results."))
        }
        return true
    }

    /// The result id in `esclop://compare/<id>`.
    nonisolated static func route(_ url: URL) -> UUID? {
        guard url.scheme == "esclop", url.host() == "compare" else { return nil }
        return url.pathComponents.filter { $0 != "/" }.first.flatMap(UUID.init(uuidString:))
    }

    private func present() {
        let window = window ?? makeWindow()
        self.window = window
        window.title = Strings.format("Compare %@", model.result?.output.lastPathComponent ?? "")
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: CompareView(model: model)))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1040, height: 760))
        window.contentMinSize = NSSize(width: 720, height: 520)
        window.center()
        window.setFrameAutosaveName("dev.esclop.compare")
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak model] _ in
            MainActor.assumeIsolated { model?.players?.stop() }
        }
        return window
    }
}
