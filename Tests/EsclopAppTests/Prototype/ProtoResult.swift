// SPDX-License-Identifier: GPL-3.0-or-later
//
// Prototype of the floating result: one glass card, the picture clean on top and a footer under
// it with the saving as the one large figure. The footer is the only place that changes.

@testable import EsclopAppKit
import SwiftUI

struct ProtoResultCard: View {
    enum State: Equatable {
        case working(progress: Double, left: String)
        case done
        case hover
        case aggressive
        case already
        case restored
        case failed
        case failedOpen
        case uploaded
    }

    var picture: NSImage = ProtoSamples.screenshot
    var state: State = .done
    var size = "612 kB"
    var saving = "−75 %"

    var body: some View {
        let width = Proto.cardWidth - 2 * Proto.cardPadding
        let height = min(190, max(72, (width * picture.size.height / picture.size.width).rounded()))
        VStack(spacing: 0) {
            Image(nsImage: picture)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)
                .saturation(isFailed ? 0.15 : 1)
                .opacity(isFailed ? 0.7 : 1)
                .clipShape(RoundedRectangle(cornerRadius: Proto.pictureRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Proto.pictureRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            footer
                .frame(width: width, height: Proto.footerHeight)
            if state == .failedOpen {
                Text("This file isn’t a video L’Esclop can read. It may be damaged. The original is untouched.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: width - 12, alignment: .leading)
                    .padding(.bottom, 8)
            }
        }
        .padding(Proto.cardPadding)
        .protoGlass(Proto.cardRadius)
    }

    private var isFailed: Bool { state == .failed || state == .failedOpen }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 6) {
            switch state {
            case let .working(progress, left):
                Text("Optimising").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                Text(left).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityValue("\(Int(progress * 100)) %")
            case .done:
                Text(saving).font(Proto.figure(17)).foregroundStyle(Proto.saving)
                Spacer(minLength: 4)
                Text(size).font(.system(size: 12)).foregroundStyle(.secondary)
            case .aggressive:
                Text(saving).font(Proto.figure(17)).foregroundStyle(Proto.saving)
                Image(systemName: "bolt.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(Proto.warm)
                Spacer(minLength: 4)
                Text(size).font(.system(size: 12)).foregroundStyle(.secondary)
            case .hover:
                Text(saving).font(Proto.figure(17)).foregroundStyle(Proto.saving)
                Spacer(minLength: 4)
                HStack(spacing: 2) {
                    ProtoIconButton(symbol: "arrow.uturn.backward", name: "Undo")
                    ProtoIconButton(symbol: "square.on.square", name: "Copy")
                    ProtoIconButton(symbol: "ellipsis", name: "Options")
                }
            case .already:
                Text("Already small").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                Text(size).font(.system(size: 12)).foregroundStyle(.secondary)
            case .restored:
                Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text("Original back").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                Text("2.4 MB").font(.system(size: 12)).foregroundStyle(.secondary)
            case .failed, .failedOpen:
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Proto.error)
                Text("Not optimised").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                Button("Retry") {}
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
            case .uploaded:
                Image(systemName: "link").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text("Link copied").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                Text(saving).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .padding(.leading, 8)
        .padding(.trailing, state == .hover ? 2 : 8)
        .overlay(alignment: .top) {
            if case let .working(progress, _) = state {
                // The one progress indicator: a neutral line where picture and footer meet.
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.1))
                        Capsule().fill(Color.primary.opacity(0.55)).frame(width: max(4, proxy.size.width * progress))
                    }
                }
                .frame(height: 2)
                .offset(y: -3)
            }
        }
    }
}

/// The second level: the same card, grown. Comparison, the figure, the bar that matches the claim.
struct ProtoDetailCard: View {
    var body: some View {
        let width = Proto.detailWidth - 2 * Proto.detailPadding
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Image(nsImage: ProtoSamples.screenshot).resizable().aspectRatio(contentMode: .fill)
                Rectangle().fill(.white).frame(width: 1.5).shadow(color: .black.opacity(0.4), radius: 1.5)
                Image(systemName: "chevron.left.chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(white: 0.2))
                    .frame(width: 22, height: 28)
                    .background(Capsule().fill(.white))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            }
            .frame(width: width, height: 198)
            .clipShape(RoundedRectangle(cornerRadius: Proto.detailPictureRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Proto.detailPictureRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))

            HStack {
                Text("Original").foregroundStyle(.secondary) + Text("  2.4 MB")
                Spacer()
                Text("612 kB  ") + Text("Optimised").foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("−75 %").font(Proto.figure(30)).foregroundStyle(Proto.saving)
                    Spacer()
                    Text("1.8 MB saved").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .monospacedDigit()
                ProtoSplitBar(kept: 0.25)
                Text("PNG · 2940 × 1912 · metadata removed")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.top, 12)

            HStack(spacing: 6) {
                ForEach(["Undo", "Compare", "Options…"], id: \.self) { title in
                    Button(title) {}
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(Capsule().fill(Color.primary.opacity(0.09)))
                }
            }
            .padding(.top, 14)
        }
        .padding(Proto.detailPadding)
        .frame(width: Proto.detailWidth)
        .protoGlass(Proto.detailRadius)
    }
}

/// A message with no file: the pause hotkey.
struct ProtoNotice: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "forward.end.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text("Skipping the next copy").font(.system(size: 12, weight: .medium))
            ProtoKeys(keys: ["⌃", "⇧", "P"])
        }
        .padding(.horizontal, 12)
        .frame(height: Proto.footerHeight)
        .protoGlass(Proto.footerHeight / 2)
    }
}

/// The newest three, 8 pt apart. Nothing moves when the pointer crosses them.
struct ProtoStack: View {
    var body: some View {
        VStack(alignment: .trailing, spacing: Proto.gap) {
            ProtoResultCard(picture: ProtoSamples.photo, state: .done, size: "1.1 MB", saving: "−54 %")
            ProtoResultCard(picture: ProtoSamples.chart, state: .working(progress: 0.62, left: "4 s"))
            ProtoResultCard(picture: ProtoSamples.screenshot, state: .hover)
        }
    }
}
