// SPDX-License-Identifier: GPL-3.0-or-later
//
// A single rounded rectangle at the results corner: "Drop to optimise", and with Command held,
// "Drop to optimise harder" in the warm colour.

import SwiftUI

public struct DropZoneView: View {
    let state: DropZoneState

    public init(state: DropZoneState) {
        self.state = state
    }

    public var body: some View {
        let tint = state.harder ? Palette.warm : Palette.accent
        let inner = RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
        HStack(spacing: 12) {
            Image(systemName: state.harder ? "arrow.down.to.line.compact" : "arrow.down.to.line")
                .font(.title2.weight(.medium))
                .foregroundStyle(tint)
                .frame(width: Metrics.dropZoneIcon, height: Metrics.dropZoneIcon)
                .background(tint.opacity(state.hovering ? 0.18 : 0.1), in: inner)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .font(.headline)
                Text(state.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background {
            inner
                .strokeBorder(tint.opacity(state.hovering ? 0.9 : 0.45), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .background(inner.fill(tint.opacity(state.hovering ? 0.08 : 0)))
        }
        .padding(8)
        .frame(width: Metrics.dropZoneWidth)
        .panelSurface()
        .animation(Motion.hover, value: state.hovering)
        .animation(Motion.hover, value: state.harder)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(state.title), \(state.detail)")
    }
}
