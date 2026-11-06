// SPDX-License-Identifier: GPL-3.0-or-later
//
// The floating result's second level (DESIGN.md › Floating result): a 320 pt glass card grown from
// the thumbnail's corner, with a before/after comparison and a draggable divider, the deflate bar,
// the figures and the actions. It shares the thumbnail's glass ID, so one morphs into the other.

import EsclopCore
import SwiftUI

struct DetailCard: View {
    let card: ResultCard
    let info: CardPresentation
    let perform: (CardPresentation.Action) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The bar starts at the original size and contracts once the card is open.
    @State private var contracted = false

    var body: some View {
        let tint = info.tone == .warm ? Palette.warm : (info.tone == .neutral ? Color.primary : Palette.accent)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(info.detailTitle, systemImage: info.detailSymbol)
                    .font(.headline)
                    .labelStyle(DetailTitleStyle(tint: tint))
                Spacer()
                Button { perform(.closeDetail) } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Close details")
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 10)

            Comparison(card: card, width: Metrics.detailWidth - 2 * Metrics.detailPadding)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.detailPictureRadius, style: .continuous))

            HStack(alignment: .firstTextBaseline) {
                Text(info.change).font(.callout)
                Spacer(minLength: 8)
                if let percent = info.percent {
                    Text(percent)
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                        .foregroundStyle(tint)
                }
            }
            .monospacedDigit()
            .padding(.top, 12)
            .padding(.bottom, 10)

            if info.percent != nil {
                DeflateBar(end: contracted ? info.barEnd : 1, progress: nil, tint: tint, filled: true)
            }

            HStack {
                Text(info.formats)
                Spacer()
                if let dimensions = info.dimensions { Text(dimensions) }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.vertical, 10)

            if !info.detailActions.isEmpty {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(Array(stride(from: 0, to: info.detailActions.count, by: 2)), id: \.self) { index in
                        GridRow {
                            ForEach(info.detailActions[index ..< min(index + 2, info.detailActions.count)], id: \.self) { action in
                                Button(action.title) { perform(action) }
                                    .buttonStyle(CapsuleButtonStyle())
                                    .help(action.accessibilityName)
                            }
                        }
                    }
                }
            }
        }
        .padding(Metrics.detailPadding)
        .frame(width: Metrics.detailWidth)
        .glassSurface(RoundedRectangle(cornerRadius: Metrics.detailRadius, style: .continuous), id: "shell-\(card.id)")
        .onAppear {
            if reduceMotion { contracted = true } else {
                withAnimation(Motion.bar.delay(0.1)) { contracted = true }
            }
        }
    }
}

private struct DetailTitleStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

/// A capsule button on glass-coloured fill, for the detail's actions.
struct CapsuleButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.07)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.6), lineWidth: 1))
            .contentShape(Capsule())
    }
}

/// The original and the optimised picture, split by a divider the person can drag.
struct Comparison: View {
    let card: ResultCard
    let width: CGFloat
    @State private var split: CGFloat = 0.5

    var body: some View {
        let after = card.thumbnail
        let height = Picture.height(for: after, width: width, range: 120...260)
        if let before = card.originalThumbnail, card.result != nil {
            ZStack(alignment: .topLeading) {
                Picture(card: card, width: width, radius: Metrics.detailPictureRadius)
                Picture(card: card, width: width, radius: Metrics.detailPictureRadius, image: before)
                    .mask(alignment: .leading) { Rectangle().frame(width: width * split) }
                HStack {
                    tag("Original")
                    Spacer()
                    tag("Optimised")
                }
                .padding(8)
                divider(height: height)
                    .offset(x: width * split - 11.5)
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                split = min(1, max(0, value.location.x / width))
            })
            .accessibilityHidden(true)
        } else {
            Picture(card: card, width: width, radius: Metrics.detailPictureRadius)
                .frame(height: height)
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Color(white: 0.16))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.9)))
    }

    private func divider(height: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(.white).frame(width: 1, height: height).shadow(color: .black.opacity(0.5), radius: 1.5)
            Image(systemName: "chevron.left.chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color(white: 0.16))
                .frame(width: 23, height: 29)
                .background(Capsule().fill(Color.white.opacity(0.92)))
        }
        .frame(width: 23, height: height)
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
