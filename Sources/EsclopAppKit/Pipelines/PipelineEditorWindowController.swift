// SPDX-License-Identifier: GPL-3.0-or-later
//
// The one pipeline editor window, opened from the menu, from Settings and by
// `esclop://pipelines` or `esclop://pipelines/<name>`.

import AppKit
import EsclopCore
import SwiftUI

@MainActor
public final class PipelineEditorWindowController {
    public let model: PipelineEditorModel
    private(set) var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    public init(model: PipelineEditorModel) {
        self.model = model
    }

    public var isVisible: Bool { window?.isVisible ?? false }

    /// Shows the window on `name` (a saved pipeline or a template), or as it was.
    public func show(_ name: String? = nil) {
        model.reload()
        model.open(name: name)
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Opens the window for an `esclop://pipelines` link. False when the link is not one.
    @discardableResult
    public func open(_ url: URL) -> Bool {
        guard let route = Self.route(url) else { return false }
        show(route.name)
        return true
    }

    /// `esclop://pipelines` (name nil) or `esclop://pipelines/<name>`.
    nonisolated static func route(_ url: URL) -> PipelinesRoute? {
        guard url.scheme == "esclop", url.host() == "pipelines" else { return nil }
        let name = url.pathComponents.filter { $0 != "/" }.joined(separator: "/")
        return PipelinesRoute(name: name.isEmpty ? nil : name)
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: PipelineEditorView(model: model))
        host.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: host)
        window.title = Strings.text("Pipelines")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 900, height: 680))
        window.contentMinSize = NSSize(width: 760, height: 520)
        window.center()
        window.setFrameAutosaveName("dev.esclop.pipelines")
        // A "Try it" copy does not outlive the window.
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak model] _ in
            MainActor.assumeIsolated { model?.discardTry() }
        }
        return window
    }
}

/// Where an `esclop://pipelines` link points.
struct PipelinesRoute: Equatable, Sendable {
    /// Nil for the window as it was.
    var name: String?
}
