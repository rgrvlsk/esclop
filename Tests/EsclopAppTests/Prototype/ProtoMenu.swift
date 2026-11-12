// SPDX-License-Identifier: GPL-3.0-or-later
//
// Prototype of the menu bar panel and the glyph's states. The panel is glass under the glyph:
// what the app did today, the last results as pictures that drag out, three commands.

import AppKit
@testable import EsclopAppKit
import SwiftUI

struct ProtoMenuPanel: View {
    enum Mode { case normal, paused, empty }
    var mode: Mode = .normal
    var catalan = false

    private let figures = ["−75 %", "−54 %", "−76 %", "−62 %", "−89 %", "−75 %"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if mode == .empty {
                Text(catalan ? "Copia una captura de pantalla. Apareixerà aquí, més petita." : "Copy a screenshot. It lands here, smaller.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .multilineTextAlignment(.center)
            } else {
                grid
            }
            Divider().opacity(0.6)
            VStack(spacing: 0) {
                row(catalan ? "Optimitza fitxers…" : "Optimise Files…", keys: ["⌘", "O"])
                row(catalan ? "Optimitza el porta-retalls" : "Optimise Clipboard", keys: ["⌃", "⇧", "C"])
                row(catalan ? "Fluxos…" : "Pipelines…", keys: [])
            }
            .padding(.horizontal, -6)
            Text(mode == .paused
                ? (catalan ? "No mira res fins a les 14:32" : "Watching nothing until 14:32")
                : (catalan ? "Mira el porta-retalls i 2 carpetes" : "Watching the clipboard and 2 folders"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 320)
        .protoGlass(Proto.panelRadius)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                switch mode {
                case .normal:
                    Text("−38 MB").font(Proto.figure(24)).foregroundStyle(Proto.saving).monospacedDigit()
                    Text(catalan ? "avui, en 14 fitxers" : "today, across 14 files").font(.system(size: 11)).foregroundStyle(.secondary)
                case .paused:
                    Text(catalan ? "En pausa" : "Paused").font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text(catalan ? "Torna a les 14:32" : "Back at 14:32").font(.system(size: 11)).foregroundStyle(.secondary)
                case .empty:
                    Text(catalan ? "A punt" : "Ready").font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text(catalan ? "Encara no s’ha optimitzat res" : "Nothing optimised yet").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if mode == .paused {
                Button(catalan ? "Reprèn" : "Resume") {}
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: Proto.hit)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
            } else {
                ProtoIconButton(symbol: "pause.fill", name: "Pause")
            }
            ProtoIconButton(symbol: "gearshape.fill", name: "Settings and more")
        }
        .frame(height: 46)
    }

    private var grid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Array(ProtoSamples.pictures.enumerated()), id: \.offset) { index, picture in
                VStack(spacing: 4) {
                    Image(nsImage: picture)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 64)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    Text(figures[index])
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(mode == .paused ? .secondary : .primary)
                }
            }
        }
    }

    private func row(_ title: String, keys: [String]) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            if !keys.isEmpty { ProtoKeys(keys: keys) }
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .contentShape(Rectangle())
    }
}

/// The pause choices, as the menu the pause button opens.
struct ProtoPauseMenu: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(["Skip the next copy", "For 5 minutes", "For an hour", "Until I resume"], id: \.self) { title in
                Text(title).font(.system(size: 13)).padding(.horizontal, 10).frame(height: 26, alignment: .leading)
            }
        }
        .padding(.vertical, 5)
        .frame(width: 180, alignment: .leading)
        .protoGlass(12)
    }
}

/// The glyph in a strip of menu bar: idle, working (the clog takes a step), paused (hollow).
struct ProtoGlyphStrip: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 34) {
            state("Idle") { glyph(MenuBarLabel.customGlyph) }
            state("Working, frame 1") { glyph(MenuBarLabel.customGlyph).rotationEffect(.degrees(-9), anchor: .bottomLeading) }
            state("Working, frame 2") { glyph(MenuBarLabel.customGlyph).rotationEffect(.degrees(5), anchor: .bottomTrailing).offset(x: 1.5) }
            state("Paused") { glyph(ProtoGlyph.hollow) }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(scheme == .dark ? Color(white: 0.14) : Color(white: 0.93))
    }

    private func state(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 8) {
            content().frame(width: 34, height: 24)
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
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
        let scale: CGFloat = 4
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
        let eroded = filled.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 1.35 * scale])
        // Keep the silhouette where the eroded copy is not.
        let outline = filled.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: eroded])
        guard let cg = CIContext().createCGImage(outline, from: filled.extent) else { return nil }
        let image = NSImage(cgImage: cg, size: glyph.size)
        image.isTemplate = true
        return image
    }()
}
