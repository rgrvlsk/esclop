// SPDX-License-Identifier: GPL-3.0-or-later
//
// The floating result's second level (docs/design/targets: pr2-detail-card): the card grown to
// 320 pt. The picture, the name and the file's facts, the saving at the next size up, and the
// actions as 1 + 2 + "…": the most likely one in charcoal, two round ones beside it, the rest in a
// menu. A click, Return or Space opens it; × and Esc close it.

import EsclopCore
import SwiftUI

struct DetailCard: View {
    let card: ResultCard
    let info: CardPresentation
    let corner: ScreenCorner
    let perform: (CardPresentation.Action) -> Void
    let interact: (AppModel.Interaction) -> Void

    static let pictureWidth = Metrics.detailWidth - 2 * Metrics.detailPadding
    /// The detail's picture keeps its aspect ratio within these heights.
    static let pictureHeights: ClosedRange<CGFloat> = 120...240

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picture(card: card, width: Self.pictureWidth, radius: Metrics.detailPictureRadius, heights: Self.pictureHeights)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.detailPictureRadius, style: .continuous))
                .pictureHairline(Metrics.detailPictureRadius)
                .modifier(DragOut(file: card.draggableFile) { interact(.dragging(true)) })
                .overlay(alignment: corner.isRight ? .topTrailing : .topLeading) {
                    PillButton(action: .closeDetail, size: 24, perform: perform).padding(CardFace.buttonInset)
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
            DetailActions(info: info, perform: perform)
        }
        .padding(Metrics.detailPadding)
        .frame(width: Metrics.detailWidth)
        .floatingSurface(Metrics.detailRadius, fill: info.tone == .error ? Surface.decision : Surface.cream)
    }

    /// "JPEG · 4032 × 3024", "PNG → WebP · 2880 × 1800".
    private var facts: String {
        [info.formats, info.dimensions].compactMap { $0 }.joined(separator: " · ")
    }
}

/// 1 + 2 + "…": the charcoal button with what it acts on, up to two round buttons with their
/// names under them, and the menu for the rest.
struct DetailActions: View {
    let info: CardPresentation
    let perform: (CardPresentation.Action) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if let primary = info.primary {
                PrimaryButton(action: primary, detail: info.primaryDetail, perform: perform)
            }
            ForEach(info.secondary, id: \.self) { action in
                VStack(spacing: 4) {
                    PillButton(action: action, size: Self.round, perform: perform)
                    Text(action.title.uppercased(with: Strings.locale))
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.8)
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
                        Text(detail).font(.system(size: 11)).opacity(0.8).minimumScaleFactor(0.85)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Ink.onCharcoal)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
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
            // Drawn like the round buttons beside it.
            Image(systemName: "ellipsis")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(Ink.text)
                .frame(width: size, height: size)
                .background(Circle().fill(Surface.cream))
                .overlay(Circle().strokeBorder(Ink.secondary.opacity(0.22), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                .contentShape(Circle())
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
