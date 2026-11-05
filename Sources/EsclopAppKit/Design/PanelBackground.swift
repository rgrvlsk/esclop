// SPDX-License-Identifier: GPL-3.0-or-later
//
// Floating panels sit on the system HUD material with a 1 pt hairline and one shadow (DESIGN.md).
// ImageRenderer cannot draw AppKit views, so renders swap the material for a flat fill of the
// same tone through `PanelBackdrop.flat`.

import AppKit
import SwiftUI

public enum PanelBackdrop: Sendable {
    /// NSVisualEffectView with the `.hudWindow` material, blending behind the window.
    case material
    /// A flat stand-in for still renders.
    case flat
}

extension EnvironmentValues {
    @Entry public var panelBackdrop: PanelBackdrop = .material
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct PanelSurface: ViewModifier {
    @Environment(\.panelBackdrop) private var backdrop
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
        content
            .background {
                switch backdrop {
                case .material: VisualEffectBackground().clipShape(shape)
                case .flat: shape.fill(colorScheme == .dark ? Color(white: 0.17) : Color(white: 0.96))
                }
            }
            .overlay { shape.strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.1), lineWidth: 1) }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.16), radius: 10, y: 4)
    }
}

extension View {
    func panelSurface() -> some View { modifier(PanelSurface()) }
}
