// SPDX-License-Identifier: GPL-3.0-or-later
//
// Prototype of the options popover and the drop zone. The popover opens on the controls, never on
// a fold, for every kind of file; the drop zone is a row of tiles, no dashes.

import AppKit
@testable import EsclopAppKit
import SwiftUI

/// A segmented control that fills its row.
struct ProtoSegments: View {
    let items: [String]
    var selected = 0
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Text(item)
                    .font(.system(size: 12, weight: index == selected ? .semibold : .regular))
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .background { if index == selected { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.16)) } }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Proto.innerRadius, style: .continuous).fill(Color.primary.opacity(0.07)))
    }
}

struct ProtoOptions: View {
    enum Tab { case format, size, actions }
    enum Kind { case image, video, pdf, audio }
    var tab: Tab = .format
    var kind: Kind = .image
    var suggestion = true
    var catalan = false
    /// A change is running: the selection has moved, the figure waits, Stop is at hand.
    var pending = false

    @State private var quality = 70.0
    @State private var scale = 50.0
    @State private var on = true
    @State private var off = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if suggestion, tab == .format, kind == .image { suggestionRow }
            ProtoSegments(
                items: catalan ? ["Format", "Mida", "Accions"] : ["Format", "Size", "Actions"],
                selected: tab == .format ? 0 : (tab == .size ? 1 : 2)
            )
            switch tab {
            case .format:
                switch kind {
                case .image: imageFormat
                case .video: videoFormat
                case .pdf: pdfFormat
                case .audio: audioFormat
                }
            case .size: size
            case .actions: actions
            }
        }
        .padding(Proto.panelPadding)
        .frame(width: 340)
        .protoGlass(Proto.panelRadius)
    }

    private var sample: (name: String, change: String, saving: Int, picture: NSImage) {
        switch kind {
        case .image: return (catalan ? "Captura 2026-11-05 a les 10.42" : "Screenshot 2026-11-05 at 10.42", catalan ? "2,4 MB → 612 kB" : "2.4 MB → 612 kB", 75, ProtoSamples.screenshot)
        case .video: return ("Screen Recording 2026-11-05", "84 MB → 19 MB", 77, ProtoSamples.chart)
        case .pdf: return ("Dossier.pdf", "13 MB → 3.1 MB", 76, ProtoSamples.page)
        case .audio: return ("Interview.m4a", "18 MB → 6.2 MB", 66, ProtoSamples.poster)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: sample.picture)
                .resizable().aspectRatio(contentMode: .fill)
                .frame(width: 60, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: Proto.innerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Proto.innerRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(sample.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(sample.change).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 4)
            if pending {
                Button {} label: { Label("Stop", systemImage: "stop.fill").labelStyle(.iconOnly).font(.system(size: 11, weight: .semibold)).frame(width: Proto.hit, height: Proto.hit) }
                    .buttonStyle(.plain)
                    .background(Circle().fill(Color.primary.opacity(0.14)))
            } else {
                Text(Proto.percent(sample.saving)).font(Proto.figure(24)).foregroundStyle(Proto.saving).monospacedDigit()
            }
        }
        .overlay(alignment: .bottom) {
            if pending {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.14))
                        Capsule().fill(Color.primary.opacity(0.6)).frame(width: proxy.size.width * 0.4)
                    }
                }
                .frame(height: 2)
                .offset(y: 7)
            }
        }
    }

    /// One sentence and one button that says what it does. It is gone once used.
    private var suggestionRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(catalan ? "En WebP ocuparia 410 kB" : "As WebP it would be 410 kB").font(.system(size: 12, weight: .medium))
                Text(catalan ? "Sol anar bé per a les captures" : "Usually right for screenshots").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(catalan ? "Converteix a WebP" : "Convert to WebP") {}.controlSize(.small).buttonStyle(.borderedProminent)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: Proto.innerRadius, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func tiles(_ items: [(String, String)], more: Bool = true) -> some View {
        let chosen = pending ? 1 : 0
        return HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                VStack(spacing: 1) {
                    Text(item.0).font(.system(size: 12, weight: .semibold))
                    Text(item.1).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: Proto.innerRadius, style: .continuous).fill(Color.primary.opacity(index == chosen ? 0.14 : 0.06)))
                .overlay {
                    if index == chosen { RoundedRectangle(cornerRadius: Proto.innerRadius, style: .continuous).strokeBorder(Proto.control, lineWidth: 1.5) }
                }
            }
            if more {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 44)
                    .background(RoundedRectangle(cornerRadius: Proto.innerRadius, style: .continuous).fill(Color.primary.opacity(0.06)))
                    .accessibilityLabel("More formats")
            }
        }
    }

    private func line(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            Text(value).font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
        }
    }

    private func toggle(_ title: String, _ value: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            Toggle("", isOn: value).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }

    private func rule(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().opacity(0.6)
            Toggle(title, isOn: $off).font(.system(size: 13))
        }
    }

    private var compression: some View {
        ProtoSegments(items: catalan ? ["Adaptativa", "Sense pèrdua", "A fons"] : ["Adaptive", "Lossless", "Aggressive"])
    }

    private var imageFormat: some View {
        VStack(alignment: .leading, spacing: 12) {
            tiles([("PNG", "612 kB"), ("JPEG", "320 kB"), ("WebP", "410 kB"), ("AVIF", "285 kB")])
            compression
            VStack(spacing: 2) {
                HStack {
                    Text(catalan ? "Qualitat" : "Quality").font(.system(size: 13))
                    Spacer()
                    Text("70").font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: $quality, in: 1 ... 100)
            }
            toggle(catalan ? "Treu les metadades" : "Remove metadata", $on)
            rule(catalan ? "Fes-ho sempre amb les captures" : "Always do this for screenshots")
        }
    }

    private var videoFormat: some View {
        VStack(alignment: .leading, spacing: 12) {
            tiles([("HEVC", "19 MB"), ("H.264", "27 MB"), ("GIF", "41 MB")])
            compression
            line("Frame rate", "30 fps")
            line("Speed", "1×")
            toggle("Remove audio", $off)
            rule("Always do this for screen recordings")
        }
    }

    private var pdfFormat: some View {
        VStack(alignment: .leading, spacing: 12) {
            tiles([("Screen", "1.2 MB"), ("Reading", "3.1 MB"), ("Print", "6.4 MB")])
            Text("Reading keeps pictures at 150 dpi.").font(.system(size: 11)).foregroundStyle(.secondary)
            toggle("Keep text selectable", $on)
            toggle("Remove metadata", $on)
            rule("Always do this for exported PDFs")
        }
    }

    private var audioFormat: some View {
        VStack(alignment: .leading, spacing: 12) {
            tiles([("AAC", "6.2 MB"), ("MP3", "7.4 MB"), ("Opus", "4.9 MB")])
            chips("Bitrate", ["64", "96", "128", "160", "192", "256"], selected: 3)
            line("Speed", "1×")
            toggle("Even out loudness", $off)
            rule("Always do this for voice memos")
        }
    }

    private var size: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 2) {
                HStack {
                    Text(catalan ? "Escala" : "Scale").font(.system(size: 13))
                    Spacer()
                    Text("50\u{202F}% · 1470 × 956 · 180 kB").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: $scale, in: 10 ... 100, step: 10)
            }
            chips(catalan ? "Com a màxim" : "Fit under", ["500 kB", "1 MB", "2 MB", "5 MB", catalan ? "Altres…" : "Other…"], selected: nil)
            chips(catalan ? "Retalla" : "Crop", ["1:1", "4:3", "16:9", "9:16", catalan ? "Lliure…" : "Free…"], selected: 2)
        }
    }

    private func chips(_ title: String, _ items: [String], selected: Int?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13))
            HStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    Text(item)
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                        .frame(height: Proto.hit)
                        .background(Capsule().fill(Color.primary.opacity(index == selected ? 0.14 : 0.06)))
                        .overlay { if index == selected { Capsule().strokeBorder(Proto.control, lineWidth: 1.5) } }
                }
            }
        }
    }

    /// A list, like a menu: a label never wraps or breaks, in either language.
    private var actions: some View {
        VStack(spacing: 0) {
            actionRow("square.on.square", catalan ? "Copia" : "Copy", ["⌘", "C"])
            actionRow("square.and.arrow.down", catalan ? "Anomena i desa…" : "Save As…", ["⌘", "S"])
            actionRow("folder", catalan ? "Mostra al Finder" : "Show in Finder", ["⌘", "R"])
            actionRow("eye", catalan ? "Vista ràpida" : "Quick Look", [catalan ? "Espai" : "Space"])
            actionRow("rectangle.split.2x1", catalan ? "Compara amb l’original" : "Compare with the Original", [])
            Divider().opacity(0.6).padding(.vertical, 4).padding(.horizontal, 6)
            actionRow("square.and.arrow.up", catalan ? "Comparteix…" : "Share…", [])
            actionRow("arrow.up.forward.app", catalan ? "Obre amb" : "Open With", [], chevron: true)
            actionRow("square.stack.3d.up", catalan ? "Executa una drecera" : "Run a Shortcut", [], chevron: true)
            actionRow("point.3.connected.trianglepath.dotted", catalan ? "Aplica un flux" : "Run a Pipeline", [], chevron: true)
            actionRow("icloud.and.arrow.up", catalan ? "Puja a R2" : "Upload to R2", [])
        }
        .padding(.horizontal, -6)
    }

    private func actionRow(_ symbol: String, _ title: String, _ keys: [String], chevron: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 20)
            Text(title).font(.system(size: 13))
            Spacer()
            if !keys.isEmpty { ProtoKeys(keys: keys) }
            if chevron { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 6)
        .frame(height: Proto.hit)
    }
}

