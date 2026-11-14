// SPDX-License-Identifier: GPL-3.0-or-later
//
// The detail's "…" menu (docs/design/targets: pr2-detail-card): a cream panel outside the card,
// on the side that faces the screen, joined to the round "…" button by a liquid neck. It opens
// as a drop that leaves the button and spreads into the panel while the neck thins, and closes
// back into the button. The outline is one vector path (the button's circle, the neck and the
// panel, united), so it stays sharp at any scale and carries one hairline and one shadow.
//
// The detail publishes where its "…" and its card are (`LiquidMenuAnchor`); the stack draws the
// menu over every card, with a click catcher under it, and widens itself while it is open so
// the panel does not clip it.

import AppKit
import EsclopCore
import SwiftUI

// MARK: - Geometry

/// The menu's outline at `progress` 0 (the button alone) to 1 (open). A spring may carry it a
/// little past 1.
struct LiquidMenuShape: Shape {
    /// The "…" button's circle, in the shape's coordinates.
    var button: CGRect
    /// The open panel.
    var panel: CGRect
    var progress: CGFloat
    var radius: CGFloat = LiquidMenu.radius

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in _: CGRect) -> Path {
        Path(Self.outline(button: button, panel: panel, progress: progress, radius: radius))
    }

    /// The panel's rectangle at `progress`: from the button's own square to the open panel. The
    /// drop travels out before it spreads, so its height lags its width.
    static func panel(button: CGRect, panel: CGRect, progress: CGFloat) -> CGRect {
        let across = progress
        let along = pow(max(progress, 0), 1.6)
        func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
        let minX = mix(button.minX, panel.minX, across), maxX = mix(button.maxX, panel.maxX, across)
        let minY = mix(button.minY, panel.minY, along), maxY = mix(button.maxY, panel.maxY, along)
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    /// The neck's waist, its full thickness: as wide as the button while the drop leaves, 9 pt
    /// once the panel stands `LiquidMenu.gap` away.
    static func waist(gap: CGFloat, button: CGFloat) -> CGFloat {
        let t = min(max(gap / LiquidMenu.gap, 0), 1)
        let eased = t * t * (3 - 2 * t)
        return button * 0.8 + (LiquidMenu.waist - button * 0.8) * eased
    }

    static func outline(button: CGRect, panel open: CGRect, progress: CGFloat, radius: CGFloat) -> CGPath {
        // Worked out with the panel to the right of the button, then mirrored when it is not.
        let leftward = open.midX < button.midX
        let mirror = CGAffineTransform(translationX: 2 * button.midX, y: 0).scaledBy(x: -1, y: 1)
        let target = leftward ? open.applying(mirror) : open
        let rect = Self.panel(button: button, panel: target, progress: max(progress, 0))
        let r = button.width / 2
        let centre = CGPoint(x: button.midX, y: button.midY)
        // Round as a drop while it travels, the panel's corner once it has spread.
        let settle = min(max((progress - 0.3) / 0.7, 0), 1)
        let eased = settle * settle * (3 - 2 * settle)
        let round = min(rect.width, rect.height) / 2
        let corner = min(round + (radius - round) * eased, round)

        var shape = CGPath(ellipseIn: button, transform: nil)
        if rect.width > 0.5, rect.height > 0.5 {
            shape = shape.union(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
        }
        if let neck = neck(centre: centre, radius: r, panel: rect, corner: corner) {
            shape = shape.union(neck)
        }
        shape = fillet(shape, radius: Self.fillet)
        guard leftward else { return shape }
        var flip = mirror
        return shape.copy(using: &flip) ?? shape
    }

    /// Every inside corner of the outline rounded to `fillet`: where the drop still overlaps the
    /// button, circle and drop meet in sharp notches that a liquid never shows (filmed in the
    /// app). A morphological closing: grow the outline by the radius, then shrink it back;
    /// outside curves come back as they were.
    static let fillet: CGFloat = 6

    static func fillet(_ shape: CGPath, radius: CGFloat) -> CGPath {
        let grown = shape.union(shape.copy(strokingWithWidth: 2 * radius, lineCap: .round, lineJoin: .round, miterLimit: 1))
        return grown.subtracting(grown.copy(strokingWithWidth: 2 * radius, lineCap: .round, lineJoin: .round, miterLimit: 1))
    }

    /// The neck between the circle and the panel's near side: two concave curves that leave the
    /// circle along its tangent, pinch to the waist and meet the panel's outline, its rounded
    /// corner included, so a drop still round in flight stays joined. Nil while the panel still
    /// overlaps the circle.
    static func neck(centre: CGPoint, radius r: CGFloat, panel: CGRect, corner: CGFloat) -> CGPath? {
        let edge = panel.minX
        let gap = edge - (centre.x + r)
        guard gap > 0.5, panel.minY < centre.y, panel.maxY > centre.y else { return nil }
        let room = min(centre.y - panel.minY, panel.maxY - centre.y) - 0.5
        let waist = min(waist(gap: gap, button: 2 * r) / 2, room * 0.7)
        let flare = waist + min(10, gap * 0.6 + 4)
        let top = max(centre.y - flare, panel.minY + 0.5)
        let bottom = min(centre.y + flare, panel.maxY - 0.5)
        // The panel's outline on its near side at height `y`: the straight edge, or the corner's arc.
        func side(_ y: CGFloat) -> CGFloat {
            let upper = panel.minY + corner, lower = panel.maxY - corner
            let dy = y < upper ? upper - y : (y > lower ? y - lower : 0)
            return edge + corner - (max(corner * corner - dy * dy, 0)).squareRoot()
        }
        let reachTop = CGPoint(x: side(top), y: top)
        let reachBottom = CGPoint(x: side(bottom), y: bottom)
        let inside = edge + max(corner, 1)

        // Where the curves leave the circle: 55° either side of the axis toward the panel.
        let angle = CGFloat.pi * 55 / 180
        let leaveTop = CGPoint(x: centre.x + r * CGFloat(Foundation.cos(Double(angle))), y: centre.y - r * CGFloat(Foundation.sin(Double(angle))))
        let leaveBottom = CGPoint(x: leaveTop.x, y: centre.y + (centre.y - leaveTop.y))
        let tangent = CGPoint(x: CGFloat(Foundation.sin(Double(angle))), y: CGFloat(Foundation.cos(Double(angle))))
        let middle = centre.x + r + gap * 0.45
        let reach = min(gap * 0.5, r)

        let path = CGMutablePath()
        path.move(to: leaveTop)
        path.addCurve(
            to: CGPoint(x: middle, y: centre.y - waist),
            control1: CGPoint(x: leaveTop.x + tangent.x * reach, y: leaveTop.y + tangent.y * reach),
            control2: CGPoint(x: middle - (middle - leaveTop.x) * 0.5, y: centre.y - waist)
        )
        path.addCurve(
            to: reachTop,
            control1: CGPoint(x: middle + (reachTop.x - middle) * 0.6, y: centre.y - waist),
            control2: CGPoint(x: reachTop.x, y: top + (centre.y - waist - top) * 0.6)
        )
        // Through the panel's body, so the union leaves no seam.
        path.addLine(to: CGPoint(x: inside, y: top))
        path.addLine(to: CGPoint(x: inside, y: bottom))
        path.addLine(to: reachBottom)
        path.addCurve(
            to: CGPoint(x: middle, y: centre.y + waist),
            control1: CGPoint(x: reachBottom.x, y: bottom - (bottom - centre.y - waist) * 0.6),
            control2: CGPoint(x: middle + (reachBottom.x - middle) * 0.6, y: centre.y + waist)
        )
        path.addCurve(
            to: leaveBottom,
            control1: CGPoint(x: middle - (middle - leaveTop.x) * 0.5, y: centre.y + waist),
            control2: CGPoint(x: leaveBottom.x + tangent.x * reach, y: leaveBottom.y - tangent.y * reach)
        )
        path.addLine(to: centre)
        path.closeSubpath()
        return path
    }
}

// MARK: - Where the menu goes

/// What the detail tells the stack: its card, the menu's actions, and where its "…" and the
/// card itself are.
struct LiquidMenuAnchor: Equatable {
    let card: ResultCard
    let actions: [CardPresentation.Action]
    /// What Share… shares, and the view at the detail's own "…" the services open from.
    let file: URL
    let share: SharingAnchor
    /// The panel goes to the left of the card (a right-hand corner).
    let leftward: Bool
    /// The card's own fill, so the menu reads as part of it.
    let fill: Color
    let button: Anchor<CGRect>
    let frame: Anchor<CGRect>

    static func == (a: Self, b: Self) -> Bool {
        a.card === b.card && a.actions == b.actions && a.file == b.file && a.share === b.share && a.leftward == b.leftward && a.fill == b.fill && a.button == b.button && a.frame == b.frame
    }
}

struct LiquidMenuKey: PreferenceKey {
    static let defaultValue: [LiquidMenuAnchor] = []
    static func reduce(value: inout [LiquidMenuAnchor], nextValue: () -> [LiquidMenuAnchor]) {
        value += nextValue()
    }
}

// MARK: - The menu

/// The open menu, drawn by the stack in its own coordinates.
struct LiquidMenu: View {
    let anchor: LiquidMenuAnchor
    let button: CGRect
    let card: CGRect
    let perform: (CardPresentation.Action) -> Void
    let close: () -> Void

    /// The panel's width, its corner, a row's height, and the gap between the card and the panel.
    nonisolated static let width: CGFloat = 184
    nonisolated static let radius: CGFloat = 14
    nonisolated static let row: CGFloat = 34
    nonisolated static let inset: CGFloat = 5
    nonisolated static let outside: CGFloat = 10
    /// The neck's span once open (button edge to panel edge) and its thinnest point.
    nonisolated static let gap: CGFloat = Metrics.detailPadding + outside
    nonisolated static let waist: CGFloat = 9
    /// When the rows start to show: once the drop has spread to its full width (about 200 ms
    /// into the spring, filmed in the app), so the outline never cuts their first letters.
    nonisolated static let rowsDelay: Double = 0.2
    /// What the stack adds on the card's open side while the menu shows: the panel, its gap,
    /// 16 pt for the spring carrying it past its place (seen clipped in the app at 12) and 12 pt
    /// for its shadow, less the stack's own margin.
    nonisolated static let room: CGFloat = width + outside + 16 + 12 - Metrics.screenMargin

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var progress: CGFloat = 0
    @State private var rows = false
    /// Stays true until the close has drawn its last frame, so the drop can sink back.
    @State private var mounted = false
    /// Reduce Motion's crossfade.
    @State private var fade: Double = 1
    @State private var keys = MenuKeys()

    private var open: Bool { anchor.card.machine.menuOpen }

    /// The open panel, centred on "…" and kept within the card's height.
    static func panel(button: CGRect, card: CGRect, count: Int, leftward: Bool) -> CGRect {
        let height = CGFloat(count) * row + 2 * inset
        var y = button.midY - height / 2
        y = min(y, card.maxY - height)
        y = max(y, card.minY)
        let x = leftward ? card.minX - outside - width : card.maxX + outside
        return CGRect(x: x, y: y, width: width, height: height)
    }

    var body: some View {
        let panel = Self.panel(button: button, card: card, count: anchor.actions.count, leftward: anchor.leftward)
        let shape = LiquidMenuShape(button: button, panel: panel, progress: progress)
        let shown = open || mounted
        // Everything is placed in the stack's coordinates, where the anchors resolve.
        ZStack {
            if shown {
                // A click anywhere else in the panel closes the menu and does nothing more.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                    .accessibilityHidden(true)
                shape
                    .fill(anchor.fill)
                    .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.16), radius: 9, y: 4)
                    // The card's edge: a dark hairline in light, a light rim in dark.
                    .overlay { shape.stroke(scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10), lineWidth: 0.5) }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                Button(action: close) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: button.width * 0.4, weight: .medium))
                        .foregroundStyle(Ink.text)
                        .frame(width: button.width, height: button.height)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .frame(width: button.width, height: button.height)
                .position(x: button.midX, y: button.midY)
                .accessibilityLabel(Strings.text("More options"))
                // The rows show only inside the outline, so they never stand out of the drop.
                list
                    .frame(width: panel.width, height: panel.height)
                    .position(x: panel.midX, y: panel.midY)
                    .mask { shape }
            }
        }
        .opacity(fade)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if open { animate(true) } }
        .onChange(of: open) { _, value in animate(value) }
        .onDisappear { keys.stop() }
    }

    /// The keys while it is open: arrows, Home and End move, Return or Space runs, Esc closes.
    /// Taken from the panel's events before SwiftUI's focus sees them: in the app, focus did not
    /// always reach the menu (after another window closed), and the keys went elsewhere.
    private func key(_ code: UInt16) -> Bool {
        switch code {
        case 125: return move(+1)
        case 126: return move(-1)
        case 115: return highlight(0)
        case 119: return highlight(anchor.actions.count - 1)
        case 36, 76, 49: return runHighlighted()
        case 53:
            close()
            return true
        default: return false
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(anchor.actions.enumerated()), id: \.element) { index, action in
                LiquidMenuRow(
                    separated: index > 0,
                    action: action,
                    highlighted: anchor.card.menuHighlight == index,
                    hover: { inside in
                        if inside { anchor.card.menuHighlight = index } else if anchor.card.menuHighlight == index { anchor.card.menuHighlight = nil }
                    },
                    choose: { choose(action) }
                )
                // The animation reaches the opacity alone. On the whole row it also carried the
                // row's layout, and in the app each row slid in from beyond the panel's far edge.
                .animation(reduceMotion ? Motion.crossfade : .easeOut(duration: 0.12).delay(rows ? Self.rowsDelay + 0.018 * Double(index) : 0)) {
                    $0.opacity(rows ? 1 : 0)
                }
            }
        }
        .padding(.vertical, Self.inset)
    }

    private func move(_ step: Int) -> Bool {
        let count = anchor.actions.count
        guard open, count > 0 else { return false }
        let current = anchor.card.menuHighlight ?? (step > 0 ? -1 : count)
        anchor.card.menuHighlight = (current + step + count) % count
        return true
    }

    private func highlight(_ index: Int) -> Bool {
        guard open, anchor.actions.indices.contains(index) else { return false }
        anchor.card.menuHighlight = index
        return true
    }

    private func runHighlighted() -> Bool {
        guard open, let index = anchor.card.menuHighlight, anchor.actions.indices.contains(index) else { return false }
        choose(anchor.actions[index])
        return true
    }

    /// Runs a row: Share… shows the system's share services at "…"; the rest go to the model.
    /// The menu closes first, and the action runs once the drop has sunk back: one that takes
    /// the detail away (Convert…, Move to Trash) would otherwise cut the menu off mid-way, and
    /// one that opens the options popover marks the card's menu open again, for the popover.
    private func choose(_ action: CardPresentation.Action) {
        close()
        guard action != .share else {
            anchor.share.show(anchor.file, leftward: anchor.leftward)
            return
        }
        let perform = perform
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.12 : 0.2)) { perform(action) }
    }

    /// Makes the panel key, so the keys reach it even while another app is in front (the panel
    /// does not activate the app), and listens to them.
    private func listen() {
        guard let window = anchor.share.window else { return }
        window.makeKey()
        keys.start(window: window, key: key)
    }

    private func animate(_ opening: Bool) {
        if opening { mounted = true }
        let unmount = { if !open { mounted = false } }
        if !opening { keys.stop() }
        if reduceMotion {
            // The open shape, faded in and out; nothing moves.
            if opening {
                progress = 1
                fade = 0
                listen()
            }
            withAnimation(.easeOut(duration: 0.12)) {
                fade = opening ? 1 : 0
                rows = opening
            } completion: {
                unmount()
                if !open { progress = 0 }
            }
            return
        }
        if opening {
            fade = 1
            listen()
            rows = true
            withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) { progress = 1 }
        } else {
            // The rows are gone before the drop starts to sink, so it never cuts their letters.
            withAnimation(.easeOut(duration: 0.07)) { rows = false }
            withAnimation(.easeIn(duration: 0.16).delay(0.08)) { progress = 0 } completion: { unmount() }
        }
    }
}

