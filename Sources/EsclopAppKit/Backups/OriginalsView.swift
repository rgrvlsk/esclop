// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Originals window, from the menu's gear: every original L'Esclop keeps, newest first, with
// its thumbnail, folder, date and size, Restore, Show in Finder and Remove; ⌘A or shift-click
// selects several for Restore and Remove, Space shows the selected one in Quick Look. Their
// total and Remove All under them. A plain native list.

import AppKit
import EsclopCore
import SwiftUI

struct OriginalsView: View {
    let model: OriginalsModel
    @State private var selection = Set<OriginalItem.ID>()
    /// The originals a Remove asks about; all of them for Remove All.
    @State private var removing: [OriginalItem]?

    init(model: OriginalsModel, selection: Set<OriginalItem.ID> = []) {
        self.model = model
        _selection = State(initialValue: selection)
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.loaded, model.items.isEmpty {
                // The retention sentence once, and no "0 originals · 0 B" under it.
                ContentUnavailableView(Strings.text("No originals kept"), systemImage: "clock.arrow.circlepath", description: Text(retention))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(model.items) { item in
                        OriginalRow(item: item, model: model) { removing = [item] }
                    }
                }
                .contextMenu(forSelectionType: OriginalItem.ID.self) { ids in menu(model.items(ids)) }
                .onKeyPress(.space) { quickLook() }
                .onDeleteCommand { if !selected.isEmpty { removing = selected } }
                Divider()
                footer
            }
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 320, idealHeight: 440)
        .task { await model.load() }
        .onAppear { model.watch() }
        .onDisappear { model.stopWatching() }
        .onChange(of: model.items.map(\.id)) { _, ids in selection.formIntersection(ids) }
        .confirmationDialog(removalTitle, isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(Strings.text("Remove"), role: .destructive) {
                let items = removing ?? []
                Task { await model.remove(items) }
            }
        } message: {
            Text(Strings.text("These files can no longer be restored. This cannot be undone."))
        }
        .alert(failureTitle, isPresented: Binding(get: { !model.removalFailures.isEmpty }, set: { if !$0 { model.removalFailures = [] } })) {
            EmptyView()
        } message: {
            Text(model.removalFailures.formatted(.list(type: .and, width: .standard).locale(Strings.locale)))
        }
        .designTint()
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary).monospacedDigit()
                Text(retention).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if selected.isEmpty {
                Button(Strings.text("Remove All…"), role: .destructive) { removing = model.items }
                    .disabled(model.items.isEmpty)
            } else {
                Button(Strings.text("Restore")) { restore(selected) }
                    .disabled(selected.allSatisfy(\.inPlace))
                Button(Strings.text("Remove…"), role: .destructive) { removing = selected }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder private func menu(_ items: [OriginalItem]) -> some View {
        if !items.isEmpty {
            if items.contains(where: { !$0.inPlace }) { Button(Strings.text("Restore")) { restore(items) } }
            Button(Strings.text("Show in Finder")) { model.reveal(items) }
            if items.count == 1 { Button(Strings.text("Quick Look")) { QuickLookPresenter.shared.show(items[0].entry.backup) } }
            Divider()
            Button(Strings.text("Remove…"), role: .destructive) { removing = items }
        }
    }

    private var selected: [OriginalItem] { model.items(selection) }

    private func restore(_ items: [OriginalItem]) {
        Task { await model.restore(items) }
    }

    private func quickLook() -> KeyPress.Result {
        guard let item = selected.first else { return .ignored }
        QuickLookPresenter.shared.toggle(item.entry.backup)
        return .handled
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

    private var removalTitle: String {
        let count = removing?.count ?? 0
        if count == model.items.count, count > 1 { return Strings.text("Remove every original?") }
        return count == 1 ? Strings.text("Remove this original?") : Strings.format("Remove %d originals?", count)
    }

    private var failureTitle: String {
        let count = model.removalFailures.count
        return count == 1 ? Strings.text("Could not remove 1 original") : Strings.format("Could not remove %d originals", count)
    }
}

struct OriginalRow: View {
    let item: OriginalItem
    let model: OriginalsModel
    let remove: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            picture
            VStack(alignment: .leading, spacing: 2) {
                Text(item.entry.original.lastPathComponent).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 0) {
                    // Two IMG_0001.jpg differ by their folder; the full path is in the help tag.
                    Text(folder).lineLimit(1).truncationMode(.head).layoutPriority(-1)
                    Text(" · " + details).lineLimit(1).fixedSize()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer(minLength: 8)
            if item.inPlace {
                Text(Strings.text("In place")).foregroundStyle(.secondary)
            } else {
                Button(Strings.text("Restore")) { Task { await model.restore([item]) } }
            }
            Button(Strings.text("Show in Finder"), systemImage: "folder") { model.reveal([item]) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(Strings.text("Show in Finder"))
        }
        .padding(.vertical, 3)
        .help(item.entry.original.path)
        // One element with each action once, not the buttons again as children.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.entry.original.lastPathComponent, folder, details, item.inPlace ? Strings.text("In place") : nil].compactMap(\.self).joined(separator: ", "))
        .accessibilityActions {
            if !item.inPlace { Button(Strings.text("Restore")) { Task { await model.restore([item]) } } }
            Button(Strings.text("Show in Finder")) { model.reveal([item]) }
            Button(Strings.text("Remove…"), action: remove)
        }
        .task(id: item.id) {
            guard model.app.loadsThumbnails, let image = await Thumbnails.load(item.entry.backup, side: 72) else { return }
            thumbnail = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
        }
    }

    /// The thumbnail the batch and menu rows use; the file's icon until it loads.
    private var picture: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.entry.backup.path)).resizable()
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    /// Where Restore writes: "~/Pictures/Trips".
    private var folder: String {
        (item.entry.original.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
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
