// SPDX-License-Identifier: GPL-3.0-or-later
//
// Under the comparison: what each side is, the page or playback controls, and what to do with
// the result.

import AppKit
import EsclopCore
import SwiftUI

struct CompareFooter: View {
    @Bindable var model: CompareModel
    @State private var confirmingRestore = false

    var body: some View {
        VStack(spacing: 10) {
            if case .ready = model.sides {
                HStack(alignment: .top, spacing: 16) {
                    sideInfo(title: Strings.text("Original"), url: model.sides.before, image: model.beforeImage)
                    Spacer(minLength: 8)
                    middle
                    Spacer(minLength: 8)
                    sideInfo(title: Strings.text("Optimised"), url: model.sides.after, image: model.afterImage, trailing: true)
                }
            }
            HStack(spacing: 8) {
                if model.sides.after != nil {
                    tryAnother
                    Button(Strings.text("Copy"), systemImage: "doc.on.doc") { model.copy() }
                        .keyboardShortcut("c", modifiers: .command)
                    Button(Strings.text("Show in Finder"), systemImage: "folder") { model.reveal() }
                        .keyboardShortcut("r", modifiers: .command)
                }
                Spacer()
                if case .ready = model.sides {
                    Button(Strings.text("Restore Original")) { confirmingRestore = true }
                        .help(Strings.text("Put the original back and drop the optimised file"))
                    Button(Strings.text("Keep")) { model.keep() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .help(Strings.text("Keep the optimised file and close"))
                } else {
                    Button(Strings.text("Close")) { model.close() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .disabled(model.isWorking)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .confirmationDialog(Strings.text("Restore the original?"), isPresented: $confirmingRestore) {
            Button(Strings.text("Restore Original"), role: .destructive) { Task { await model.restore() } }
        } message: {
            Text(Strings.text("The optimised file is replaced by the original."))
        }
    }

    // MARK: Parts

    @ViewBuilder
    private var middle: some View {
        if model.kind == .pdf, model.pageCount > 1 {
            HStack(spacing: 6) {
                Button(Strings.text("Previous Page"), systemImage: "chevron.left") { model.previousPage() }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(model.page == 0)
                Text(Strings.format("Page %d of %d", model.page + 1, model.pageCount)).monospacedDigit()
                Button(Strings.text("Next Page"), systemImage: "chevron.right") { model.nextPage() }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(model.page + 1 >= model.pageCount)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        } else if let players = model.players {
            CompareTransport(players: players).frame(maxWidth: 520)
        } else if let difference = model.difference, model.showsDifference {
            Text(Strings.format("%@ of the pixels differ noticeably", Self.share(difference.changed)))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func sideInfo(title: String, url: URL?, image: CGImage?, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            if let url {
                Text(Self.describe(url: url, image: model.kind == .pdf ? nil : image, result: trailing ? model.result : nil, pages: model.kind == .pdf ? model.pageCount : nil))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var tryAnother: some View {
        Menu {
            Section(Strings.text("Compression")) {
                ForEach(OptimiseChoice.Compression.allCases, id: \.self) { compression in
                    Button(Self.title(compression)) {
                        var choice = model.choice
                        choice.compression = compression
                        model.tryAgain(with: choice)
                    }
                }
            }
            let formats = OptionsModel.formats(for: model.kind)
            if !formats.isEmpty {
                Section(Strings.text("Format")) {
                    ForEach(formats, id: \.self) { format in
                        Button(CardPresentation.formatName(format)) {
                            var choice = model.choice
                            choice.format = format
                            model.tryAgain(with: choice)
                        }
                    }
                }
            }
        } label: {
            Label(Strings.text("Try Another…"), systemImage: "wand.and.stars")
        }
        .fixedSize()
        .help(Strings.text("Optimise again from the original with another compression or format"))
    }

    // MARK: Words

    static func title(_ compression: OptimiseChoice.Compression) -> String {
        switch compression {
        case .adaptive: Strings.text("Adaptive")
        case .lossless: Strings.text("Lossless")
        case .aggressive: Strings.text("Aggressive")
        }
    }

    /// "PNG · 2.4 MB · 3024 × 1964".
    static func describe(url: URL, image: CGImage?, result: OptimisationResult?, pages: Int? = nil) -> String {
        var parts = [CompareMedia.formatName(url), Figures.bytes(AppModel.size(of: url))]
        if let pages, pages > 0 {
            parts.append(pages == 1 ? Strings.text("1 page") : Strings.format("%d pages", pages))
        } else if let image {

            parts.append("\(image.width) × \(image.height)")
        } else if let result, let width = result.width, let height = result.height {
            parts.append("\(width) × \(height)")
        }
        return parts.joined(separator: " · ")
    }

    /// "0.4 %", "12 %".
    static func share(_ fraction: Double) -> String {
        let percent = fraction * 100
        let text = percent < 10 ? String(format: "%.1f", percent) : String(Int(percent.rounded()))
        return text + Figures.space + "%"
    }
}
