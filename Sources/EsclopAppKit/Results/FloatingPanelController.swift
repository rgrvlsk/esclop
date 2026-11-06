// SPDX-License-Identifier: GPL-3.0-or-later
//
// The borderless panel that holds the result cards at the chosen corner of the chosen screen.
// It never activates the app, joins every Space and sizes itself to the cards.

import AppKit
import EsclopCore
import SwiftUI

/// A panel that floats without taking focus from the frontmost app, but can become key when
/// the person clicks into it, so its buttons work from the keyboard.
final class FloatingPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        // A click makes it key (without activating the app), so Esc, ⌘Z and ⌘C reach the card.
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingPanelController {
    private let model: AppModel
    private let hosting: NSHostingView<FloatingStackView>
    private let panel: FloatingPanel
    private var screen: NSScreen?

    init(model: AppModel) {
        self.model = model
        hosting = NSHostingView(rootView: FloatingStackView(model: model))
        hosting.sizingOptions = []
        panel = FloatingPanel(content: hosting)
        panel.title = "L'Esclop results"
        hosting.rootView = FloatingStackView(model: model) { [weak self] size in self?.size = size }
    }

    private var size: CGSize = .zero {
        didSet { if size != oldValue { layout() } }
    }

    /// The frame the stack takes on `screen`, anchored to `corner`.
    static func frame(for size: CGSize, corner: ScreenCorner, in visible: CGRect) -> CGRect {
        let x = corner.isRight ? visible.maxX - size.width : visible.minX
        let y = corner.isTop ? visible.maxY - size.height : visible.minY
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The screen results go to: the one under the pointer, or the main one.
    static func targetScreen(followCursor: Bool) -> NSScreen? {
        if followCursor {
            let point = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) { return screen }
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Call after the cards change.
    func update() {
        if model.cards.isEmpty {
            // Let the last card's exit transition finish before the panel goes.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(260))
                guard let self, self.model.cards.isEmpty else { return }
                self.panel.orderOut(nil)
                self.screen = nil
            }
            return
        }
        if !panel.isVisible || screen == nil {
            screen = Self.targetScreen(followCursor: model.followCursorScreen)
        }
        if size == .zero { size = hosting.fittingSize }
        layout()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// The panel's frame, for the drop zone to stack above it.
    var visibleFrame: CGRect? { panel.isVisible ? panel.frame : nil }

    private func layout() {
        guard let screen, size.width > 0, size.height > 0 else { return }
        panel.setFrame(Self.frame(for: size, corner: model.corner, in: screen.visibleFrame), display: true)
    }
}
