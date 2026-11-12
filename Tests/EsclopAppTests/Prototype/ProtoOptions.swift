// SPDX-License-Identifier: GPL-3.0-or-later
//
// Prototype of the options popover and the drop zone. The popover opens on the controls, never on
// a fold; the drop zone is a shelf of glass targets, no dashes.

import AppKit
@testable import EsclopAppKit
import SwiftUI

struct ProtoOptions: View {
    enum Tab: String, CaseIterable { case format = "Format", size = "Size", share = "Share" }
    var tab: Tab = .format
    var suggestion = true
    var catalan = false

    @State private var quality = 70.0
    @State private var scale = 50.0
    @State private var strip = true
    @State private var always = false
    @State private var compression = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if suggestion, tab == .format { suggestionRow }
            Picker("", selection: .constant(tab)) {
                ForEach(Tab.allCases, id: \.self) { Text(title($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch tab {
            case .format: format
            case .size: size
            case .share: share
            }
        }
        .padding(14)
        .frame(width: 340)
        .protoGlass(Proto.panelRadius)
    }

    private func title(_ tab: Tab) -> String {
        guard catalan else { return tab.rawValue }
        switch tab {
        case .format: return "Format"
        case .size: return "Mida"
        case .share: return "Envia"
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: ProtoSamples.screenshot)
                .resizable().aspectRatio(contentMode: .fill)
                .frame(width: 60, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(catalan ? "Captura 2026-11-05 a les 10.42" : "Screenshot 2026-11-05 at 10.42")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text("2.4 MB → 612 kB").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 4)
            Text("−75 %").font(Proto.figure(20)).foregroundStyle(Proto.saving).monospacedDigit()
        }
    }

    /// One sentence and one button. It is gone once used.
    private var suggestionRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(catalan ? "En WebP faria 410 kB" : "As WebP it would be 410 kB").font(.system(size: 12, weight: .medium))
                Text(catalan ? "Sol anar bé per a captures" : "Usually right for screenshots").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(catalan ? "Fes-ho" : "Use WebP") {}.controlSize(.small).buttonStyle(.borderedProminent)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private var format: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(Array([("PNG", "612 kB"), ("JPEG", "320 kB"), ("WebP", "410 kB"), ("AVIF", "285 kB")].enumerated()), id: \.offset) { index, item in
                    VStack(spacing: 1) {
                        Text(item.0).font(.system(size: 12, weight: .semibold))
                        Text(item.1).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(index == 0 ? 0.12 : 0.05)))
                    .overlay {
                        if index == 0 { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 1.5) }
                    }
                }
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 44)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
                    .accessibilityLabel("More formats")
            }
            Picker("", selection: $compression) {
                Text(catalan ? "Adaptativa" : "Adaptive").tag(0)
                Text(catalan ? "Sense pèrdua" : "Lossless").tag(1)
                Text(catalan ? "A fons" : "Aggressive").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            VStack(spacing: 2) {
                HStack {
                    Text(catalan ? "Qualitat" : "Quality").font(.system(size: 13))
                    Spacer()
                    Text("70").font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: $quality, in: 1 ... 100)
            }
            HStack {
                Text(catalan ? "Treu les metadades" : "Remove metadata").font(.system(size: 13))
                Spacer()
                Toggle("", isOn: $strip).toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            Divider().opacity(0.6)
            Toggle(catalan ? "Fes-ho sempre amb les captures" : "Always do this for screenshots", isOn: $always).font(.system(size: 13))
        }
    }

    private var size: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 2) {
                HStack {
                    Text(catalan ? "Escala" : "Scale").font(.system(size: 13))
                    Spacer()
                    Text("50 % · 1470 × 956 · 180 kB").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: $scale, in: 10 ... 100, step: 10)
            }
            chips(catalan ? "Que no passi de" : "No larger than", ["500 kB", "1 MB", "2 MB", "5 MB", catalan ? "Altres…" : "Other…"], selected: nil)
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
                        .frame(height: 28)
                        .background(Capsule().fill(Color.primary.opacity(index == selected ? 0.12 : 0.06)))
                        .overlay { if index == selected { Capsule().strokeBorder(Color.accentColor, lineWidth: 1.5) } }
                }
            }
        }
    }

    /// A list, like a menu: a label never wraps or breaks, in either language.
    private var share: some View {
        VStack(spacing: 0) {
            shareRow("square.on.square", catalan ? "Copia" : "Copy", ["⌘", "C"])
            shareRow("square.and.arrow.down", catalan ? "Desa com a…" : "Save As…", ["⌘", "S"])
            shareRow("folder", catalan ? "Mostra al Finder" : "Show in Finder", ["⌘", "R"])
            shareRow("eye", catalan ? "Vista ràpida" : "Quick Look", ["Space"])
            shareRow("rectangle.split.2x1", catalan ? "Compara amb l’original…" : "Compare with the Original…", [])
            Divider().opacity(0.6).padding(.vertical, 5)
            shareRow("square.and.arrow.up", catalan ? "Comparteix…" : "Share…", [], chevron: false)
            shareRow("arrow.up.forward.app", catalan ? "Obre amb" : "Open With", [], chevron: true)
            shareRow("point.3.connected.trianglepath.dotted", catalan ? "Passa-ho per un flux" : "Run a Pipeline", [], chevron: true)
            shareRow("icloud.and.arrow.up", catalan ? "Puja a R2" : "Upload to R2", [], chevron: false)
        }
        .padding(.horizontal, -6)
    }

    private func shareRow(_ symbol: String, _ title: String, _ keys: [String], chevron: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 20)
            Text(title).font(.system(size: 13))
            Spacer()
            if !keys.isEmpty { ProtoKeys(keys: keys) }
            if chevron { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
    }
}

