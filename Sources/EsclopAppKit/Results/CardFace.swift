// SPDX-License-Identifier: GPL-3.0-or-later
//
// One result at rest (docs/design/targets: pr2-result-card-states, pr2-progress-vs-saving): the
// picture on top at its own aspect ratio, a footer under it in the same cream surface. Only the
// footer changes with the state. Work in progress tints the card aqua and runs a straight bar;
// a finished saving gets the ring; a failure tints it amber. On hover three round buttons lie
// over the picture's corner and a close button over its outer top corner, so nothing moves.

import EsclopCore
import SwiftUI

struct CardFace: View {
    let card: ResultCard
    let info: CardPresentation
    let corner: ScreenCorner
    /// Keyboard focus is on the card (and its panel is key).
    let focused: Bool
    let perform: (CardPresentation.Action) -> Void
    let interact: (AppModel.Interaction) -> Void
    let options: (() -> OptionsModel)?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spot = PointerSpot()
    @State private var tones = ToneMemo()

    static let pictureWidth = Metrics.thumbnailWidth - 2 * Metrics.thumbnailPadding

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.thumbnailRadius, style: .continuous)
        let showsButtons = card.machine.showsHoverButtons
        VStack(spacing: 0) {
            picture(showsButtons: showsButtons)
            CardFooter(card: card, info: info, perform: perform)
        }
        .padding(Metrics.thumbnailPadding)
        .frame(width: Metrics.thumbnailWidth)
        .floatingSurface(Metrics.thumbnailRadius, fill: fill)
        .background {
            if lit, let tone = card.thumbnail.flatMap({ tones.tone(of: $0, dark: scheme == .dark) }) {
                PointerGlow(tone: tone, radius: Metrics.thumbnailRadius, spot: spot, follows: !reduceMotion && card.machine.hovering)
            }
        }
        .overlay {
            if focused {
                shape.inset(by: 2).strokeBorder(Ink.text, lineWidth: 2).allowsHitTesting(false)
            }
        }
        .contentShape(shape)
        .onTapGesture { if info.actions.contains(.openDetail) { perform(.openDetail) } }
        .onContinuousHover(perform: hover)
    }

    /// The glow shows while the card is hovered or has keyboard focus.
    private var lit: Bool { card.machine.hovering || focused }

    private var fill: Color {
        if case .working = info.capsule { return Surface.progress }
        return info.tone == .error ? Surface.decision : Surface.cream
    }

    // MARK: Picture

    private func picture(showsButtons: Bool) -> some View {
        Picture(card: card, width: Self.pictureWidth, radius: Metrics.pictureRadius)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.pictureRadius, style: .continuous))
            .pictureHairline(Metrics.pictureRadius)
            .modifier(DragOut(file: card.draggableFile) { interact(.dragging(true)) })
            .overlay(alignment: .bottomTrailing) {
                if !info.tools.isEmpty {
                    tools.padding(Self.buttonInset)
                        .opacity(showsButtons ? 1 : 0)
                        .allowsHitTesting(showsButtons)
                        .animation(Motion.hover, value: showsButtons)
                }
            }
            .overlay(alignment: corner.isRight ? .topTrailing : .topLeading) {
                if showsClose {
                    PillButton(action: .dismiss, size: Self.closeSize, perform: perform)
                        .padding(Self.buttonInset)
                        .transition(.opacity)
                }
            }
            .animation(Motion.hover, value: showsClose)
    }

    private var showsClose: Bool { card.machine.hovering && card.machine.level == .thumbnail && info.actions.contains(.dismiss) }

    static let buttonInset: CGFloat = 6
    static let buttonGap: CGFloat = 4
    static let closeSize: CGFloat = 20

    private var tools: some View {
        HStack(spacing: Self.buttonGap) {
            ForEach(info.tools, id: \.self) { action in
                PillButton(action: action, perform: perform)
                    .popover(
                        isPresented: Binding(
                            get: { action == .more && card.machine.menuOpen },
                            set: { if !$0 { interact(.menu(false)) } }
                        ),
                        arrowEdge: corner.isTop ? .top : .bottom
                    ) {
                        if let options {
                            OptionsPopover(model: options(), arrowAtBottom: !corner.isTop)
                        } else {
                            OptionsPlaceholder(card: card, info: info, perform: perform)
                        }
                    }
            }
        }
    }

    /// Where the round buttons lie, in the card's space: resting there never opens the detail.
    private func onButtons(_ point: CGPoint) -> Bool {
        let inset = Metrics.thumbnailPadding + Self.buttonInset
        let count = CGFloat(info.tools.count)
        let width = count * Metrics.toolSize + max(0, count - 1) * Self.buttonGap
        let pictureBottom = Metrics.thumbnailPadding + Picture.height(for: card.thumbnail, width: Self.pictureWidth, range: Picture.heights)
        let tools = CGRect(x: Metrics.thumbnailWidth - inset - width, y: pictureBottom - Self.buttonInset - Metrics.toolSize, width: width, height: Metrics.toolSize)
        let closeX = corner.isRight ? Metrics.thumbnailWidth - inset - Self.closeSize : inset
        let close = CGRect(x: closeX, y: inset, width: Self.closeSize, height: Self.closeSize)
        return tools.contains(point) || close.contains(point)
    }

    private func hover(_ phase: HoverPhase) {
        switch phase {
        case let .active(location):
            spot.location = location
            if card.machine.showsHoverButtons, onButtons(location) {
                interact(.pointerEnteredButtons)
            } else {
                interact(card.machine.hovering ? .pointerMoved : .pointerEntered)
            }
        case .ended:
            spot.location = nil
            interact(.pointerExited)
        }
    }
}

