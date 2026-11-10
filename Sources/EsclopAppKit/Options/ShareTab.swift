// SPDX-License-Identifier: GPL-3.0-or-later
//
// Share: a row of round buttons (Copy, AirDrop, Save as, Show in Finder, Quick Look, Share…),
// then drill-downs (Open with, Run a Shortcut, Run a pipeline, shelf and upload apps when they
// are installed), and the footer: how long results stay visible, and which hover buttons show.

import AppKit
import EsclopCore
import SwiftUI

struct ShareTab: View {
    let model: OptionsModel

    var body: some View {
        let app = model.app, card = model.card
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 2) {
                RoundAction(symbol: "doc.on.doc", title: Strings.text("Copy"), shortcut: "⌘C") { app.perform(.copy, on: card) }
                RoundAction(symbol: "airplayaudio", title: "AirDrop") { app.airDrop(card) }
                RoundAction(symbol: "square.and.arrow.down", title: Strings.text("Save as…"), shortcut: "⌘S") { app.saveAs(card) }
                RoundAction(symbol: "folder", title: "Finder", shortcut: "⌘R") { app.perform(.reveal, on: card) }
                RoundAction(symbol: "eye", title: Strings.text("Quick Look"), shortcut: Strings.text("Space")) { app.quickLook(card) }
                    .keyboardShortcut(.space, modifiers: [])
                SharePickerButton(file: card.shownFile)
            }
            .padding(.vertical, 6)
            Divider()
            DrillRow(symbol: "arrow.up.forward.app", title: Strings.text("Open with")) { model.drill = .openWith }
            DrillRow(symbol: "square.2.layers.3d", title: Strings.text("Run a Shortcut")) { model.drill = .shortcut }
            DrillRow(symbol: "wand.and.rays", title: Strings.text("Run a pipeline")) { model.drill = .pipeline }
            ForEach(AppModel.installed(AppModel.shelfApps), id: \.self) { url in
                DrillRow(symbol: "tray", title: Strings.format("Add to %@", Self.name(of: url)), chevron: false) { app.open(card, with: url) }
            }
            ForEach(AppModel.installed(AppModel.uploadApps), id: \.self) { url in
                DrillRow(symbol: "icloud.and.arrow.up", title: Strings.format("Upload with %@", Self.name(of: url)), chevron: false) { app.open(card, with: url) }
            }
            Divider().padding(.top, 4)
            HStack {
                Button { model.drill = .keepVisible } label: {
                    Text(Strings.text("Keep visible") + " · " + Self.keepVisible(app.keepVisibleSeconds(for: card)) + " ›")
                }
                Spacer()
                Button(Strings.text("Customise buttons…")) { model.drill = .hoverButtons }
            }
            .buttonStyle(.plain)
            .font(OptionsType.label)
            .foregroundStyle(.secondary)
        }
    }

    static func name(of app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    static func keepVisible(_ seconds: Int?) -> String {
        guard let seconds else { return Strings.text("Always") }
        return seconds < 60 ? "\(seconds)\u{00A0}s" : "\(seconds / 60)\u{00A0}min"
    }
}

/// A 32 pt round button with its name and shortcut under it.
struct RoundAction: View {
    let symbol: String
    let title: String
    var shortcut: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
                // Two lines kept for every name, so the shortcuts sit on one line across the row.
                Text(title).font(OptionsType.label).lineLimit(2, reservesSpace: true).multilineTextAlignment(.center)
                if let shortcut { Text(shortcut).font(OptionsType.label).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// "Share…": the system share picker, anchored to the button.
struct SharePickerButton: View {
    let file: URL

    var body: some View {
        RoundAction(symbol: "square.and.arrow.up", title: Strings.text("Share…")) {
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView else { return }
            let picker = NSSharingServicePicker(items: [file])
            let point = window.mouseLocationOutsideOfEventStream
            picker.show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1), of: view, preferredEdge: .minY)
        }
    }
}

/// The lists inside the popover.
struct OptionsDrill: View {
    let model: OptionsModel
    let drill: OptionsModel.Drill

    var body: some View {
        let app = model.app, card = model.card
        switch drill {
        case .encoder:
            DrillPage(title: Strings.text("Re-optimise with"), back: back) {
                ForEach(VideoEncoder.allCases, id: \.self) { encoder in
                    DrillRow(symbol: model.card.choice.videoEncoder == encoder ? "checkmark" : "cpu", title: encoder.displayName, chevron: false) {
                        model.update { $0.videoEncoder = encoder }
                        back()
                    }
                }
            }
        case .openWith:
            DrillPage(title: Strings.text("Open with"), back: back) {
                ForEach(app.apps(toOpen: card), id: \.self) { url in
                    Button { app.open(card, with: url) } label: {
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                            Text(ShareTab.name(of: url))
                            Spacer()
                        }
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        case .shortcut:
            DrillPage(title: Strings.text("Run a Shortcut"), back: back) {
                if model.shortcuts.isEmpty {
                    Text(Strings.text("No shortcuts yet. Make one in the Shortcuts app.")).foregroundStyle(.secondary)
                }
                ForEach(model.shortcuts, id: \.self) { name in
                    DrillRow(symbol: "square.2.layers.3d", title: name, chevron: false) { app.runShortcut(name, on: card) }
                }
            }
            .task { await model.loadShortcuts() }
        case .pipeline:
            DrillPage(title: Strings.text("Run a pipeline"), back: back) {
                let names = app.pipelineNames
                if names.isEmpty {
                    Text(Strings.text("No pipelines yet. Save one in Settings or with `esclop pipeline`.")).foregroundStyle(.secondary)
                }
                ForEach(names, id: \.self) { name in
                    DrillRow(symbol: "wand.and.rays", title: name, chevron: false) { app.runPipeline(name, on: card) }
                }
            }
        case .keepVisible:
            DrillPage(title: Strings.text("Keep visible"), back: back) {
                ForEach([5, 10, 30, 60, 300], id: \.self) { seconds in
                    DrillRow(symbol: app.keepVisibleSeconds(for: card) == seconds ? "checkmark" : "clock", title: ShareTab.keepVisible(seconds), chevron: false) {
                        app.setKeepVisible(seconds, for: card)
                        back()
                    }
                }
                DrillRow(symbol: app.keepVisibleSeconds(for: card) == nil ? "checkmark" : "pin", title: Strings.text("Always"), chevron: false) {
                    app.setKeepVisible(nil, for: card)
                    back()
                }
            }
        case .hoverButtons:
            DrillPage(title: Strings.text("Hover buttons"), back: back) {
                let shown = Set(app.hoverButtons)
                ForEach(["undo", "convert", "downscale", "crop"], id: \.self) { name in
                    SwitchRow(title: CardPresentation.hoverButtonTitle(name), isOn: Binding(
                        get: { shown.contains(name) },
                        set: { app.setHoverButton(name, shown: $0) }
                    ))
                }
                Text(Strings.text("“…” always stays, so the options are one click away.")).font(OptionsType.label).foregroundStyle(.secondary)
            }
        }
    }

    private func back() { model.drill = nil }
}
