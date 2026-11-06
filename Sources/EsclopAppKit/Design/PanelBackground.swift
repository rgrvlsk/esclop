// SPDX-License-Identifier: GPL-3.0-or-later
//
// The floating surfaces' material (DESIGN.md › Layout, Color, Motion):
// - macOS 26 and later, built with Xcode 26 or later (Swift 6.2): Liquid Glass (`glassEffect`), inside a `GlassEffectContainer` so shapes
//   with a shared glass ID morph into each other;
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
    /// The namespace glass IDs live in, set by the floating stack's glass container.
    @Entry var glassNamespace: Namespace.ID?
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

/// Glass in a shape. `id` ties it to the same glass in another state, so the system morphs one
/// into the other (thumbnail into detail, activity capsule out of the thumbnail).
struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var id: String?
    /// A border colour that replaces the hairline (the error state's red rim).
    var rim: Color?
    var interactive = false

    @Environment(\.panelBackdrop) private var backdrop
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.glassNamespace) private var namespace

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
    @ViewBuilder private func glass(_ content: Content) -> some View {
        let glass = interactive ? Glass.regular.interactive() : Glass.regular
        // The rim is part of the glass's content: a glass container draws its glass over anything
        // laid outside it.
        let surface = content
            .overlay { if let rim { shape.strokeBorder(rim, lineWidth: 1.5).allowsHitTesting(false) } }
            .glassEffect(glass, in: shape)
        if let id, let namespace {
            surface.glassEffectID(id, in: namespace)
        } else {
            surface
        }
    }
    #endif
}

extension View {
    func glassSurface(_ shape: some InsettableShape, id: String? = nil, rim: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, id: id, rim: rim, interactive: interactive))
    }

    /// The drop zone's surface: one rounded glass shape.
    func panelSurface() -> some View {
        glassSurface(RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
    }
}

/// Wraps glass siblings so they blend and morph on macOS 26; a plain container before.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content
    @Namespace private var namespace

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
                .environment(\.glassNamespace, namespace)
        } else {
            content
        }
        #else
        content
        #endif
    }
}
