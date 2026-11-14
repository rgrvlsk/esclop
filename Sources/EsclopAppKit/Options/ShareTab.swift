// SPDX-License-Identifier: GPL-3.0-or-later
//
// Actions (docs/design/targets: pr4-options-popover-size-actions): one row each, a round symbol,
// what it does and what it gives, and a play button: the person's pipelines, Upload (the link on
// the clipboard), Share… (the system's services), then Run a Shortcut › and Open with ›. Copy ⌘C,
// Save as ⌘S, Show in Finder ⌘R and Quick Look ⌘Y are keys of the popover; Compare is the
// detail's loupe; how long results stay is in Settings.

import AppKit
import EsclopCore
import SwiftUI

struct ShareTab: View {
    let model: OptionsModel
    @State private var share = SharingAnchor()

    var body: some View {
        let app = model.app, card = model.card
        VStack(alignment: .leading, spacing: 8) {
            ForEach(app.pipelineNames, id: \.self) { name in
                ActionRow(symbol: "wand.and.rays", title: name, detail: Strings.text("Your pipeline")) { app.runPipeline(name, on: card) }
            }
            // Uploads to the person's own targets (Settings › Uploads), the link on the clipboard.
            let targets = app.uploadTargets
            ForEach(targets) { target in
                ActionRow(
                    symbol: "icloud.and.arrow.up", title: targets.count == 1 ? Strings.text("Upload") : Strings.format("Upload to %@", target.name),
                    detail: Strings.text("Copies a link")
                ) { app.upload(card, to: target.name) }
            }
            if targets.isEmpty {
                ActionRow(symbol: "icloud.and.arrow.up", title: Strings.text("Set Up Uploads…"), detail: Strings.text("In Settings"), opens: true) {
                    if let url = URL(string: "esclop://settings/uploads") { NSWorkspace.shared.open(url) }
                }
            }
            if let link = card.link {
                ActionRow(symbol: "link", title: Strings.text("Copy Link"), detail: link.host() ?? "") { app.copyLink(link) }
            }
            ActionRow(symbol: "square.and.arrow.up", title: Strings.text("Share…"), detail: Strings.text("AirDrop, Mail, Messages")) {
                share.show(card.shownFile, leftward: false)
            }
            .background(share.view.allowsHitTesting(false).accessibilityHidden(true))
            ForEach(AppModel.installed(AppModel.shelfApps), id: \.self) { url in
                ActionRow(symbol: "tray", title: Strings.format("Add to %@", Self.name(of: url)), detail: Strings.text("Shelf app")) { app.open(card, with: url) }
            }
            ForEach(AppModel.installed(AppModel.uploadApps), id: \.self) { url in
                ActionRow(symbol: "icloud.and.arrow.up", title: Strings.format("Upload with %@", Self.name(of: url)), detail: Strings.text("Upload app")) { app.open(card, with: url) }
            }
            VStack(spacing: 0) {
                DrillRow(symbol: "square.2.layers.3d", title: Strings.text("Run a Shortcut")) { model.drill = .shortcut }
                DrillRow(symbol: "arrow.up.forward.app", title: Strings.text("Open with")) { model.drill = .openWith }
            }
            .padding(.horizontal, 4)
            Button { app.onOpenPipelines?(nil) } label: {
                Label(Strings.text("Edit Pipelines…"), systemImage: "plus")
                    .font(OptionsType.bodyStrong)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .padding(.horizontal, 14)
                    .overlay(RoundedRectangle(cornerRadius: OptionsType.radius, style: .continuous)
                        .strokeBorder(PopoverInk.secondary.color.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(PopoverInk.primary.color)
        }
        .disabled(card.isWorking)
    }

    static func name(of app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// An action as a row: a round symbol, what it does and what it gives, and a play button.
struct ActionRow: View {
    let symbol: String
    let title: String
    let detail: String
    /// It opens somewhere else (Settings): a chevron, not a play button.
    var opens = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Surface.tile))
                    .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(OptionsType.bodyStrong).lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail).font(OptionsType.label).foregroundStyle(PopoverInk.secondary.color).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if opens {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PopoverInk.secondary.color)
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.92)))
                        .foregroundStyle(Ink.charcoal)
                        .environment(\.colorScheme, .light)
                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: OptionsType.radius, style: .continuous).fill(Surface.cream))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .foregroundStyle(PopoverInk.primary.color)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// The lists inside the popover.
struct OptionsDrill: View {
    let model: OptionsModel
    let drill: OptionsModel.Drill

    var body: some View {
        let app = model.app, card = model.card
        switch drill {
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
                    Text(Strings.text("No shortcuts yet. Make one in the Shortcuts app.")).foregroundStyle(PopoverInk.secondary.color)
                }
                ForEach(model.shortcuts, id: \.self) { name in
                    DrillRow(symbol: "square.2.layers.3d", title: name, chevron: false) { app.runShortcut(name, on: card) }
                }
            }
            .task { await model.loadShortcuts() }
        }
    }

    private func back() { model.drill = nil }
}
