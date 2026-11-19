// SPDX-License-Identifier: GPL-3.0-or-later
//
// The options popover from the "…" button (DESIGN.md › Options popover): one file, about 360 pt
// wide and never taller than 560 pt. The header and the tabs stay pinned; the tab's content
// scrolls inside with a fade at the bottom edge. Drill-downs replace the content in place.

import AppKit
import EsclopCore
import SwiftUI

public struct OptionsPopover: View {
    @State private var model: OptionsModel
    @State private var contentHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the arrow is: the bottom edge when the popover sits above its button.
    let arrowAtBottom: Bool

    public init(model: OptionsModel, arrowAtBottom: Bool = true) {
        _model = State(initialValue: model)
        self.arrowAtBottom = arrowAtBottom
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.drill == nil {
                FusedTabs(tabs: model.tabs, selection: $model.tab)
            }
            ScrollView {
                content
                    .padding(.horizontal, OptionsType.padding)
                    .padding(.top, model.drill == nil ? 14 : OptionsType.padding)
                    .padding(.bottom, OptionsType.padding)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollIndicators(.automatic)
            // A definite height from the first layout: AppKit places the popover with its first
            // size, and an unmeasured scroll view would make it flip below the button.
            .frame(height: min(contentHeight > 0 ? contentHeight : 200, OptionsType.maxHeight - FusedTabs.height))
            .mask(alignment: .bottom) { fade }
            .background { FusedPanel(drill: model.drill != nil) }
        }
        .frame(width: OptionsType.width)
        .font(OptionsType.body)
        .foregroundStyle(PopoverInk.primary.color)
        // The chosen tab's outline over the recessed bar, under the content.
        .backgroundPreferenceValue(FusedTabKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor, model.drill == nil {
                    FusedTabShape(tab: proxy[anchor], panelTop: FusedTabs.height, inset: FusedPanel.inset)
                        .fill(Surface.tile)
                }
            }
        }
        .background(Surface.recessed)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: model.tab)
        .background { shortcuts }
        .background { PopoverEdgePin(arrowAtBottom: arrowAtBottom).frame(width: 0, height: 0) }
        .task { await model.appear() }
        .onDisappear { model.disappear() }
        .designTint()
    }

    @ViewBuilder private var content: some View {
        if let drill = model.drill {
            OptionsDrill(model: model, drill: drill)
        } else {
            switch model.tab {
            case .optimise: OptimiseTab(model: model)
            case .size: SizeTab(model: model)
            case .crop: CropSection(model: model)
            case .sound: SoundTab(model: model)
            case .share: ShareTab(model: model)
            }
        }
    }

    /// The bottom 24 pt fade out only when there is more to scroll to.
    private var fade: some View {
        let scrolls = contentHeight > OptionsType.maxHeight - FusedTabs.height
        return VStack(spacing: 0) {
            Rectangle()
            LinearGradient(colors: [.black, .black.opacity(scrolls ? 0 : 1)], startPoint: .top, endPoint: .bottom).frame(height: 24)
        }
    }

    /// The listed ⌘ shortcuts work from any tab.
    private var shortcuts: some View {
        Group {
            Button("") { model.app.perform(.copy, on: model.card) }.keyboardShortcut("c")
            Button("") { model.app.saveAs(model.card) }.keyboardShortcut("s")
            Button("") { model.app.perform(.reveal, on: model.card) }.keyboardShortcut("r")
            Button("") { model.app.perform(.undo, on: model.card) }.keyboardShortcut("z")
            // ⌘Y as in Finder: a bare Space would take the key from a focused tile or checkbox.
            Button("") { model.app.quickLook(model.card) }.keyboardShortcut("y")
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The round tabs (docs/design/targets: pr4-options-popover-tabs): one symbol each, the chosen one
/// fused with the panel under it like a folder's tab, and the tab's name in small caps at the end.
struct FusedTabs: View {
    let tabs: [OptionsTab]
    @Binding var selection: OptionsTab

    static let height: CGFloat = 64
    static let side: CGFloat = 40

    var body: some View {
        HStack(spacing: 10) {
            ForEach(tabs) { tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    // Thin symbols, about a third of the tab, as in the owner's reference
                        // (Intellecta's tabs).
                    Image(systemName: tab.symbol)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(PopoverInk.primary.color)
                        .frame(width: Self.side, height: Self.side)
                        .background {
                            // Resting tabs are raised like every control; the chosen one is the
                            // same circle, fused into the panel.
                            if !selected { Color.clear.raised(Circle(), fill: Surface.tile) }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(PressScale())
                .anchorPreference(key: FusedTabKey.self, value: .bounds) { selected ? $0 : nil }
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
            Spacer(minLength: 8)
            Text(selection.title)
                .font(Typeface.section)
                .textCase(.uppercase)
                .tracking(2)
                .foregroundStyle(PopoverInk.primary.color.opacity(0.8))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .frame(height: Self.height, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.text("Options"))
    }
}

struct FusedTabKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// The panel under the tabs, in the lighter tile; a drill-down fills the popover with it.
struct FusedPanel: View {
    var drill: Bool
    static let inset: CGFloat = 8
    static let radius: CGFloat = 18

    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: drill ? 0 : Self.radius, bottomLeadingRadius: Self.radius,
            bottomTrailingRadius: Self.radius, topTrailingRadius: drill ? 0 : Self.radius, style: .continuous
        )
        .fill(Surface.tile)
        .padding([.horizontal, .bottom], drill ? 0 : Self.inset)
    }
}

/// The chosen tab and the panel as one outline: the tab's circle, a neck down into the panel,
/// and fillets where they meet, as the "…" menu's drop does (`LiquidMenuShape.fillet`).
struct FusedTabShape: Shape {
    var tab: CGRect
    var panelTop: CGFloat
    var inset: CGFloat

    func path(in rect: CGRect) -> Path {
        // The chosen tab is the same circle as the others (owner: one geometry for the tabs).
        let lip = tab
        let circle = CGPath(roundedRect: lip, cornerWidth: lip.width / 2, cornerHeight: lip.width / 2, transform: nil)
        let neck = CGPath(rect: CGRect(x: lip.minX, y: lip.midY, width: lip.width, height: panelTop - lip.midY + FusedPanel.radius), transform: nil)
        let panel = CGPath(
            roundedRect: CGRect(x: inset, y: panelTop, width: rect.width - 2 * inset, height: FusedPanel.radius * 2),
            cornerWidth: FusedPanel.radius, cornerHeight: FusedPanel.radius, transform: nil
        )
        // A wide fillet where the tab meets the panel, as in the reference (about 11 pt).
        return Path(LiquidMenuShape.fillet(circle.union(neck).union(panel), radius: 11))
    }
}

/// Keeps the popover's arrow on its button while the content grows or shrinks. AppKit places a
/// popover once and then resizes it from the top, so a popover above its button would grow down
/// over the thumbnail. This pins the edge that carries the arrow.
struct PopoverEdgePin: NSViewRepresentable {
    /// The arrow is on the popover's bottom edge (the popover sits above its button).
    var arrowAtBottom: Bool

    func makeNSView(context: Context) -> PinView {
        let view = PinView()
        view.arrowAtBottom = arrowAtBottom
        return view
    }

    func updateNSView(_ view: PinView, context: Context) {
        view.arrowAtBottom = arrowAtBottom
    }

    final class PinView: NSView {
        var arrowAtBottom = true
        private var pinned: CGFloat?
        nonisolated(unsafe) private var observer: NSObjectProtocol?
        private var previous: NSRunningApplication?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            pinned = nil
            guard let window else {
                // The popover closed: give focus back to the app the person was working in.
                if let previous, NSApp.isActive { previous.activate() }
                previous = nil
                return
            }
            // The first frame is where AppKit put the popover against its button.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                self.pinned = self.arrowAtBottom ? window.frame.minY : window.frame.maxY
                // Only the active app, or a non-activating panel, gets keystrokes, and a popover
                // is not a panel. For Return, arrows and typing a name or a size to reach it, the
                // app comes forward while the popover is open; closing hands focus back.
                if !NSApp.isActive {
                    self.previous = NSWorkspace.shared.frontmostApplication
                    NSApp.activate(ignoringOtherApps: true)
                }
                window.makeKey()
            }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restore() }
            }
        }

        private func restore() {
            guard let window, let pinned else { return }
            var frame = window.frame
            let edge = arrowAtBottom ? frame.minY : frame.maxY
            guard abs(edge - pinned) > 0.5 else { return }
            frame.origin.y = arrowAtBottom ? pinned : pinned - frame.height
            window.setFrameOrigin(frame.origin)
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
