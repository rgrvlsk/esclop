// SPDX-License-Identifier: GPL-3.0-or-later
//
// The drop zone at the results corner: "Drop to optimise" (with Command, "Drop to optimise
// harder" in the warm colour), and beside it up to four preset zones in a 2 × 2 grid, facing the
// screen. Text and icons use the popover's explicit inks on its near-opaque surface, so they keep
// their contrast whatever is behind the glass.

import SwiftUI

public struct DropZoneView: View {
    let state: DropZoneState

    public init(state: DropZoneState) {
        self.state = state
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if state.zonesLeading { zoneGrid }
            plainTarget
            if !state.zonesLeading { zoneGrid }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .background(PopoverInk.surface.color, in: RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
        .panelSurface()
        .animation(Motion.hover, value: state.hovering)
        .animation(Motion.hover, value: state.harder)
        .animation(Motion.hover, value: state.hoveredZone)
    }

    private var tint: Color { state.harder ? PopoverInk.warm.color : PopoverInk.accent.color }

    private var plainTarget: some View {
        let inner = RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
        return HStack(spacing: 12) {
            Image(systemName: state.harder ? "arrow.down.to.line.compact" : "arrow.down.to.line")
                .font(.title2.weight(.medium))
                .foregroundStyle(tint)
                .frame(width: Metrics.dropZoneIcon, height: Metrics.dropZoneIcon)
                .background(tint.opacity(state.hovering ? 0.18 : 0.1), in: inner)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .font(.headline)
                    .foregroundStyle(PopoverInk.primary.color)
                Text(state.detail)
                    .font(.caption)
                    .foregroundStyle(PopoverInk.secondary.color)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: Metrics.dropZoneWidth - 16, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background {
            inner
                .strokeBorder(tint.opacity(state.hovering ? 0.9 : 0.45), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .background(inner.fill(tint.opacity(state.hovering ? 0.08 : 0)))
        }
        .reportFrame(DropZoneState.plainTarget, to: state)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(state.title), \(state.detail)")
    }

    @ViewBuilder
    private var zoneGrid: some View {
        if !state.zones.isEmpty {
            let rows = stride(from: 0, to: state.zones.count, by: 2).map { Array(state.zones[$0 ..< min($0 + 2, state.zones.count)]) }
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(rows, id: \.first?.name) { row in
                    GridRow {
                        ForEach(row) { zone in PresetZoneCell(zone: zone, hovered: state.hoveredZone == zone.name, state: state) }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Strings.text("Preset zones"))
        }
    }
}

/// One preset zone: the pipeline's symbol and name in a dashed square that fills when a drag is
/// over it.
struct PresetZoneCell: View {
    let zone: PresetZone
    let hovered: Bool
    let state: DropZoneState

    static let size = CGSize(width: 92, height: 64)

    var body: some View {
        let inner = RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
        let accent = PopoverInk.accent.color
        VStack(spacing: 4) {
            Image(systemName: zone.icon)
                .font(.title3.weight(.medium))
                .foregroundStyle(hovered ? accent : PopoverInk.icon.color)
                .frame(height: 22)
            Text(zone.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(PopoverInk.primary.color)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 6)
        .frame(width: Self.size.width, height: Self.size.height)
        .background {
            inner
                .strokeBorder(accent.opacity(hovered ? 0.9 : 0.35), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .background(inner.fill(hovered ? PopoverInk.selectedFill.color : .clear))
        }
        .scaleEffect(hovered ? 1.03 : 1)
        .reportFrame(zone.name, to: state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Strings.format("Preset zone: %@", zone.name))
        .accessibilityHint(Strings.text("Drop files here to run this pipeline on them."))
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
