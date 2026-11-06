// SPDX-License-Identifier: GPL-3.0-or-later
//
// The batch window: the aggregate saving with the deflate bar and the controls for the whole
// batch on top, then one row per file with its progress, sizes, its own bar and its actions.
// The same language as the floating result: Palette.accent, the rounded saving figure, the
// deflate bar contracting to the new proportion.

import AppKit
import EsclopCore
import EsclopOptimisers
import SwiftUI

public struct BatchView: View {
    let batch: Batch
    let app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(batch: Batch, app: AppModel) {
        self.batch = batch
        self.app = app
    }

    public var body: some View {
        let info = BatchPresentation(batch: batch)
        VStack(spacing: 0) {
            BatchHeader(batch: batch, app: app, info: info)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(batch.rows) { row in
                        BatchRowView(row: row, batch: batch, app: app)
                        Divider().padding(.leading, 64)
                    }
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 360, idealHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(reduceMotion ? nil : Motion.bar, value: info.barEnd)
    }
}

struct BatchHeader: View {
    let batch: Batch
    let app: AppModel
    let info: BatchPresentation

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
                        .font(.system(.title, design: .rounded).weight(.semibold))
                        .foregroundStyle(Palette.accent)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            DeflateBar(end: info.barEnd, progress: info.progress, tint: Palette.accent, filled: info.progress == nil)
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
                    Task { await app.restoreAll(batch) }
                } label: {
                    Label(Strings.text("Restore All"), systemImage: "arrow.uturn.backward")
                }
                .disabled(batch.restorable.isEmpty)
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
    @State private var hovering = false
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            picture
            VStack(alignment: .leading, spacing: 4) {
                Text(row.source.lastPathComponent).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(BatchPresentation.status(of: row))
                    .font(.subheadline)
                    .foregroundStyle(isError ? Color.red : .secondary)
                    .lineLimit(2)
                    .monospacedDigit()
                bar.frame(maxWidth: 180)
            }
            Spacer(minLength: 8)
            if hovering {
                actions.transition(.opacity)
            } else if let figure = BatchPresentation.figure(of: row) {
                Text(figure)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(Palette.accent)
                    .monospacedDigit()
            } else if case .working = row.state {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.source.lastPathComponent), \(BatchPresentation.status(of: row))")
        .accessibilityValue(BatchPresentation.figure(of: row) ?? "")
        .accessibilityActions { menu }
        .task(id: row.shownFile) {
            guard let image = await Thumbnails.load(row.shownFile, side: 72) else { return }
            thumbnail = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
        }
    }

    private var isError: Bool {
        if case .failed = row.state { return true }
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
            DeflateBar(end: 1, progress: fraction > 0 ? fraction : nil, tint: Palette.accent, filled: false)
        case let .done(result):
            DeflateBar(end: result.bytesBefore > 0 ? min(1, Double(result.bytesAfter) / Double(result.bytesBefore)) : 1, progress: nil, tint: Palette.accent, filled: true)
        case .waiting:
            DeflateBar(end: 1, progress: nil, tint: Palette.accent, filled: false).opacity(0.5)
        default:
            EmptyView()
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            if row.result?.backup != nil {
                RowButton(symbol: "arrow.uturn.backward", title: Strings.text("Restore the original")) { Task { await app.restore(row) } }
            }
            if canRetry {
                RowButton(symbol: "arrow.clockwise", title: Strings.text("Try again")) { row.retry?() }
            }
            if row.isRunning {
                RowButton(symbol: "stop.fill", title: Strings.text("Stop")) { row.cancel?() }
            } else {
                RowButton(symbol: "doc.on.doc", title: Strings.text("Copy")) { Clipboard.write(files: [row.shownFile], to: app.pasteboard) }
                RowButton(symbol: "folder", title: Strings.text("Show in Finder")) { app.reveal([row.shownFile]) }
            }
        }
    }

    private var canRetry: Bool {
        switch row.state {
        case .failed, .cancelled: return true
        default: return false
        }
    }

    @ViewBuilder private var menu: some View {
        if row.result?.backup != nil {
            Button(Strings.text("Restore the original")) { Task { await app.restore(row) } }
        }
        if canRetry { Button(Strings.text("Try again")) { row.retry?() } }
        if row.isRunning { Button(Strings.text("Stop")) { row.cancel?() } }
        Button(Strings.text("Show in Finder")) { app.reveal([row.shownFile]) }
        Button(Strings.text("Copy")) { Clipboard.write(files: [row.shownFile], to: app.pasteboard) }
        if row.isFinished {
            Divider()
            Button(Strings.text("Remove from the List")) { batch.remove(row) }
        }
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
