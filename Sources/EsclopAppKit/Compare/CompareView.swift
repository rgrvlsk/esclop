// SPDX-License-Identifier: GPL-3.0-or-later
//
// The compare window: the result's name and saving, the layout and zoom controls, the two
// files, what each one is (format, size, dimensions) and what to do with the result: keep it,
// restore the original, try another compression or format, copy it or show it in Finder.

import AppKit
import EsclopCore
import SwiftUI

public struct CompareView: View {
    @Bindable var model: CompareModel
    @Environment(\.displayScale) private var displayScale

    public init(model: CompareModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
                .overlay { if model.isWorking { working } }
            Divider()
            CompareFooter(model: model)
        }
        .tint(Palette.accent)
        .task(id: model.loadKey) { await model.load() }
        .background {
            // Esc closes, as in Clop.
            Button(Strings.text("Close")) { model.close() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.result?.output.lastPathComponent ?? "")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let result = model.result {
                    Text(Figures.change(before: result.bytesBefore, after: result.bytesAfter))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if let result = model.result, !Figures.isNoSaving(before: result.bytesBefore, after: result.bytesAfter) {
                Text(Figures.percent(before: result.bytesBefore, after: result.bytesAfter))
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .foregroundStyle(result.bytesAfter < result.bytesBefore ? Palette.accent : Color.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 12)
            if case .ready = model.sides {
                Picker(Strings.text("Layout"), selection: $model.mode) {
                    Label(Strings.text("Split"), systemImage: "rectangle.lefthalf.inset.filled").tag(CompareModel.Mode.split)
                    Label(Strings.text("Side by side"), systemImage: "rectangle.split.2x1").tag(CompareModel.Mode.sideBySide)
                    Label(Strings.text("Flip"), systemImage: "rectangle.on.rectangle").tag(CompareModel.Mode.flip)
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
                .labelsHidden()
                .fixedSize()

                .help(Strings.text("How the two files are shown"))
                if model.mode == .flip {
                    Button(model.showsOriginal ? Strings.text("Show Optimised") : Strings.text("Show Original")) { model.showsOriginal.toggle() }
                        .keyboardShortcut(.space, modifiers: [])
                        .help(Strings.text("Flip between the two (Space)"))
                }
                if model.kind == .image || model.kind == .pdf { pictureControls }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var pictureControls: some View {
        HStack(spacing: 4) {
            Button(Strings.text("Zoom Out"), systemImage: "minus.magnifyingglass") {
                model.viewport.zoomOut(pixels: model.pixels, in: canvasSize, displayScale: displayScale)
            }
            .keyboardShortcut("-", modifiers: .command)
            Button(model.viewport.zoom == nil ? Strings.text("Fit") : model.viewport.label(pixels: model.pixels, in: canvasSize, displayScale: displayScale)) {
                if model.viewport.zoom == nil { model.viewport.zoom = 1 } else { model.viewport.fit() }
            }
            .monospacedDigit()
            .frame(minWidth: 52)
            .help(Strings.text("Fit, or 100 % (one image pixel per screen pixel)"))
            .accessibilityLabel(Strings.format("Zoom: %@", model.viewport.label(pixels: model.pixels, in: canvasSize, displayScale: displayScale)))
            Button(Strings.text("Zoom In"), systemImage: "plus.magnifyingglass") {
                model.viewport.zoomIn(pixels: model.pixels, in: canvasSize, displayScale: displayScale)
            }
            .keyboardShortcut("=", modifiers: .command)
            Toggle(isOn: $model.showsDifference) {
                Label(Strings.text("Differences"), systemImage: "square.2.layers.3d.top.filled")
            }
            .switchLabel(title: Strings.text("Differences"), hint: Strings.text("Mark in red where the two differ"))
            .toggleStyle(.button)
            .disabled(model.difference == nil)
            .help(Strings.text("Mark in red where the two differ"))

        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .background {
            // ⌘0 fits, ⌘1 shows 100 %: shortcuts without buttons of their own (a background
            // takes no room in the layout).
            Group {
                Button(Strings.text("Fit")) { model.viewport.fit() }.keyboardShortcut("0", modifiers: .command)
                Button(Strings.text("Actual Size")) { model.viewport.zoom = 1 }.keyboardShortcut("1", modifiers: .command)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    /// The canvas size the zoom buttons work against (the window less its bars).
    @State private var canvasSize = CGSize(width: 900, height: 560)

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.sides {
        case .ready:
            Group {
                switch model.kind {
                case .video?:
                    if let players = model.players { CompareVideo(model: model, players: players).padding(12) } else { ProgressView() }
                case .audio?:
                    CompareAudio(model: model)
                default:
                    if model.afterImage == nil { ProgressView() } else { CompareCanvas(model: model) }
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
        case let .pruned(after):
            CompareMessage(
                symbol: "clock.arrow.circlepath",
                title: Strings.text("The original is no longer kept"),
                detail: Strings.format("Backups of originals are kept for %@, and this one has been removed. The optimised file is still in place: %@.", backupDays, after.lastPathComponent)

            )
        case .restored:
            CompareMessage(
                symbol: "arrow.uturn.backward.circle",
                title: Strings.text("The original is back"),
                detail: Strings.text("This result was undone, so there is no optimised version to compare.")
            )
        case .gone:
            CompareMessage(
                symbol: "questionmark.folder",
                title: Strings.text("The optimised file is not there"),
                detail: Strings.text("It was moved or deleted after it was optimised.")
            )
        }
    }

    private var backupDays: String {
        let days = EsclopSettings.backupRetentionDays.value(in: model.app.settings)
        return days == 1 ? Strings.text("1 day") : Strings.format("%d days", days)
    }

    private var working: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(Strings.text("Optimising…")).font(.headline)
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .accessibilityElement(children: .combine)
    }
}

/// A plain message where the comparison would be.
struct CompareMessage: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(detail)
        }
    }
}

/// Audio: two cards, one plays at a time; the transport sits in the footer.
struct CompareAudio: View {
    @Bindable var model: CompareModel

    var body: some View {
        HStack(spacing: 16) {
            card(title: Strings.text("Original"), url: model.sides.before)
            card(title: Strings.text("Optimised"), url: model.sides.after)
        }
        .padding(24)
    }

    private func card(title: String, url: URL?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform").font(.system(size: 42)).foregroundStyle(Palette.accent).accessibilityHidden(true)
            Text(title).font(.headline)
            if let url {
                Text(CompareMedia.formatName(url) + " · " + Figures.bytes(AppModel.size(of: url))).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .accessibilityElement(children: .combine)
    }
}
