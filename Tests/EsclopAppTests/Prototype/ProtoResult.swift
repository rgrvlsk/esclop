// SPDX-License-Identifier: GPL-3.0-or-later
//
// Prototype of the floating result: one card, the picture clean on top and a footer under it
// with the saving as the one large figure. The footer is the only place that changes.

@testable import EsclopAppKit
import SwiftUI

struct ProtoResultCard: View {
    enum State: Equatable {
        case working(progress: Double, left: String)
        case done
        case aggressive
        case ruled
        case already
        case restored
        case failed
        case failedOpen
        case uploaded
    }

    var picture: NSImage = ProtoSamples.screenshot
    var state: State = .done
    /// The pointer is over the card: the footer's right side becomes the state's buttons and
    /// the close button shows on the corner.
    var hover = false
    var size = "612 kB"
    var saving = Proto.percent(75)
    var dimmed = false
    /// Several failures share one slot.
    var failures = 1

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
                .overlay(alignment: .top) {
                    if case let .working(progress, _) = state {
                        // The one progress indicator, on the seam of picture and footer, inside
                        // the picture's corners. It belongs to the footer's frame, so nothing
                        // in the footer moves it.
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.14))
                                Capsule().fill(Color.primary.opacity(0.6)).frame(width: max(4, proxy.size.width * progress))
                            }
                        }
                        .frame(height: 2)
                        .padding(.horizontal, 10)
                        .offset(y: -1)
                    }
                }
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
        .overlay(alignment: .topLeading) {
            // The pointer's way out: on the outer corner, as Notification Center does.
            if hover {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 20)
                    .protoGlass(10)
                    .frame(width: Proto.hit, height: Proto.hit)
                    .offset(x: -8, y: -8)
                    .accessibilityLabel("Dismiss")
            }
        }
        .opacity(dimmed ? 0.6 : 1)
    }

    private var isFailed: Bool { state == .failed || state == .failedOpen }

    /// What the pointer can do in each state: every state defines its buttons.
    private var tools: [(String, String)] {
        switch state {
        case .working: return [("stop.fill", "Stop")]
        case .done, .aggressive, .ruled: return [("arrow.uturn.backward", "Undo"), ("square.on.square", "Copy"), ("ellipsis", "Options")]
        case .already: return [("square.on.square", "Copy"), ("ellipsis", "Options")]
        case .restored: return [("arrow.uturn.forward", "Optimise Again"), ("ellipsis", "Options")]
        case .uploaded: return [("link", "Copy Link"), ("ellipsis", "Options")]
        case .failed, .failedOpen: return []
        }
    }

    private func label(_ text: String) -> some View { Text(text).font(.system(size: 12, weight: .medium)) }
    private func quiet(_ text: String) -> some View { Text(text).font(.system(size: 12)).foregroundStyle(.secondary) }
    private func mark(_ symbol: String, _ color: Color = .secondary) -> some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
    }

    @ViewBuilder private var footer: some View {
        let showTools = hover && !tools.isEmpty
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch state {
            case .working:
                label("Optimising")
            case .done:
                Text(saving).font(Proto.figure(17)).foregroundStyle(Proto.saving)
            case .aggressive:
                Text(saving).font(Proto.figure(17)).foregroundStyle(Proto.saving)
                mark("bolt.fill", Proto.warm)
            case .ruled:
                Text(saving).font(Proto.figure(17)).foregroundStyle(Proto.saving)
                mark("pin.fill")
            case .already:
                label("Already optimised")
            case .restored:
                label("Original restored")
            case .failed, .failedOpen:
                mark("exclamationmark.triangle.fill", Proto.error)
                label(failures > 1 ? "\(failures) not optimised" : "Not optimised")
            case .uploaded:
                mark("link")
                label("Link copied")
            }
            Spacer(minLength: 4)
            if showTools {
                HStack(spacing: 4) {
                    ForEach(tools, id: \.0) { ProtoIconButton(symbol: $0.0, name: $0.1) }
                }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            } else {
                switch state {
                case let .working(_, left): quiet(left)
                case .done, .aggressive, .ruled, .already: quiet(size)
                case .restored: quiet("2.4 MB")
                case .uploaded: quiet(saving)
                case .failed, .failedOpen:
                    Button("Retry") {}
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(height: Proto.hit)
                        .background(Capsule().fill(Color.primary.opacity(0.14)))
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .padding(.leading, 8)
        .padding(.trailing, showTools || isFailed ? 3 : 8)
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
            .padding(.horizontal, 4)
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Proto.percent(75)).font(Proto.figure(34)).foregroundStyle(Proto.saving)
                    Spacer()
                    Text("1.8 MB saved").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .monospacedDigit()
                ProtoSplitBar(kept: 0.25)
                Text("PNG · 2940 × 1912 · metadata removed")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .padding(.top, 12)

            HStack(spacing: 8) {
                ForEach(["Undo", "Compare", "Options…"], id: \.self) { title in
                    Button(title) {}
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: Proto.hit)
                        .background(Capsule().fill(Color.primary.opacity(0.14)))
                }
            }
            .padding(.top, 12)
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
            ProtoResultCard(picture: ProtoSamples.chart, state: .working(progress: 0.62, left: "4 s"))
            ProtoResultCard(picture: ProtoSamples.photo, state: .done, size: "1.1 MB", saving: Proto.percent(54))
            ProtoResultCard(picture: ProtoSamples.screenshot, state: .done, hover: true)
        }
    }
}

/// The detail lies over its neighbours, which stay where they are and dim.
struct ProtoStackWithDetail: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: Proto.gap) {
                ProtoResultCard(picture: ProtoSamples.chart, state: .done, size: "88 kB", saving: Proto.percent(89), dimmed: true)
                ProtoResultCard(picture: ProtoSamples.photo, state: .done, size: "1.1 MB", saving: Proto.percent(54)).hidden()
                ProtoResultCard(picture: ProtoSamples.screenshot, state: .done).hidden()
            }
            ProtoDetailCard()
        }
    }
}

/// Three slots, always: failures gather in one, so the stack cannot outgrow the screen.
struct ProtoStackWithFailures: View {
    var body: some View {
        VStack(alignment: .trailing, spacing: Proto.gap) {
            ProtoResultCard(picture: ProtoSamples.chart, state: .failed, failures: 3)
            ProtoResultCard(picture: ProtoSamples.photo, state: .done, size: "1.1 MB", saving: Proto.percent(54))
            ProtoResultCard(picture: ProtoSamples.screenshot, state: .done)
        }
    }
}
