// SPDX-License-Identifier: GPL-3.0-or-later
//
// Prototype of the menu bar panel and the glyph's states. The panel hangs under the glyph: what
// the app did today, the last results as pictures that drag out, four commands.

import AppKit
@testable import EsclopAppKit
import SwiftUI

struct ProtoMenuPanel: View {
    enum Mode { case normal, selected, batch, paused, pausedOpen, empty }
    var mode: Mode = .normal
    var catalan = false

    private let figures = [75, 54, 76, 62, 89, 75]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if mode == .empty {
                VStack(spacing: 8) {
                    ProtoClog(width: 72, wood: true).padding(.top, 6)
                    Text(catalan ? "Copia una captura. La trobaràs aquí, més petita." : "Copy a screenshot. You’ll find it here, smaller.")
                        .font(.system(size: 13))
                        .foregroundStyle(Proto.quiet)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 132)
            } else {
                grid
                // The newest result is selected when the panel opens, so the row is always
                // there: the commands never shift, and ⌘Z has a visible target.
                selection
            }
            Divider().opacity(0.6)
            VStack(spacing: 0) {
                row(catalan ? "Optimitza fitxers…" : "Optimise Files…", keys: ["⌘", "O"])
                row(catalan ? "Optimitza el porta-retalls" : "Optimise Clipboard", keys: ["⌃", "⇧", "C"])
                row(catalan ? "Tots els resultats" : "All Results", keys: [])
                row(catalan ? "Fluxos" : "Pipelines", keys: [])
            }
            .padding(.horizontal, -6)
            // One line, always: what the app is watching, or the batch that is running.
            HStack(spacing: 6) {
                if mode == .batch { ProgressView().controlSize(.mini) }
                Text(status).font(.system(size: 11)).foregroundStyle(Proto.quiet)
                Spacer()
                if mode == .batch { Text(catalan ? "Mostra" : "Show").font(.system(size: 11, weight: .medium)) }
            }
            .frame(height: 14)
        }
        .padding(Proto.panelPadding)
        .frame(width: 3 * 92 + 2 * Proto.gap + 2 * Proto.panelPadding)
        .protoGlass(Proto.panelRadius)
    }

    /// The last seven days' savings, today's in green: the figure has a history.
    private var week: some View {
        let days: [CGFloat] = [0.35, 0.6, 0.2, 0.85, 0.5, 0.3, 1]
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, value in
                Capsule().fill(index == 6 ? Proto.saving : Proto.quiet.opacity(0.45)).frame(width: 4, height: 6 + 20 * value)
            }
        }
        .frame(height: 28, alignment: .bottom)
        .padding(.trailing, 8)
        .accessibilityLabel("The last seven days")
    }

    private var status: String {
        switch mode {
        case .batch: return catalan ? "S’està optimitzant: 7 de 9" : "Optimising 7 of 9"
        case .paused, .pausedOpen: return catalan ? "No vigila res" : "Watching nothing"
        default: return catalan ? "Vigila el porta-retalls i 2 carpetes" : "Watching the clipboard and 2 folders"
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                switch mode {
                case .normal, .selected, .batch:
                    ProtoFigure(text: "−38 MB", size: 32)
                    Text(mode == .normal ? (catalan ? "avui, el millor de la setmana" : "today, the week’s best") : (catalan ? "avui, en 14 fitxers" : "today, across 14 files")).font(.system(size: 11)).foregroundStyle(Proto.quiet)
                case .paused, .pausedOpen:
                    Text(catalan ? "En pausa" : "Paused").font(.system(size: 24, weight: .semibold))
                    Text(mode == .pausedOpen
                        ? (catalan ? "Fins que ho diguis" : "Until you resume")
                        : (catalan ? "Es reprèn a les 14:32" : "Resumes at 14:32")).font(.system(size: 11)).foregroundStyle(Proto.quiet)
                case .empty:
                    Text(catalan ? "A punt" : "Ready").font(.system(size: 24, weight: .semibold))
                }
            }
            .fixedSize()
            Spacer(minLength: 4)
            if mode == .normal || mode == .selected || mode == .batch { week }
            if mode == .paused || mode == .pausedOpen {
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
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Proto.quiet)
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
                                    if index == (mode == .selected ? 1 : 0) {
                                        RoundedRectangle(cornerRadius: Proto.innerRadius + 2, style: .continuous)
                                            .strokeBorder(Proto.control, lineWidth: 2).padding(-3)
                                    }
                                }
                            Text(Proto.percent(figures[index]))
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(Proto.quiet)
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
                Text(mode == .selected ? (catalan ? "Platja 02.jpg" : "Beach 02.jpg") : (catalan ? "Captura 10.42.png" : "Screenshot 10.42.png")).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(mode == .selected ? (catalan ? "2,4 MB → 1,1 MB" : "2.4 MB → 1.1 MB") : (catalan ? "2,4 MB → 612 kB" : "2.4 MB → 612 kB")).font(.system(size: 11)).foregroundStyle(Proto.quiet).monospacedDigit()
            }
            Spacer(minLength: 4)
            ProtoIconButton(symbol: "arrow.uturn.backward", name: "Undo")
            ProtoIconButton(symbol: "rectangle.split.2x1", name: "Compare")
            ProtoIconButton(symbol: "folder", name: "Show in Finder")
            ProtoIconButton(symbol: "ellipsis", name: "Options")
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
            ? ["Per a la pròxima còpia", "Durant 5 minuts", "Durant una hora", "Fins que jo ho digui"]
            : ["For the Next Copy", "For 5 Minutes", "For an Hour", "Until I Resume"]
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items, id: \.self) { title in
                Text(title).font(.system(size: 13)).padding(.horizontal, 10).frame(height: 26, alignment: .leading)
            }
        }
        .padding(.vertical, 5)
        .frame(width: 190, alignment: .leading)
        .protoGlass(14)
    }
}

/// The glyph in a strip of menu bar: idle, working (the clog takes a step), paused (hollow).
/// The shipped states are drawn as vectors; these stand in for them.
struct ProtoGlyphStrip: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 34) {
            state("Idle") { glyph(MenuBarLabel.customGlyph) }
            state("Working: heel") { glyph(MenuBarLabel.customGlyph).rotationEffect(.degrees(-15), anchor: .bottomLeading).overlay(alignment: .bottom) { Capsule().fill(.primary).frame(width: 26, height: 1).offset(y: 3) } }
            state("Working: toe") { glyph(MenuBarLabel.customGlyph).rotationEffect(.degrees(8), anchor: .bottomTrailing).overlay(alignment: .bottom) { Capsule().fill(.primary).frame(width: 26, height: 1).offset(y: 3) } }
            state("Paused") { glyph(ProtoGlyph.hollow) }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(scheme == .dark ? Color(white: 0.14) : Color(white: 0.93))
    }

    private func state(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 8) {
            content().frame(width: 34, height: 24)
            Text(title).font(.system(size: 11)).foregroundStyle(Proto.quiet)
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
