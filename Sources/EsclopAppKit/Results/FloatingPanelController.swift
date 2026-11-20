// SPDX-License-Identifier: GPL-3.0-or-later
//
// The borderless panel that holds the result cards at the chosen corner of the chosen screen.
// It never activates the app, joins every Space and sizes itself to the cards.

import AppKit
import EsclopCore
import SwiftUI

/// A panel that floats without taking focus from the frontmost app, but can become key when
/// the person clicks into it or presses "Go to the newest result", so its buttons work from the
/// keyboard. The pointer resting on a card gives it its card keys without that (`HoverKeys`).
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
        // Movement, not only entering and leaving, so a still pointer can be told from a pass.
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingPanelController {
    private let model: AppModel
    private let hosting: NSHostingView<PanelRoot>
    private let panel: FloatingPanel
    private var screen: NSScreen?
    private var swipeMonitor: Any?
    private var resignObserver: Any?
    private var swipe: CGFloat = 0

    init(model: AppModel) {
        self.model = model
        hosting = NSHostingView(rootView: PanelRoot(model: model))
        hosting.sizingOptions = []
        panel = FloatingPanel(content: hosting)
        panel.title = "L'Esclop results"
        hosting.rootView = PanelRoot(model: model) { [weak self] size in self?.contentSize = size }
        // A menu closes when the person turns to another window or app, as a system menu does.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closeMenus()
                // The keys went elsewhere: Esc on the card dismisses it again.
                for card in self?.model.cards ?? [] { card.lentKeys = false }
            }
        }
        model.onReturnKeys = { [weak self] in self?.returnKeys() }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.swiped(event) ? nil : event
        }
    }

    /// What the stack needs right now.
    private var contentSize: CGSize = .zero {
        didSet { if contentSize != oldValue { resize() } }
    }

    /// What the panel has: grows at once, shrinks only after the animation, so a result that
    /// grows into its detail or shrinks back is never clipped mid-way.
    private var size: CGSize = .zero
    private var shrink: Task<Void, Never>?

    private func resize() {
        let grown = CGSize(width: max(size.width, contentSize.width), height: max(size.height, contentSize.height))
        if grown != size {
            size = grown
            layout()
        }
        shrink?.cancel()
        guard contentSize != size else { return }
        shrink = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.size = self.contentSize
            self.layout()
        }
    }

    private func closeMenus() {
        for card in model.visibleCards where card.machine.detailMenuOpen {
            model.interact(card, .menu(false))
        }
    }

    /// A two-finger swipe toward the screen edge dismisses the result under the pointer, like the
    /// system screenshot thumbnail.
    private func swiped(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas, !model.visibleCards.contains(where: { $0.machine.menuOpen }) else { return false }
        if event.phase == .began { swipe = 0 }
        // Finger movement, whatever the scroll direction setting.
        swipe += event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        guard event.phase == .ended || event.phase == .cancelled else { return abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) }
        let towardEdge = model.corner.isRight ? swipe > 60 : swipe < -60
        swipe = 0
        guard towardEdge, let card = model.visibleCards.last(where: { $0.machine.hovering }) else { return false }
        model.dismiss(card)
        return true
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
        if contentSize == .zero { contentSize = hosting.fittingSize }
        layout()
        if !panel.isVisible { panel.orderFrontRegardless() }
        // "Go to the newest result": the keys come here without activating the app, as a click.
        // Esc, Undo, Copy or Save gives them back (`returnKeys`).
        if model.visibleCards.contains(where: \.wantsFocus) { panel.makeKey() }
    }

    /// The app in front gets its keys back and the cards stay: the panel never activated the
    /// app, so when it stops being key the window server gives the keys to the active app again.
    private func returnKeys() {
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    /// The panel's frame, for the drop zone to stack above it.
    var visibleFrame: CGRect? { panel.isVisible ? panel.frame : nil }

    private func layout() {
        guard let screen, size.width > 0, size.height > 0 else { return }
        panel.setFrame(Self.frame(for: size, corner: model.corner, in: screen.visibleFrame), display: true)
    }
}

/// The stack, pinned to the panel's corner while the panel is larger than it.
struct PanelRoot: View {
    let model: AppModel
    var onSize: (CGSize) -> Void = { _ in }

    var body: some View {
        let corner = model.corner
        FloatingStackView(model: model, onSize: onSize)
            .frame(
                maxWidth: .infinity, maxHeight: .infinity,
                alignment: corner.isTop ? (corner.isRight ? .topTrailing : .topLeading) : (corner.isRight ? .bottomTrailing : .bottomLeading)
            )
            .designTint()
    }
}
