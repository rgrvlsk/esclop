// SPDX-License-Identifier: GPL-3.0-or-later
//
// Two or more failures in one place of the stack (docs/design/targets: pr2-failures): an amber
// pill, "3 not optimised" (the single card's words), that opens into their list, each with its reason and Retry,
// and Retry All and Dismiss under it. One failure keeps its own card (`CardFace`).

import AppKit
import EsclopCore
import SwiftUI

struct FailureGroup: View {
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let cards = model.failedCards
        Group {
            if model.failuresExpanded { list(cards) } else { pill(cards) }
        }
        // Gone with its last failure: the next group starts closed.
        .onDisappear { model.failuresExpanded = false }
    }

    // MARK: Closed

    private func pill(_ cards: [ResultCard]) -> some View {
        Button { expand(true) } label: {
            HStack(spacing: 8) {
                Self.triangle(size: 15)
                Text(Self.heading(cards))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Ink.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Ink.text)
            }
            .padding(.horizontal, 14)
            .frame(width: Metrics.thumbnailWidth, height: Self.pillHeight)
            .floatingSurface(Self.pillHeight / 2, fill: Surface.decision)
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(Self.heading(cards))
        .accessibilityHint(Strings.text("Shows each file and why"))
    }

    // MARK: Open

    private func list(_ cards: [ResultCard]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Self.triangle(size: 19)
                Text(Self.heading(cards))
                    .font(Typeface.smallHeading)
                    .foregroundStyle(Ink.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button { expand(false) } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Ink.text)
                        .frame(width: Spacing.hit, height: Spacing.hit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .help(Strings.text("Hide the list"))
                .accessibilityLabel(Strings.text("Hide the list"))
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(height: 54)
            .background(Surface.decision)

            rows(cards)

            Rectangle().fill(Ink.secondary.opacity(0.18)).frame(height: 0.5)
            HStack(spacing: 44) {
                if cards.contains(where: { Self.retry(for: $0) != nil }) {
                    Button(Strings.text("Retry All")) { model.retryFailures() }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Ink.charcoalText)
                }
                Button(Strings.text("Dismiss")) { model.dismissFailures() }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Ink.secondary)
                    .help(Strings.text("Remove these notices; the files stay as they are"))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .frame(width: Metrics.detailWidth)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.detailRadius, style: .continuous))
        .floatingSurface(Metrics.detailRadius)
    }

    /// The rows, scrolling past four so the list never runs off the screen.
    @ViewBuilder private func rows(_ cards: [ResultCard]) -> some View {
        let content = VStack(spacing: 0) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                if index > 0 {
                    Rectangle().fill(Ink.secondary.opacity(0.18)).frame(height: 0.5).padding(.leading, 72)
                }
                FailureRow(card: card) { model.perform($0, on: card) }
            }
        }
        if cards.count > Self.rowsShown {
            ScrollView { content }.frame(height: CGFloat(Self.rowsShown) * FailureRow.height + 0.5 * CGFloat(Self.rowsShown - 1))
        } else {
            content
        }
    }

    private func expand(_ open: Bool) {
        withAnimation(reduceMotion ? Motion.crossfade : Motion.enter) { model.failuresExpanded = open }
    }

    static let pillHeight: CGFloat = 40
    static let rowsShown = 4

    /// The heading says what did not happen, so it stays true for a mix.
    static func heading(_ cards: [ResultCard]) -> String {
        switch Set(cards.compactMap(\.failure)) {
        case [.optimise]: return Strings.format("%d not optimised", cards.count)
        case [.upload]: return Strings.format("%d not uploaded", cards.count)
        default: return Strings.format("%d failed", cards.count)
        }
    }

    /// Retry, or Upload Again, where another try can help; nil for a file that is gone.
    static func retry(for card: ResultCard) -> CardPresentation.Action? {
        let actions = card.presentation.actions
        return [CardPresentation.Action.retryUpload, .retry].first(where: actions.contains)
    }

    static func triangle(size: CGFloat) -> some View {
        Image(systemName: "exclamationmark.triangle")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Ink.error)
            .accessibilityHidden(true)
    }
}

/// One failure in the list: the picture, the name, why, and the way forward.
struct FailureRow: View {
    let card: ResultCard
    let perform: (CardPresentation.Action) -> Void

    static let height: CGFloat = 66

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(card.displayName ?? card.source.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Ink.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(reason)
            }
            Spacer(minLength: 8)
            if let action = FailureGroup.retry(for: card) {
                TextPill(action: action, title: CardFooter.retryTitle(action), perform: perform)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: Self.height)
        .accessibilityElement(children: .combine)
    }

    /// The failure's own words; a file that is gone says so, since that is what stops a retry.
    private var reason: String {
        if card.failure == .optimise, !FileManager.default.fileExists(atPath: card.source.path) {
            return Strings.text("The file was moved or deleted.")
        }
        return card.presentation.caption
    }

    @ViewBuilder private var thumbnail: some View {
        Group {
            if let picture = card.thumbnail {
                Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Ink.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .background(Rectangle().fill(NeutralFill.resting))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .pictureHairline(10)
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch MediaKind.of(card.source) {
        case .video: return "film"
        case .pdf: return "doc.richtext"
        case .audio: return "waveform"
        default: return "photo"
        }
    }
}
