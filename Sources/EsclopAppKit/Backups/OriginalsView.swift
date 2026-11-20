// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Originals window, from the menu's gear: every original L'Esclop keeps, newest first, with
// its date and size, Restore and Show in Finder; their total and Remove All under them. A plain
// native list.

import AppKit
import EsclopCore
import SwiftUI

struct OriginalsView: View {
    let model: OriginalsModel
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(spacing: 0) {
            if model.loaded, model.items.isEmpty {
                ContentUnavailableView(Strings.text("No originals kept"), systemImage: "clock.arrow.circlepath", description: Text(retention))
                    .frame(maxHeight: .infinity)
            } else {
                List(model.items) { item in OriginalRow(item: item, model: model) }
            }
            Divider()
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary).monospacedDigit()
                    Text(retention).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button(Strings.text("Remove All…"), role: .destructive) { confirmingRemoval = true }
                    .disabled(model.items.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 320, idealHeight: 440)
        .task { await model.load() }
        .confirmationDialog(Strings.text("Remove every original?"), isPresented: $confirmingRemoval) {
            Button(Strings.text("Remove All"), role: .destructive) { Task { await model.removeAll() } }
        } message: {
            Text(Strings.text("These files can no longer be restored. This cannot be undone."))
        }
        .designTint()
    }

    /// "12 originals · 48 MB"
    private var summary: String {
        let size = Figures.bytes(model.totalBytes)
        return model.items.count == 1 ? Strings.format("1 original · %@", size) : Strings.format("%d originals · %@", model.items.count, size)
    }

    private var retention: String {
        let days = model.retentionDays
        return days == 0 ? Strings.text("Originals are kept until you remove them.") : Strings.format("Originals are kept for %@, then removed.", SettingPresentation.retention(days: days))
    }
}

struct OriginalRow: View {
    let item: OriginalItem
    let model: OriginalsModel

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.entry.backup.path))
                .resizable()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.entry.original.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(details).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            if item.inPlace {
                Text(Strings.text("In place")).foregroundStyle(.secondary)
            } else {
                Button(Strings.text("Restore")) { Task { await model.restore(item) } }
            }
            Button(Strings.text("Show in Finder"), systemImage: "folder") { model.reveal(item) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(Strings.text("Show in Finder"))
        }
        .padding(.vertical, 3)
        .contextMenu { actions }
        .accessibilityElement(children: .combine)
        .accessibilityActions { actions }
    }

    @ViewBuilder private var actions: some View {
        if !item.inPlace { Button(Strings.text("Restore")) { Task { await model.restore(item) } } }
        Button(Strings.text("Show in Finder")) { model.reveal(item) }
    }

    /// "19 Nov 2026, 9:41 · 2.4 MB"
    private var details: String {
        let date = item.entry.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Strings.locale))
        return date + " · " + Figures.bytes(item.entry.bytes)
    }
}

/// One Originals window, reused; it reads the backups again each time it is shown.
@MainActor
final class OriginalsWindowController {
    let model: OriginalsModel
    private var window: NSWindow?

    init(model: OriginalsModel) {
        self.model = model
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.contentView = NSHostingView(rootView: OriginalsView(model: model))
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.title = Strings.text("Originals")
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("dev.esclop.originals")
        return window
    }
}
