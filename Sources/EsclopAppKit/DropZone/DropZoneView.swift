// SPDX-License-Identifier: GPL-3.0-or-later
//
// The drop zone at the results corner (`pr5-drop-zone`): one row of raised tiles on the popover's
// surface, the plain "Optimise" tile and up to four preset zones facing the screen, and under them
// "Drop to optimise · Hold ⌘ to optimise harder" (over a preset zone: "Drop to run “name”"; with
// ⌥: "The originals stay as they are"). The tile under the drag turns charcoal at the same height,
// as a chosen tile does in the options popover: one geometry, one elevation.

import SwiftUI

public struct DropZoneView: View {
    let state: DropZoneState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: DropZoneState) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: DropTiles.gap) {
                if state.zonesLeading { zoneRow }
                plainTarget
                if !state.zonesLeading { zoneRow }
            }
            hintLine
        }
        .padding(10)
        .padding(.bottom, 2)
        .background(PopoverInk.surface.color, in: RoundedRectangle(cornerRadius: Metrics.dropZoneRadius, style: .continuous))
        .glassSurface(RoundedRectangle(cornerRadius: Metrics.dropZoneRadius, style: .continuous))
        // Reduce Motion: the tiles change colour in a crossfade and do not grow (DESIGN.md › Motion).
        .animation(hoverAnimation, value: state.hovering)
        .animation(hoverAnimation, value: state.harder)
        .animation(hoverAnimation, value: state.keepOriginals)
        .animation(hoverAnimation, value: state.hoveredZone)
        .designTint()
    }

    private var hoverAnimation: Animation { reduceMotion ? Motion.crossfade : Motion.hover }

    private var plainTarget: some View {
        // Alone, it takes the panel's width, so it does not float under the hint line.
        DropTile(hovered: state.hovering, width: state.zones.isEmpty ? nil : DropTiles.plainWidth) {
            Group {
                if let glyph = MenuBarLabel.customGlyph {
                    Image(nsImage: glyph).renderingMode(.template)
                } else {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 17, weight: .medium))
                }
            }
            // Harder in the warm colour, on cream and on charcoal alike.
            .foregroundStyle(state.harder ? AnyShapeStyle(state.hovering ? Ink.warmOnCharcoal : PopoverInk.warm.color) : AnyShapeStyle(.primary))
        } label: {
            Text(state.tileTitle)
            if !state.count.isEmpty {
                Text(state.count).font(OptionsType.label).opacity(0.75).monospacedDigit()
            }
        }
        .reportFrame(DropZoneState.plainTarget, to: state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([state.plainTitle, state.count, state.plainHint].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    @ViewBuilder
    private var zoneRow: some View {
        if !state.zones.isEmpty {
            HStack(alignment: .top, spacing: DropTiles.gap) {
                ForEach(state.zones) { zone in
                    DropTile(hovered: state.hoveredZone == zone.name, width: DropTiles.zoneWidth) {
                        Image(systemName: zone.icon).font(.system(size: 15, weight: .medium))
                    } label: {
                        // A long name keeps its start and its end; the tooltip has all of it.
                        Text(zone.title).truncationMode(.middle)
                    }
                    .help(zone.title)
                    .reportFrame(zone.name, to: state)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Strings.format("Preset zone: %@", zone.title))
                    .accessibilityHint(Strings.text("Drop files here to run this pipeline on them."))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Strings.text("Preset zones"))
        }
    }

    @ViewBuilder private var hintLine: some View {
        if state.zones.isEmpty {
            line(state.title, state.hint)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .accessibilityHidden(true)
        } else {
            // Over a preset zone the line names its whole pipeline, in two lines at most, since a
            // tooltip cannot show while the mouse button is down. The tallest line the drag can
            // show keeps its room from the start: the panel is sized once, and the tiles must not
            // move under the drag. The plain line has two lines too, so Catalan's hint is whole.
            ZStack {
                ForEach(state.zones) { zone in
                    line(state.title(over: zone), "").lineLimit(2)
                    line(state.title(over: zone), Strings.text("The originals stay as they are")).lineLimit(2)
                }
                ForEach(Array(state.plainLines.enumerated()), id: \.offset) { _, plain in
                    line(plain.title, plain.hint).lineLimit(2)
                }
            }
            .hidden()
            .overlay {
                ViewThatFits(in: .vertical) {
                    line(state.title, state.hint)
                    // ⌥ over a zone whose name takes the room: what ⌥ does is said whole, and the
                    // name is on the tile.
                    if state.hoveredZone != nil, state.keepOriginals {
                        Text(state.hint).font(OptionsType.label).foregroundStyle(hintInk)
                    }
                    line(state.title, state.hint).lineLimit(2)
                }
            }
            .minimumScaleFactor(0.85)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: rowWidth)
            .accessibilityHidden(true)
        }
    }

    /// One paragraph, so a long pipeline name wraps with its hint.
    private func line(_ title: String, _ hint: String) -> Text {
        let text = Text(title).foregroundStyle(PopoverInk.secondary.color)
        guard !hint.isEmpty else { return text.font(OptionsType.label) }
        return (text + Text(verbatim: " · ").foregroundStyle(PopoverInk.secondary.color) + Text(hint).foregroundStyle(hintInk)).font(OptionsType.label)
    }

    /// The tiles' row: the plain target and the zones.
    private var rowWidth: CGFloat {
        DropTiles.plainWidth + CGFloat(state.zones.count) * (DropTiles.zoneWidth + DropTiles.gap)
    }

    /// ⌥ says what it keeps in the primary ink; ⌘'s aggressive settings in the warm colour.
    private var hintInk: Color {
        if state.keepOriginals { return PopoverInk.primary.color }
        return state.harder ? PopoverInk.warm.color : PopoverInk.secondary.color
    }
}

/// One target: a symbol in a flat circle over a name of two lines at most, on a raised cream tile
/// that turns charcoal while the drag is over it.
enum DropTiles {
    static let plainWidth: CGFloat = 124
    static let zoneWidth: CGFloat = 100
    static let height: CGFloat = 104
    static let gap: CGFloat = 8
}

struct DropTile<Symbol: View, Label: View>: View {
    let hovered: Bool
    /// nil: as wide as the panel.
    let width: CGFloat?
    @ViewBuilder let symbol: Symbol
    @ViewBuilder let label: Label
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Symbols on one line across the row, whether a name takes one line or two.
        VStack(spacing: 6) {
            symbol
                .frame(width: 38, height: 38)
                // Inside a raised tile: flat, a tint of the tile.
                .background(Circle().fill(hovered ? Ink.onCharcoal.opacity(0.14) : Color.primary.opacity(0.06)))
            VStack(spacing: 1) { label }
                .font(OptionsType.bodyStrong)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .frame(minWidth: width ?? DropTiles.plainWidth, maxWidth: width ?? .infinity, minHeight: DropTiles.height, maxHeight: DropTiles.height, alignment: .top)
        .foregroundStyle(hovered ? AnyShapeStyle(Ink.onCharcoal) : AnyShapeStyle(PopoverInk.primary.color))
        .raised(RoundedRectangle(cornerRadius: OptionsType.radius, style: .continuous), fill: hovered ? Ink.charcoal : Surface.cream)
        .scaleEffect(hovered && !reduceMotion ? 1.03 : 1)
    }
}

private extension View {
    /// Writes this view's frame in the drop zone's space to the state, for the drop target's hit test.
    func reportFrame(_ id: String, to state: DropZoneState) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(DropZoneState.space)) } action: { frame in
            state.frames[id] = frame
        }
    }
}