/// The drop zone: tiles in a row, each a fixed size. The one under the drag takes the colour and
/// grows from its centre; the gaps between tiles belong to the nearest tile.
struct ProtoDropZone: View {
    enum Mode { case idle, target, preset, aggressive }
    var mode: Mode = .idle
    var presets = true
    var catalan = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if presets {
                tile("photo", catalan ? "A WebP" : "To WebP", hot: mode == .preset)
                tile("arrow.down.right.and.arrow.up.left", catalan ? "Menys d’1 MB" : "Under 1 MB", hot: false)
                tile("camera.viewfinder", catalan ? "Captures del blog" : "Blog screenshots", hot: false)
            }
            main
        }
    }

    private var main: some View {
        let hot = mode == .target || mode == .aggressive
        let tint: Color? = mode == .aggressive ? Proto.litWarm : (mode == .target ? Proto.lit : nil)
        return HStack(spacing: 10) {
            ProtoClog(width: 34, template: hot)
            VStack(alignment: .leading, spacing: 1) {
                Text(mode == .aggressive
                    ? (catalan ? "Optimitza a fons" : "Optimise Aggressively")
                    : (catalan ? "Optimitza" : "Optimise"))
                    .font(.system(size: 13, weight: .semibold))
                Text(catalan ? "3 fitxers" : "3 files").font(.system(size: 11)).opacity(hot ? 1 : 0.62)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: Proto.cardWidth, height: 92, alignment: .leading)
        .foregroundStyle(hot ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .protoGlass(Proto.tileRadius, tint: tint)
        .scaleEffect(hot ? 1.04 : 1)
        .opacity(mode == .preset ? 0.6 : 1)
    }

    private func tile(_ symbol: String, _ title: String, hot: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20, weight: .regular)).frame(height: 24)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.top, 18)
        .frame(width: 92, height: 92, alignment: .top)
        .foregroundStyle(hot ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .protoGlass(Proto.tileRadius, tint: hot ? Proto.lit : nil)
        .scaleEffect(hot ? 1.04 : 1)
        .opacity(mode == .target || mode == .aggressive ? 0.6 : 1)
    }
}