/// The drop zone: glass targets in a row. The one under the drag grows and takes the accent.
struct ProtoDropZone: View {
    enum Mode { case idle, target, preset, aggressive }
    var mode: Mode = .idle
    var presets = true
    var catalan = false

    var body: some View {
        HStack(alignment: .bottom, spacing: Proto.gap) {
            if presets {
                tile("photo", catalan ? "A WebP" : "To WebP", hot: mode == .preset)
                tile("arrow.down.to.line", catalan ? "Menys d’1 MB" : "Under 1 MB", hot: false)
                tile("folder", catalan ? "Captures del blog" : "Blog screenshots", hot: false)
            }
            main
        }
    }

    private var main: some View {
        let hot = mode == .target || mode == .aggressive
        let tint: Color? = mode == .aggressive ? Proto.warm : (mode == .target ? Color.accentColor : nil)
        return HStack(spacing: 10) {
            if let glyph = MenuBarLabel.customGlyph {
                Image(nsImage: glyph).renderingMode(.template).resizable().aspectRatio(contentMode: .fit).frame(width: 34)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(mode == .aggressive
                    ? (catalan ? "Optimitza a fons" : "Optimise Aggressively")
                    : (catalan ? "Optimitza" : "Optimise"))
                    .font(.system(size: 15, weight: .semibold))
                Text(catalan ? "3 fitxers" : "3 files").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 92)
        .frame(minWidth: 168, alignment: .leading)
        .background { if let tint { RoundedRectangle(cornerRadius: Proto.tileRadius, style: .continuous).fill(tint.opacity(0.28)) } }
        .protoGlass(Proto.tileRadius)
        .scaleEffect(hot ? 1.05 : 1, anchor: .bottomTrailing)
        .opacity(mode == .preset ? 0.6 : 1)
    }

    private func tile(_ symbol: String, _ title: String, hot: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20, weight: .regular))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .frame(width: 92, height: 92)
        .background { if hot { RoundedRectangle(cornerRadius: Proto.tileRadius, style: .continuous).fill(Color.accentColor.opacity(0.28)) } }
        .protoGlass(Proto.tileRadius)
        .scaleEffect(hot ? 1.05 : 1, anchor: .bottom)
        .opacity(mode == .target || mode == .aggressive ? 0.6 : 1)
    }
}
