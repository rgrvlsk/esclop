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
        /// A failure another try can fix (an upload refused, a busy file).
        case failed
        case failedOpen
        /// A failure another try cannot fix: the way out is the file.
        case unreadable
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
    var catalan = false

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
                        // The one progress indicator: wholly inside the footer, at its top
                        // edge, inside the picture's corners. Nothing in the footer moves it.
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.24))
                                Capsule().fill(Color.primary.opacity(0.7)).frame(width: max(4, proxy.size.width * progress))
                            }
                        }
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .offset(y: 2)
                    }
                }
            if state == .failedOpen {
                Text(catalan
                    ? "El servidor ha rebutjat la pujada. El fitxer optimitzat es conserva."
                    : "The server refused the upload. The optimised file is kept.")
                    .font(.system(size: 11))
                    .foregroundStyle(Proto.quiet)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: width - 12, alignment: .leading)
                    .padding(.bottom, 8)
            }
        }
        // Dimming takes the ink and the picture, never the surface.
        .opacity(dimmed ? 0.45 : 1)
        .padding(Proto.cardPadding)
        .protoGlass(Proto.cardRadius)
        .overlay(alignment: .topLeading) {
            // The pointer's way out, centred on the card's outer corner.
            if hover {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 20)
                    .protoGlass(10)
                    .frame(width: Proto.hit, height: Proto.hit)
                    .offset(x: -14, y: -14)
                    .accessibilityLabel("Dismiss")
            }
        }
    }

    private var isFailed: Bool { state == .failed || state == .failedOpen || state == .unreadable }

    /// What the pointer can do in each state: every state defines its buttons. The way back or
    /// forward (Stop, Undo, Optimise Again) is always the last one, in the same trailing slot, so
    /// a second click stays on it and Options keeps its place across the change.
    private var tools: [(String, String)] {
        switch state {
        case .working: return [("stop.fill", "Stop")]
        case .done, .aggressive, .ruled: return [("square.on.square", "Copy"), ("ellipsis", "Options"), ("arrow.uturn.backward", "Undo")]
        case .already: return [("square.on.square", "Copy"), ("ellipsis", "Options")]
        case .restored: return [("ellipsis", "Options"), ("arrow.uturn.forward", "Optimise Again")]
        case .uploaded: return [("square.on.square", "Copy Link"), ("ellipsis", "Options")]
        case .failed, .failedOpen, .unreadable: return []
        }
    }

    private func label(_ text: String) -> some View { Text(text).font(.system(size: 12, weight: .medium)) }
    private func quiet(_ text: String) -> some View { Text(text).font(.system(size: 12)).foregroundStyle(Proto.quiet) }
    private func mark(_ symbol: String, _ color: Color = Proto.quiet) -> some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
    }

    private var footer: some View {
        let showTools = hover && !tools.isEmpty
        // One baseline for every state: text sits on it, and the buttons lie over the right
        // side without taking part in the layout, so hover moves nothing.
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch state {
            case .working:
                label(catalan ? "S’està optimitzant" : "Optimising")
            case .done:
                Text(saving).font(Proto.figure(17)).foregroundStyle(Proto.saving)
            case .aggressive:
                Text(saving).font(Proto.figure(17)).foregroundStyle(Proto.saving)
                mark("bolt.fill", Proto.warm)
            case .ruled:
                Text(saving).font(Proto.figure(17)).foregroundStyle(Proto.saving)
                mark("pin.fill")
            case .already:
                label(catalan ? "Ja estava optimitzat" : "Already optimised")
            case .restored:
                label(catalan ? "Original recuperat" : "Original restored")
            case .failed, .failedOpen, .unreadable:
                mark("exclamationmark.triangle.fill", Proto.error)
                // The label says what did not happen: an upload, or the optimising itself.
                label(failures > 1
                    ? (catalan ? "\(failures) han fallat" : "\(failures) failed")
                    : state == .unreadable
                        ? (catalan ? "No optimitzat" : "Not optimised")
                        : (catalan ? "No s’ha pujat" : "Not uploaded"))
            case .uploaded:
                mark("link")
                label(catalan ? "Enllaç copiat" : "Link copied")
            }
            Spacer(minLength: 4)
            Group {
                switch state {
                case let .working(_, left): quiet(left)
                case .done, .aggressive, .ruled, .already: quiet(catalan ? size.replacingOccurrences(of: ".", with: ",") : size)
                case .restored: quiet(catalan ? "2,4 MB" : "2.4 MB")
                case .uploaded: quiet(saving)
                case .failed, .failedOpen, .unreadable: Text(" ").font(.system(size: 12))
                }
            }
            .opacity(showTools ? 0 : 1)
        }
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 8)
        .overlay(alignment: .trailing) {
            HStack(spacing: 4) {
                if showTools {
                    ForEach(tools, id: \.0) { ProtoIconButton(symbol: $0.0, name: $0.1) }
                } else if state == .unreadable {
                    ProtoIconButton(symbol: "folder", name: "Show in Finder")
                } else if isFailed {
                    Button(catalan ? "Torna-hi" : "Retry") {}
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(height: Proto.hit)
                        .background(Capsule().fill(Color.primary.opacity(0.14)))
                }
            }
            .padding(.trailing, 3)
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
                Text("Original").foregroundStyle(Proto.quiet) + Text("  2.4 MB")
                Spacer()
                Text("612 kB  ") + Text("Optimised").foregroundStyle(Proto.quiet)
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .padding(.horizontal, 4)
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Proto.percent(75)).font(Proto.figure(34)).foregroundStyle(Proto.saving)
                    Spacer()
                    Text("1.8 MB saved").font(.system(size: 13)).foregroundStyle(Proto.quiet)
                }
                .monospacedDigit()
                ProtoSplitBar(kept: 0.25)
                Text("PNG · 2940 × 1912 · metadata removed")
                    .font(.system(size: 11))
                    .foregroundStyle(Proto.quiet)
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
            Image(systemName: "forward.end.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Proto.quiet)
            Text("The next copy won’t be optimised").font(.system(size: 12, weight: .medium)).foregroundStyle(Proto.ink)
            ProtoKeys(keys: ["⌃", "⇧", "P"])
        }
        .padding(.horizontal, 12)
        .frame(height: Proto.footerHeight)
        .protoGlass(Proto.footerHeight / 2, small: true)
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
    var catalan = false
    var body: some View {
        VStack(alignment: .trailing, spacing: Proto.gap) {
            ProtoResultCard(picture: ProtoSamples.chart, state: .failed, failures: 3, catalan: catalan)
            ProtoResultCard(picture: ProtoSamples.photo, state: .done, size: "1.1 MB", saving: Proto.percent(54), catalan: catalan)
            ProtoResultCard(picture: ProtoSamples.screenshot, state: .done, catalan: catalan)
        }
    }
}