/// One row: the action's name, highlighted under the pointer or the arrow keys.
struct LiquidMenuRow: View {
    /// A hairline above it, between rows.
    let separated: Bool
    let action: CardPresentation.Action
    let highlighted: Bool
    let hover: (Bool) -> Void
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            Text(action.title)
                .font(.system(size: 13))
                .foregroundStyle(Ink.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: LiquidMenu.row, alignment: .leading)
                .padding(.horizontal, 14)
                .background {
                    if highlighted {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(NeutralFill.resting).padding(.horizontal, 5).padding(.vertical, 2)
                    }
                }
                .contentShape(Rectangle())
                .overlay(alignment: .top) {
                    if separated { Rectangle().fill(Ink.secondary.opacity(0.18)).frame(height: 0.5).padding(.horizontal, 12) }
                }
        }
        .buttonStyle(.plain)
        .onHover(perform: hover)
        .accessibilityLabel(action.accessibilityName)
    }
}

// MARK: - Keys

/// The menu's keys, taken from its panel's key events while it is open.
@MainActor
final class MenuKeys {
    private var monitor: Any?

    func start(window: NSWindow, key: @escaping (UInt16) -> Bool) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard event.window === window, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            return MainActor.assumeIsolated { key(event.keyCode) } ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Share

/// An AppKit view behind the detail's "…", so the system's share services open there, from a
/// click or a key.
@MainActor
final class SharingAnchor {
    private let host = NSView()
    private var picker: NSSharingServicePicker?

    var view: some View { SharingAnchorView(host: host) }

    /// The panel the detail is in.
    var window: NSWindow? { host.window }

    /// Shows the services beside the detail's "…". The anchor sits behind that button, which
    /// stays put while the menu sinks back and the panel shrinks.
    func show(_ file: URL, leftward: Bool) {
        guard host.window != nil else { return }
        let picker = NSSharingServicePicker(items: [file])
        self.picker = picker
        picker.show(relativeTo: host.bounds, of: host, preferredEdge: leftward ? .minX : .maxX)
    }
}

private struct SharingAnchorView: NSViewRepresentable {
    let host: NSView
    func makeNSView(context _: Context) -> NSView { host }
    func updateNSView(_: NSView, context _: Context) {}
}