// MARK: - Footer

/// What the card says under its picture. One baseline in every state; the card never resizes on
/// hover.
struct CardFooter: View {
    let card: ResultCard
    let info: CardPresentation
    let perform: (CardPresentation.Action) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let slot: CGFloat = 48
    /// A result that grew: its figure in the secondary ink, never the saving's teal.
    static let neutral = Color(nsColor: Palette.dynamic(light: 0x625C56, dark: 0xB9AFA5))

    var body: some View {
        Group {
            switch info.capsule {
            case let .result(before, after):
                saving(before: before, after: after)
            case .working:
                working
            case let .status(symbol, _):
                lines(slot: symbolSlot(info.headline == Strings.text("Already optimised") ? nil : symbol))
            case .error:
                failed
            case .notice:
                EmptyView()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: Self.slot + 12, alignment: .leading)
    }

    // A finished saving: the ring with the figure, the original size in brick red, the new one
    // in grey, the name as a caption.
    private func saving(before: Int, after: Int) -> some View {
        let saved = before > 0 ? Double(before - after) / Double(before) : 0
        let grew = after > before
        let percent = Int((abs(saved) * 100).rounded())
        let figure = Figure(
            number: grew ? "+\(percent)" : Figure.percentParts(percent).number, unit: "%",
            spoken: Figures.percent(before: before, after: after), size: 16,
            color: grew ? Self.neutral : Ink.saving
        )
        return HStack(spacing: 10) {
            ZStack {
                if grew { emptyRing } else { SavingGauge(saved: saved, lineWidth: 4) }
                figure
            }
            .frame(width: Self.slot, height: Self.slot)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(Figures.bytes(before)).foregroundStyle(Ink.original)
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.secondary)
                    Text(Figures.bytes(after)).foregroundStyle(Ink.secondary)
                    if card.aggressive {
                        Image(systemName: "bolt.fill").foregroundStyle(Ink.warm).help(Strings.text("Optimise harder"))
                    }
                    if let rule = card.appliedRule {
                        Image(systemName: "pin.fill").foregroundStyle(Ink.text).help(rule.tooltip())
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                caption(info.caption)
            }
        }
    }

