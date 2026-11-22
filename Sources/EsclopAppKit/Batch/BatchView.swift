// SPDX-License-Identifier: GPL-3.0-or-later
//
// The batch window: the aggregate saving with the deflate bar and the controls for the whole
// batch on top, then one row per file with its progress, sizes, its own bar and its actions.
// The same language as the floating result: Ink.saving, the saving in `Figure.font`, the
// deflate bar contracting to the new proportion.

import AppKit
import EsclopCore
import EsclopOptimisers
import SwiftUI

public struct BatchView: View {
    let batch: Batch
    let app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The rows chosen with a click, ⌘-click, shift-click, ⌘A or the arrows: the context menu acts
    /// on them all, and they drag out together.
    @State private var selection = Set<BatchRow.ID>()
    /// The row under the pointer: Space shows it in Quick Look when nothing is selected.
    /// ponytail: set by hover, so a wheel scroll under a still pointer keeps the row it left until
    /// the pointer moves; clear it on scroll if that misleads.
    @State private var pointed: BatchRow.ID?
    @FocusState private var focused: Bool

    public init(batch: Batch, app: AppModel) {
        self.batch = batch
        self.app = app
    }

    /// Opens with rows selected, for the renders.
    init(batch: Batch, app: AppModel, selection: Set<BatchRow.ID>) {
        self.init(batch: batch, app: app)
        _selection = State(initialValue: selection)
    }

