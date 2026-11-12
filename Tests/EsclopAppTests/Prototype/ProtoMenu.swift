// SPDX-License-Identifier: GPL-3.0-or-later
//
// Prototype of the menu bar panel and the glyph's states. The panel hangs under the glyph: what
// the app did today, the last results as pictures that drag out, four commands.

import AppKit
@testable import EsclopAppKit
import SwiftUI

struct ProtoMenuPanel: View {
    enum Mode { case normal, selected, paused, empty }
    var mode: Mode = .normal
    var catalan = false

    private let figures = [75, 54, 76, 62, 89, 75]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if mode == .empty {
                VStack(spacing: 8) {
                    if Proto.own { ProtoClog(width: 56) }
                    Text(catalan ? "Copia una captura de pantalla. Apareixerà aquí, més petita." : "Copy a screenshot. It lands here, smaller.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 96)
            } else {
                grid
                if mode == .selected { selection }
            }
            Divider().opacity(0.6)
            VStack(spacing: 0) {
                row(catalan ? "Optimitza fitxers…" : "Optimise Files…", keys: ["⌘", "O"])
                row(catalan ? "Optimitza el porta-retalls" : "Optimise Clipboard", keys: ["⌃", "⇧", "C"])
                row(catalan ? "Tots els resultats…" : "All Results…", keys: [])
                row(catalan ? "Fluxos…" : "Pipelines…", keys: [])
            }
            .padding(.horizontal, -6)
            if mode != .paused {
                Text(catalan ? "Vigila el porta-retalls i 2 carpetes" : "Watching the clipboard and 2 folders")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Proto.panelPadding)
        .frame(width: 3 * 92 + 2 * Proto.gap + 2 * Proto.panelPadding)
        .protoGlass(Proto.panelRadius)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                switch mode {
                case .normal, .selected:
                    Text("−38 MB").font(Proto.figure(24)).foregroundStyle(Proto.saving).monospacedDigit()
                    Text(catalan ? "avui, en 14 fitxers" : "today, across 14 files").font(.system(size: 11)).foregroundStyle(.secondary)
                case .paused:
                    Text(catalan ? "En pausa" : "Paused").font(.system(size: 24, weight: .semibold))
                    Text(catalan ? "Es reprèn a les 14:32" : "Resumes at 14:32").font(.system(size: 11)).foregroundStyle(.secondary)
                case .empty:
                    Text(catalan ? "A punt" : "Ready").font(.system(size: 24, weight: .semibold))
                    Text(catalan ? "Encara no s’ha optimitzat res" : "Nothing optimised yet").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if mode == .paused {
                Button(catalan ? "Reprèn" : "Resume") {}
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: Proto.hit)
                    .background(Capsule().fill(Color.primary.opacity(0.14)))
            } else {
                // A menu, so it says so: pause, with the chevron of a pull-down.
                HStack(spacing: 3) {
                    Image(systemName: "pause.fill").font(.system(size: 11, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(height: Proto.hit)
                .background(Capsule().fill(Color.primary.opacity(0.14)))
                .accessibilityLabel("Pause")
            }
            ProtoIconButton(symbol: "gearshape.fill", name: "Settings and more")
        }
        .frame(height: 44)
    }

    private var grid: some View {
        VStack(spacing: Proto.gap) {
            ForEach(0 ..< 2, id: \.self) { line in
                HStack(spacing: Proto.gap) {
                    ForEach(0 ..< 3, id: \.self) { column in
                        let index = line * 3 + column
                        VStack(spacing: 4) {
                            Image(nsImage: ProtoSamples.pictures[index])
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 92, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: Proto.innerRadius, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: Proto.innerRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                                .overlay {
                                    if mode == .selected, index == 1 {
                                        RoundedRectangle(cornerRadius: Proto.innerRadius + 2, style: .continuous)
                                            .strokeBorder(Proto.control, lineWidth: 2).padding(-3)
                                    }
                                }
                            Text(Proto.percent(figures[index]))
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// The picture that is selected, and what can be done with it, here.
    private var selection: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text(catalan ? "Platja 02.jpg" : "Beach 02.jpg").font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("2.4 MB → 1.1 MB").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 4)
            ProtoIconButton(symbol: "arrow.uturn.backward", name: "Undo")
            ProtoIconButton(symbol: "rectangle.split.2x1", name: "Compare")
            ProtoIconButton(symbol: "magnifyingglass", name: "Show in Finder")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: Proto.innerRadius, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func row(_ title: String, keys: [String]) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            if !keys.isEmpty { ProtoKeys(keys: keys) }
        }
        .padding(.horizontal, 6)
        .frame(height: Proto.hit)
        .contentShape(Rectangle())
    }
}

/// The pause choices, as the menu the pause button opens.
struct ProtoPauseMenu: View {
    var catalan = false
    var body: some View {
        let items = catalan
            ? ["Salta la pròxima còpia", "Durant 5 minuts", "Durant una hora", "Fins que ho reprengui"]
            : ["Skip the Next Copy", "For 5 Minutes", "For an Hour", "Until I Resume"]
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items, id: \.self) { title in
                Text(title).font(.system(size: 13)).padding(.horizontal, 10).frame(height: 26, alignment: .leading)
            }
        }
        .padding(.vertical, 5)
        .frame(width: 190, alignment: .leading)
        .protoGlass(12)
    }
}

/// The glyph in a strip of menu bar: idle, working (the clog takes a step), paused (hollow).
/// The shipped states are drawn as vectors; these stand in for them.
struct ProtoGlyphStrip: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 34) {
            state("Idle") { glyph(MenuBarLabel.customGlyph) }
            state("Working: heel") { glyph(MenuBarLabel.customGlyph).rotationEffect(.degrees(-6), anchor: .bottomLeading) }
            state("Working: toe") { glyph(MenuBarLabel.customGlyph).rotationEffect(.degrees(4), anchor: .bottomTrailing) }
            state("Paused") { glyph(ProtoGlyph.hollow) }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(scheme == .dark ? Color(white: 0.14) : Color(white: 0.93))
    }

    private func state(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 8) {
            content().frame(width: 34, height: 24)
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func glyph(_ image: NSImage?) -> some View {
        if let image {
            Image(nsImage: image).renderingMode(.template).foregroundStyle(.primary)
        }
    }
}

@MainActor
enum ProtoGlyph {
    /// The clog as an outline: the silhouette minus itself eroded.
    static let hollow: NSImage? = {
        guard let glyph = MenuBarLabel.customGlyph else { return nil }
        let scale: CGFloat = 8
        let size = NSSize(width: glyph.size.width * scale, height: glyph.size.height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        glyph.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let filled = CIImage(bitmapImageRep: rep) else { return nil }
        let eroded = filled.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 1.5 * scale])
        // Keep the silhouette where the eroded copy is not.
        let outline = filled.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: eroded])
        guard let cg = CIContext().createCGImage(outline, from: filled.extent) else { return nil }
        let image = NSImage(cgImage: cg, size: glyph.size)
        image.isTemplate = true
        return image
    }()
}