    private var working: some View {
        let stop: CardPresentation.Action = info.actions.contains(.cancelUpload) ? .cancelUpload : .stop
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.headline).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.text).lineLimit(1)
                TimelineView(.periodic(from: card.startedAt, by: 1)) { context in
                    caption(workCaption(at: context.date))
                }
            }
            Spacer(minLength: 0)
            if info.actions.contains(stop) { PillButton(action: stop, perform: perform) }
        }
        .frame(minHeight: Self.slot)
        .overlay(alignment: .top) { WorkBar(progress: info.progress, pulses: !reduceMotion).offset(y: -4) }
    }

    /// "Beach.jpg · 40 %", or the time left for a job expected to take more than two seconds.
    private func workCaption(at date: Date) -> String {
        guard info.actions.contains(.stop) else { return info.caption }
        if card.expectedDuration > 2 {
            let left = JobEstimate.secondsLeft(elapsed: date.timeIntervalSince(card.startedAt), fraction: info.progress ?? -1, expected: card.expectedDuration)
            return info.caption + " · " + Figures.timeLeft(left)
        }
        guard let progress = info.progress else { return info.caption }
        return info.caption + " · " + "\(Int((progress * 100).rounded()))" + Figures.space + "%"
    }

    /// The triangle, what did not happen and why, and the one way forward. The pill sits beside
    /// the words when they fit ("Retry"), under them when they do not ("Upload Again").
    private var failed: some View {
        let action: CardPresentation.Action? = [.retryUpload, .retry, .reveal].first(where: info.actions.contains)
        let words = VStack(alignment: .leading, spacing: 2) {
            Text(info.headline).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.text).lineLimit(1)
            Text(info.caption)
                .font(.system(size: 11)).foregroundStyle(Ink.text)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .help(info.caption)
        }
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Ink.error)
                .frame(width: Self.slot, height: Self.slot)
            if let action {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        words.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        TextPill(action: action, perform: perform)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        words
                        TextPill(action: action, perform: perform)
                    }
                }
            } else {
                words
            }
        }
    }

    private func lines(slot: some View) -> some View {
        HStack(spacing: 10) {
            slot.frame(width: Self.slot, height: Self.slot)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.headline).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.text).lineLimit(1)
                caption(info.caption)
            }
        }
    }

    /// The ring's place: an empty ring for "already optimised", else the state's symbol.
    @ViewBuilder private func symbolSlot(_ symbol: String?) -> some View {
        if let symbol {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.text)
                .frame(width: Self.slot - 8, height: Self.slot - 8)
                .background(Circle().fill(NeutralFill.resting))
        } else {
            emptyRing
        }
    }

    private var emptyRing: some View {
        Circle().inset(by: 2).stroke(Ink.secondary.opacity(0.25), lineWidth: 4)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.middle)
    }
}

// MARK: - Parts

/// The picture's tone, worked out once per picture and appearance: the card's body runs on every
/// pointer move while it is hovered.
@MainActor
final class ToneMemo {
    private var key: (ObjectIdentifier, Bool)?
    private var value: Color?

    func tone(of image: NSImage, dark: Bool) -> Color? {
        if let key, key.0 == ObjectIdentifier(image), key.1 == dark { return value }
        key = (ObjectIdentifier(image), dark)
        value = PictureTone.of(image, dark: dark)
        return value
    }
}

/// The straight 4 pt bar of work in progress. Without a fraction it pulses, still under Reduce
/// Motion. Progress is never a ring.
struct WorkBar: View {
    var progress: Double?
    var pulses: Bool
    @State private var dim = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.progress.opacity(0.22))
                Capsule().fill(Ink.progress)
                    .frame(width: proxy.size.width * min(1, max(0.03, progress ?? 1)))
                    .opacity(progress == nil ? (dim ? 0.35 : 0.8) : 1)
                    .animation(.linear(duration: 0.2), value: progress)
            }
        }
        .frame(height: 4)
        .onAppear {
            guard pulses, progress == nil else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityHidden(true)
    }
}

/// A round cream button with a symbol: the card's buttons, its close button, Stop.
struct PillButton: View {
    let action: CardPresentation.Action
    var size: CGFloat = Metrics.toolSize
    let perform: (CardPresentation.Action) -> Void

    var body: some View {
        Button { perform(action) } label: {
            Image(systemName: action.symbol)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(Ink.text)
                .frame(width: size, height: size)
                .background(Circle().fill(Surface.cream))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .help(action.accessibilityName)
        .accessibilityLabel(action.accessibilityName)
    }
}

/// A white pill with a charcoal word: Retry, Show in Finder.
struct TextPill: View {
    let action: CardPresentation.Action
    let perform: (CardPresentation.Action) -> Void

    var body: some View {
        Button { perform(action) } label: {
            Text(action.title)
                .font(.system(size: 12, weight: .semibold))
                // Always on white, so always charcoal.
                .foregroundStyle(Color(nsColor: Palette.color(0x36322E)))
                .padding(.horizontal, 12)
                .frame(minHeight: Metrics.toolSize)
                .background(Capsule().fill(Color.white.opacity(0.92)))
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .fixedSize()
        .accessibilityLabel(action.accessibilityName)
    }
}

/// Tactile press: 96 %.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