    public var body: some View {
        let info = BatchPresentation(batch: batch)
        VStack(spacing: 0) {
            BatchHeader(batch: batch, app: app, info: info)
            Divider()
            // A native list: the selection, ⌘A and the arrows work as in Finder.
            List(selection: $selection) {
                ForEach(batch.rows) { row in
                    BatchRowView(row: row, batch: batch, app: app) { inside in
                        if inside { pointed = row.id } else if pointed == row.id { pointed = nil }
                    }
                    .listRowInsets(EdgeInsets())
                    // A selected row drags out with the others selected.
                    .itemProvider { row.isFinished ? BatchRowView.provider(for: row.shownFile) : nil }
                }
            }
            .listStyle(.plain)
            // The keys work at once, before any click: Space on the row under the pointer.
            .focused($focused)
            .defaultFocus($focused, true)
            .contextMenu(forSelectionType: BatchRow.ID.self) { ids in
                BatchSelectionMenu(rows: batch.rows.filter { ids.contains($0.id) }, batch: batch, app: app)
            }
            .onKeyPress(.space) { quickLook() }
            // ⌘C copies the selected files, ⌫ puts their originals back.
            .onCopyCommand {
                // As L'Esclop's own copy, after SwiftUI has cleared the clipboard for the empty
                // list returned here (tried: a write inside this closure is lost).
                // ponytail: relies on that order, observed on macOS 26; a Copy menu command of
                // the window's own if an update breaks it.
                let files = selected.map(\.shownFile)
                Task { @MainActor in app.writeClipboard(files: files) }
                return []
            }
            .onDeleteCommand { restore(selected) }
            .onChange(of: batch.rows.map(\.id)) { _, ids in selection.formIntersection(ids) }
            if !selected.isEmpty {
                Divider()
                selectionBar
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 360, idealHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(reduceMotion ? nil : Motion.bar, value: info.barEnd)
        .designTint()
    }

    private var selected: [BatchRow] { batch.rows.filter { selection.contains($0.id) } }

    /// The selection's main actions under the rows, as in Originals; the rest are in its menu.
    private var selectionBar: some View {
        let rows = selected
        let restorable = rows.filter(\.canRestore), failed = rows.filter(\.canRetry), finished = rows.filter(\.isFinished)
        return HStack {
            Spacer()
            Button(Strings.text("Restore")) { restore(rows) }.disabled(restorable.isEmpty)
            Button(Strings.text("Try again")) { failed.forEach { $0.retry() } }.disabled(failed.isEmpty)
            Button(Strings.text("Remove from the List")) { finished.forEach(batch.remove) }.disabled(finished.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func restore(_ rows: [BatchRow]) {
        let restorable = rows.filter(\.canRestore)
        guard !restorable.isEmpty else { return }
        Task { for row in restorable { await app.restore(row) } }
    }

    /// The selected row, else the one under the pointer.
    private func quickLook() -> KeyPress.Result {
        let shown = batch.rows.first { selection.contains($0.id) } ?? batch.rows.first { $0.id == pointed }
        guard let row = shown, row.isFinished,
              FileManager.default.fileExists(atPath: row.shownFile.path) else { return .ignored }
        QuickLookPresenter.shared.toggle(row.shownFile)
        return .handled
    }
}

struct BatchHeader: View {
    let batch: Batch
    let app: AppModel
    let info: BatchPresentation
    @State private var confirmingRestore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.title).font(.title3.weight(.semibold))
                    if let change = info.change {
                        Text(change).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Spacer(minLength: 12)
                if let percent = info.percent {
                    Text(percent)
                        .font(Figure.font(Figure.Size.detail.rawValue))
                        .foregroundStyle(Ink.saving)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            DeflateBar(end: info.barIsNeutral ? 0 : info.barEnd, progress: info.progress, tint: info.progress == nil ? Ink.saving : Ink.progress, filled: info.progress == nil && !info.barIsNeutral)
            Text(info.counts).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            HStack(spacing: 8) {
                if batch.isRunning {
                    Button {
                        batch.paused ? batch.resume() : batch.pause()
                    } label: {
                        Label(batch.paused ? Strings.text("Resume") : Strings.text("Pause"), systemImage: batch.paused ? "play.fill" : "pause.fill")
                    }
                    Button(role: .destructive) { batch.cancelAll() } label: {
                        Label(Strings.text("Stop"), systemImage: "stop.fill")
                    }
                    .keyboardShortcut(".", modifiers: .command)
                }
                Button {
                    confirmingRestore = true
                } label: {
                    Label(Strings.text("Restore All"), systemImage: "arrow.uturn.backward")
                }
                .disabled(batch.restorable.isEmpty)
                .alert(Strings.text("Restore all originals?"), isPresented: $confirmingRestore) {
                    Button(Strings.text("Restore All"), role: .destructive) { Task { await app.restoreAll(batch) } }
                    Button(Strings.text("Cancel"), role: .cancel) {}
                } message: {
                    if batch.isRunning { Text(Strings.text("Files still to go are stopped first.")) }
                }
                if batch.failed > 0 {
                    Button {
                        app.retryFailed(batch)
                    } label: {
                        Label(Strings.text("Retry All Failed"), systemImage: "arrow.clockwise")
                    }
                }
                Spacer()
                Button {
                    app.reveal(batch.rows.filter(\.isFinished).map(\.shownFile))
                } label: {
                    Label(Strings.text("Show in Finder"), systemImage: "folder")
                }
                .disabled(batch.finished == 0)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(16)
        .accessibilityElement(children: .contain)
    }
}

struct BatchRowView: View {
    let row: BatchRow
    let batch: Batch
    let app: AppModel
    /// The pointer came onto the row or left it.
    var point: (Bool) -> Void = { _ in }
    @State private var hovering = false
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            picture
            VStack(alignment: .leading, spacing: 4) {
                Text(row.source.lastPathComponent).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(BatchPresentation.status(of: row))
                    .font(.subheadline)
                    .foregroundStyle(isError ? AnyShapeStyle(Ink.error) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .monospacedDigit()
                if let restoreError = row.restoreError {
                    Text(restoreError).font(.subheadline).foregroundStyle(Ink.error).lineLimit(2)
                }
                bar.frame(maxWidth: 180)
            }
            Spacer(minLength: 8)
            if hovering {
                actions.transition(.opacity)
            } else if let figure = BatchPresentation.figure(of: row) {
                Text(figure)
                    .font(Figure.font(Figure.Size.card.rawValue))
                    .foregroundStyle(Ink.saving)
                    .monospacedDigit()
            } else if case .working = row.state {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0; point($0) }
        .animation(Motion.hover, value: hovering)
        .help(row.isFinished ? Strings.text("Drag the file into another app") : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([row.source.lastPathComponent, BatchPresentation.status(of: row), row.restoreError].compactMap(\.self).joined(separator: ", "))
        .accessibilityValue(BatchPresentation.figure(of: row) ?? "")
        .accessibilityActions { menu }
        .task(id: row.shownFile) {
            guard let image = await Thumbnails.load(row.shownFile, side: 72) else { return }
            thumbnail = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
        }
    }

    private var isError: Bool {
        if case .failed = row.state { return true }
        if case .failed = row.upload { return true }
        return false
    }

    private var picture: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: Self.symbol(for: MediaKind.of(row.source))).font(.title3).foregroundStyle(.secondary)
            }
        }
        .frame(width: 36, height: 36)
        .background(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous).fill(Color.primary.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder private var bar: some View {
        switch row.state {
        case let .working(fraction):
            DeflateBar(end: 1, progress: fraction > 0 ? fraction : nil, tint: Ink.progress, filled: false)
        case let .done(result):
            DeflateBar(end: result.bytesBefore > 0 ? min(1, Double(result.bytesAfter) / Double(result.bytesBefore)) : 1, progress: nil, tint: Ink.saving, filled: true)
        case .waiting:
            DeflateBar(end: 1, progress: nil, tint: Ink.progress, filled: false).opacity(0.5)
        default:
            EmptyView()
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            if row.canRestore {
                RowButton(symbol: "arrow.uturn.backward", title: Strings.text("Restore the original")) { Task { await app.restore(row) } }
            }
            if row.canRetry {
                RowButton(symbol: "arrow.clockwise", title: Strings.text("Try again")) { row.retry() }
            }
            if row.isRunning {
                RowButton(symbol: "stop.fill", title: Strings.text("Stop")) { row.cancel?() }
            } else {
                RowButton(symbol: "square.on.square", title: Strings.text("Copy")) { app.writeClipboard(files: [row.shownFile]) }
                RowButton(symbol: "folder", title: Strings.text("Show in Finder")) { app.reveal([row.shownFile]) }
            }
        }
    }

    /// The row's VoiceOver actions: the context menu's buttons for this row, without its submenus.
    @ViewBuilder private var menu: some View {
        if let result = row.result {
            Button(Strings.text("Show as Result")) { app.show(result) }
            Button(Strings.text("Compare with the original…")) { app.onCompare?(result) }
        }
        if row.canRestore {
            Button(Strings.text("Restore the original")) { Task { await app.restore(row) } }
        }
        if row.canRetry { Button(Strings.text("Try again")) { row.retry() } }
        if row.isRunning { Button(Strings.text("Stop")) { row.cancel?() } }
        Button(Strings.text("Show in Finder")) { app.reveal([row.shownFile]) }
        Button(Strings.text("Copy")) { app.writeClipboard(files: [row.shownFile]) }
        if row.isFinished {
            Button(Strings.text("Quick Look")) { QuickLookPresenter.shared.show(row.shownFile) }
            Button(Strings.text("Remove from the List")) { batch.remove(row) }
        }
    }

    static func provider(for file: URL) -> NSItemProvider {
        NSItemProvider(contentsOf: file) ?? NSItemProvider(object: file as NSURL)
    }

    static func symbol(for kind: MediaKind?) -> String {
        switch kind {
        case .video: return "film"
        case .pdf: return "doc.richtext"
        case .audio: return "waveform"
        case .image, nil: return "photo"
        }
    }
}

/// The context menu for the selected rows (or the row clicked outside the selection), and a
/// row's VoiceOver actions: every action applies to each row it fits.
struct BatchSelectionMenu: View {
    let rows: [BatchRow]
    let batch: Batch
    let app: AppModel

    var body: some View {
        // Right-clicking the empty area below the rows selects nothing: no menu.
        if !rows.isEmpty { menu }
    }

    @ViewBuilder private var menu: some View {
        let finished = rows.filter(\.isFinished)
        let restorable = rows.filter(\.canRestore)
        let failed = rows.filter(\.canRetry)
        let kinds = Set(finished.map { MediaKind.of($0.source) })
        if rows.count == 1, let result = rows[0].result {
            // Its floating result, with the options popover's every choice.
            Button(Strings.text("Show as Result")) { app.show(result) }
            Button(Strings.text("Compare with the original…")) { app.onCompare?(result) }
            Divider()
        }
        if !finished.isEmpty {
            Menu(Strings.text("Optimise Again With")) {
                if kinds.count == 1, let kind = kinds.first, !OptionsModel.formats(for: kind).isEmpty {
                    Section(Strings.text("Format")) {
                        ForEach(OptionsModel.formats(for: kind), id: \.self) { format in
                            Button(format.displayName) { run { await app.rerun(finished, as: format) } }
                        }
                    }
                }
                Section(Strings.text("Compression")) {
                    ForEach(OptimiseChoice.Compression.allCases, id: \.self) { compression in
                        Button(compression.title) { run { await app.rerun(finished, compression: compression) } }
                    }
                }
            }
            // Pixels to crop and scale: images and videos, as the card's Size and Crop tabs.
            if kinds.isSubset(of: [.image, .video]) {
                Menu(Strings.text("Crop")) {
                    ForEach(CropAspect.presets.filter { $0 != .free }) { aspect in
                        Button(aspect.title) { run { await app.crop(finished, to: aspect) } }
                    }
                }
                Menu(Strings.text("Downscale")) {
                    ForEach([2000, 1280], id: \.self) { side in
                        Button("\(side)\u{00A0}px") { run { await app.downscale(finished, longSide: side) } }
                    }
                    Button(Strings.text("Half")) { run { await app.downscale(finished, longSide: nil) } }
                }
            }
        }
        if !restorable.isEmpty {
            Button(restorable.count == 1 ? Strings.text("Restore the original") : Strings.format("Restore %d originals", restorable.count)) {
                run { for row in restorable { await app.restore(row) } }
            }
        }
        if !failed.isEmpty { Button(Strings.text("Try again")) { failed.forEach { $0.retry() } } }
        let running = rows.filter(\.isRunning)
        if !running.isEmpty { Button(Strings.text("Stop")) { running.forEach { $0.cancel?() } } }
        Divider()
        Button(Strings.text("Show in Finder")) { app.reveal(rows.map(\.shownFile)) }
        Button(Strings.text("Copy")) { app.writeClipboard(files: rows.map(\.shownFile)) }
        if finished.count == 1 {
            Button(Strings.text("Quick Look")) { QuickLookPresenter.shared.show(finished[0].shownFile) }
        }
        if !finished.isEmpty {
            Divider()
            Button(Strings.text("Remove from the List")) { finished.forEach(batch.remove) }
        }
    }

    private func run(_ work: @escaping @MainActor () async -> Void) {
        Task { await work() }
    }
}

/// A 28 pt round button, like the floating result's hover buttons.
struct RowButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: Metrics.toolSize, height: Metrics.toolSize)
                .background(Circle().fill(Color.primary.opacity(0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Shows the batch window when a batch starts. It comes forward without taking focus from the
/// app the person is working in; clicking it makes it key.
@MainActor
final class BatchWindowController {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show(_ batch: Batch) {
        let window = self.window ?? makeWindow()
        self.window = window
        window.contentView = NSHostingView(rootView: BatchView(batch: batch, app: model))
        window.title = Strings.text("Batch")
        if !window.isVisible { window.center() }
        window.orderFrontRegardless()
    }

    func close() {
        window?.close()
        window?.contentView = nil
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("dev.esclop.batch")
        window.collectionBehavior = [.moveToActiveSpace]
        return window
    }
}
