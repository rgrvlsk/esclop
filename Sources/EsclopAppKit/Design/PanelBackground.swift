// SPDX-License-Identifier: GPL-3.0-or-later
//
// The drop zone's glass material until it moves to the cream surface (FloatingSurface):
// - macOS 26 and later, built with Xcode 26 or later (Swift 6.2): Liquid Glass (`glassEffect`);
// - macOS 14–25: the `.hudWindow` visual effect material with a 1 pt hairline;
// - Reduce Transparency: an opaque system background with a contrasting border;
// - still renders (`PanelBackdrop.flat`): ImageRenderer draws neither, so a translucent fill of the
//   same tone stands in.

import AppKit
import SwiftUI

public enum PanelBackdrop: Sendable {
    /// The live material: Liquid Glass, or the HUD material before macOS 26.
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

/// Glass in a shape: the drop zone's surface until it moves to the cream material.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    /// A border colour that replaces the hairline (the error state's red rim).
    var rim: Color?
    var interactive = false

    @Environment(\.panelBackdrop) private var backdrop
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(shape.strokeBorder(rim ?? Color.primary.opacity(0.45), lineWidth: rim == nil ? 1 : 1.5))
        } else if backdrop == .flat {
            content
                .background(shape.fill(colorScheme == .dark ? Color(white: 0.2).opacity(0.78) : Color(white: 0.97).opacity(0.82)))
                .overlay(shape.strokeBorder(rim ?? Color.white.opacity(colorScheme == .dark ? 0.28 : 0.7), lineWidth: rim == nil ? 1 : 1.5))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.18), radius: 12, y: 5)
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26, *) { glass(content) } else { hud(content) }
            #else
            hud(content)
            #endif
        }
    }

    /// Before macOS 26, or built with an SDK that has no Liquid Glass (Xcode 16 and earlier).
    private func hud(_ content: Content) -> some View {
        content
            .background(VisualEffectBackground().clipShape(shape))
            .overlay(shape.strokeBorder(rim ?? Color.primary.opacity(colorScheme == .dark ? 0.2 : 0.12), lineWidth: rim == nil ? 1 : 1.5))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.16), radius: 10, y: 4)
    }

    #if compiler(>=6.2)
    @available(macOS 26, *)
    private func glass(_ content: Content) -> some View {
        let glass = interactive ? Glass.regular.interactive() : Glass.regular
        return content
            .overlay { if let rim { shape.strokeBorder(rim, lineWidth: 1.5).allowsHitTesting(false) } }
            .glassEffect(glass, in: shape)
    }
    #endif
}

extension View {
    func glassSurface(_ shape: some InsettableShape, rim: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, rim: rim, interactive: interactive))
    }

    /// The drop zone's surface: one rounded glass shape.
    func panelSurface() -> some View {
        glassSurface(RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
    }
}
