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
    @State private var headerHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the arrow is: the bottom edge when the popover sits above its button.
    let arrowAtBottom: Bool

    public init(model: OptionsModel, arrowAtBottom: Bool = true) {
        _model = State(initialValue: model)
        self.arrowAtBottom = arrowAtBottom
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                OptionsHeader(model: model)
                if model.drill == nil {
                    Segments(options: model.tabs, selection: $model.tab, title: \.title)
                        .accessibilityLabel(Strings.text("Options"))
                }
            }
            .padding([.horizontal, .top], OptionsType.padding)
            .padding(.bottom, 8)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }

            ScrollView {
                content
                    .padding(.horizontal, OptionsType.padding)
                    .padding(.top, 4)
                    .padding(.bottom, OptionsType.padding)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollIndicators(.automatic)
            // A definite height from the first layout: AppKit places the popover with its first
            // size, and an unmeasured scroll view would make it flip below the button.
            .frame(height: min(contentHeight > 0 ? contentHeight : 200, max(120, OptionsType.maxHeight - max(headerHeight, 120))))
            .mask(alignment: .bottom) { fade }
        }
        .frame(width: OptionsType.width)
        .font(OptionsType.body)
        // Our own surface and inks over the glass: their contrast is known (PopoverInk).
        .foregroundStyle(PopoverInk.primary.color)
        .background(PopoverInk.surface.color)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: model.tab)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.showsFormatOptions)
        .background { shortcuts }
        .background { PopoverEdgePin(arrowAtBottom: arrowAtBottom).frame(width: 0, height: 0) }
        .task { await model.appear() }
        .onDisappear { model.disappear() }
    }

    @ViewBuilder private var content: some View {
        if let drill = model.drill {
            OptionsDrill(model: model, drill: drill)
        } else {
            switch model.tab {
            case .optimise: OptimiseTab(model: model)
            case .size: SizeTab(model: model)
            case .sound: SoundTab(model: model)
            case .share: ShareTab(model: model)
            }
        }
    }

    /// The bottom 24 pt fade out only when there is more to scroll to.
    private var fade: some View {
        let scrolls = contentHeight > OptionsType.maxHeight - headerHeight
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
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Thumbnail, editable name, "2.4 MB → 612 kB · −75 %", format and dimensions.
struct OptionsHeader: View {
    @Bindable var model: OptionsModel
    @FocusState private var editing: Bool

    var body: some View {
        let info = model.card.presentation
        HStack(alignment: .center, spacing: 10) {
            Group {
                if let image = model.card.thumbnail {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "doc").font(.title2).foregroundStyle(PopoverInk.secondary.color)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                TextField(Strings.text("File name"), text: $model.name)
                    .textFieldStyle(.plain)
                    .font(OptionsType.title)
                    .focused($editing)
                    .onSubmit { model.commitName() }
                    .disabled(model.card.result == nil)
                    .accessibilityLabel(Strings.text("File name"))
                Group {
                    if model.card.isWorking {
                        Text(Strings.text("Optimising…"))
                    } else if let result = model.card.result, Figures.isNoSaving(before: result.bytesBefore, after: result.bytesAfter) {
                        Text(Strings.format("Already optimised · %@", Figures.bytes(result.bytesAfter)))
                    } else if let result = model.card.result {
                        Text(Figures.change(before: result.bytesBefore, after: result.bytesAfter) + " · ")
                            + Text(Figures.percent(before: result.bytesBefore, after: result.bytesAfter)).foregroundStyle(PopoverInk.accent.color).fontWeight(.semibold)
                    } else {
                        Text(info.change)
                    }
                }
                .font(OptionsType.label)
                .monospacedDigit()
                Text(model.headerMeta).font(OptionsType.label).foregroundStyle(PopoverInk.secondary.color).monospacedDigit().lineLimit(1)
            }
        }
        .onChange(of: editing) { _, now in if !now { model.commitName() } }
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
