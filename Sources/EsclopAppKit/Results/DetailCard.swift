// SPDX-License-Identifier: GPL-3.0-or-later
//
// The floating result's second level (docs/design/targets: pr2-detail-card): the card grown to
// 320 pt. The picture, the name and the file's facts, the saving at the next size up, and the
// actions as 1 + 2 + "…": the most likely one in charcoal, two round ones beside it, the rest in a
// menu. A click, Return or Space opens it; there Return or Space runs the charcoal button; × and
// Esc close it. While the file runs again the charcoal button is Stop and the detail turns aqua.

import EsclopCore
import SwiftUI

struct DetailCard: View {
    let card: ResultCard
    let info: CardPresentation
    let corner: ScreenCorner
    let perform: (CardPresentation.Action) -> Void
    let interact: (AppModel.Interaction) -> Void

    static let pictureWidth = Metrics.detailWidth - 2 * Metrics.detailPadding
    /// The detail's picture keeps its aspect ratio within these heights, fitted whole.
    static let pictureHeights: ClosedRange<CGFloat> = 120...240
    static let closeSize: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picture(card: card, width: Self.pictureWidth, radius: Metrics.detailPictureRadius, heights: Self.pictureHeights, fits: true)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.detailPictureRadius, style: .continuous))
                .pictureHairline(Metrics.detailPictureRadius)
                .modifier(DragOut(file: card.draggableFile) { interact(.dragging(true)) })
                .overlay(alignment: corner.isRight ? .topTrailing : .topLeading) {
                    PillButton(action: .closeDetail, size: Self.closeSize, perform: perform)
                        .padding(CardFace.buttonInset - PillButton.slack(Self.closeSize))
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(info.fileName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Ink.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(facts).font(.system(size: 12)).foregroundStyle(Ink.secondary).monospacedDigit().lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.top, 10)
            CardFooter(card: card, info: info, perform: perform, large: true)
            if !info.removedMetadata.isEmpty {
                MetadataStrip(info: info, perform: perform).padding(.bottom, 8)
            }
            DetailActions(info: info, perform: perform)
        }
        .padding(Metrics.detailPadding)
        .frame(width: Metrics.detailWidth)
        .floatingSurface(Metrics.detailRadius, fill: info.surface)
        .task(id: card.result?.id) { await findRemovedMetadata() }
    }

    /// Reads the original's and the result's metadata off the main thread when a result shows.
    private func findRemovedMetadata() async {
        guard case let .done(result) = card.phase, let original = RemovedMetadata.original(of: result, origin: card.origin) else {
            card.removedMetadata = []
            return
        }
        let output = result.output
        let removed = await Task.detached(priority: .utility) {
            RemovedMetadata.between(original: original, output: output)
        }.value
        guard card.result?.id == result.id else { return }
        card.removedMetadata = removed
    }

    /// "JPEG · 4032 × 3024", "PNG → WebP · 2880 × 1800".
    private var facts: String {
        [info.formats, info.dimensions].compactMap { $0 }.joined(separator: " · ")
    }
}

/// What optimising took from the picture's metadata, and the way to keep it: "Removed", a
/// symbol per kind, the kinds in words, Restore.
struct MetadataStrip: View {
    let info: CardPresentation
    let perform: (CardPresentation.Action) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(Strings.text("Removed").uppercased(with: Strings.locale))
                .font(Typeface.caption.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(Ink.secondary)
                .fixedSize()
            // The symbols and the words when both fit; else the words, which say more; else the
            // symbols, whose tooltips name them.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { symbols; words }
                words
                symbols
            }
            Spacer(minLength: 4)
            Button(CardPresentation.Action.keepMetadata.title) { perform(.keepMetadata) }
                .font(Typeface.label.weight(.semibold))
                .foregroundStyle(Ink.text)
                .buttonStyle(.plain)
                .fixedSize()
                .help(CardPresentation.Action.keepMetadata.accessibilityName)
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(minHeight: 36)
        .background(Capsule().fill(NeutralFill.resting))
    }

    private var symbols: some View {
        HStack(spacing: 4) {
            ForEach(info.removedMetadata, id: \.self) { kind in
                Image(systemName: kind.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Ink.text)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Surface.cream))
                    .overlay(Circle().strokeBorder(Ink.secondary.opacity(0.22), lineWidth: 0.5))
            }
        }
        .fixedSize()
        .help(info.removedSummary)
    }

    private var words: some View {
        Text(info.removedSummary).font(Typeface.caption).foregroundStyle(Ink.secondary).lineLimit(1).fixedSize()
    }
}

/// 1 + 2 + "…": the charcoal button with what it acts on, up to two round buttons with their
/// names under them, and the menu for the rest.
struct DetailActions: View {
    let info: CardPresentation
    let perform: (CardPresentation.Action) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.hitGap) {
            if let primary = info.primary {
                PrimaryButton(action: primary, detail: info.primaryDetail, perform: perform)
            }
            ForEach(info.secondary, id: \.self) { action in
                VStack(spacing: 4) {
                    PillButton(action: action, size: Self.round, perform: perform)
                    Text(action.caption.uppercased(with: Strings.locale))
                        .font(Typeface.section)
                        .tracking(0.5)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
                .frame(minWidth: Self.round + 8)
            }
            if !info.menu.isEmpty {
                MoreMenu(actions: info.menu, size: Self.round, perform: perform)
            }
        }
    }

    static let round: CGFloat = 36
}

/// The detail's charcoal button: an icon, the action and what it acts on.
struct PrimaryButton: View {
    let action: CardPresentation.Action
    let detail: String?
    let perform: (CardPresentation.Action) -> Void

    var body: some View {
        Button { perform(action) } label: {
            HStack(spacing: 8) {
                Image(systemName: action.symbol).font(.system(size: 16, weight: .medium)).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title).font(.system(size: 13, weight: .semibold))
                    if let detail {
                        // Full white: 80 % held only 3.7:1 on dark charcoal.
                        Text(detail).font(Typeface.caption)
                    }
                }
                .lineLimit(1)
            }
            .foregroundStyle(Ink.onCharcoal)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Capsule().fill(Ink.charcoal))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .help(action.accessibilityName)
    }
}

/// "…": a plain menu of the actions that did not get a button, the options last.
struct MoreMenu: View {
    let actions: [CardPresentation.Action]
    let size: CGFloat
    let perform: (CardPresentation.Action) -> Void

    var body: some View {
        Menu {
            ForEach(actions, id: \.self) { action in
                Button(action.title) { perform(action) }
            }
        } label: {
            PillButton.face("ellipsis", size: size, glyph: 0.4).contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Strings.text("More options"))
        .accessibilityLabel(Strings.text("More options"))
    }
}

/// What "…" opens until the options popover lands: the file's figures and its plain actions.
struct OptionsPlaceholder: View {
    let card: ResultCard
    let info: CardPresentation
    let perform: (CardPresentation.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.fileName).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(info.change).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            Divider()
            ForEach([CardPresentation.Action.openDetail, .reveal, .copy, .dismiss], id: \.self) { action in
                Button {
                    perform(action)
                } label: {
                    Label(action.title, systemImage: action.symbol).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.body)
        .padding(16)
        .frame(width: 240)
    }
}
