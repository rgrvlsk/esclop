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
        .floatingSurface(Metrics.thumbnailRadius, fill: info.surface)
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
                        .padding(Self.buttonInset - PillButton.slack(Self.closeSize))
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

    /// A move only moves the glow; the card hears the pointer come and go.
    private func hover(_ phase: HoverPhase) {
        switch phase {
        case let .active(location):
            spot.location = location
            if !card.machine.hovering { interact(.pointerEntered) }
        case .ended:
            spot.location = nil
            interact(.pointerExited)
        }
    }
}

// MARK: - Footer

/// What the card says under its picture. One baseline in every state; the card never resizes on
/// hover. The detail card shows it larger, without the name it already shows above.
struct CardFooter: View {
    let card: ResultCard
    let info: CardPresentation
    let perform: (CardPresentation.Action) -> Void
    var large = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The ring's box, its stroke and its figure. The white dot clears the figure by 3 pt or more
    /// at every percentage (`RenderTests.theDotClearsTheFigure`).
    static let ring = (side: CGFloat(50), lineWidth: CGFloat(3), figure: Figure.Size.card.rawValue)
    /// The detail's ring, where the figure takes the next size up.
    static let largeRing = (side: CGFloat(62), lineWidth: CGFloat(5), figure: Figure.Size.detail.rawValue)
    /// The ring's place, and the symbol's.
    private var slot: CGFloat { Self.ring.side }

    var body: some View {
        Group {
            switch info.capsule {
            case let .result(before, after):
                saving(before: before, after: after)
            case .working:
                working
            case let .status(symbol, _):
                lines(mark: symbolSlot(symbol))
            case .error:
                failed
            case .notice:
                EmptyView()
            }
        }
        // The small card's ring lines up with the picture's edge, as in the target.
        .padding(.horizontal, large ? 6 : 0)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: slot + 12, alignment: .leading)
    }

    // A finished saving: the ring with the figure, the original size in brick red, the new one
    // in grey, the name as a caption. A result that grew gets the empty ring and a grey figure,
    // never the saving's teal.
    private func saving(before: Int, after: Int) -> some View {
        let saved = before > 0 ? Double(before - after) / Double(before) : 0
        let grew = after > before
        let percent = Int((abs(saved) * 100).rounded())
        let ring = large ? Self.largeRing : Self.ring
        let figure = Figure(
            number: grew ? "+\(percent)" : Figure.percentParts(percent).number, unit: "%",
            spoken: Figures.percent(before: before, after: after), size: ring.figure,
            color: grew ? AnyShapeStyle(Ink.secondary) : AnyShapeStyle(Ink.saving)
        )
        return HStack(spacing: 10) {
            ZStack {
                SavingGauge(saved: grew ? nil : saved, lineWidth: ring.lineWidth)
                figure
            }
            .frame(width: ring.side, height: ring.side)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: large ? 8 : 6) {
                    Text(Figures.bytes(before)).foregroundStyle(Ink.original)
                    Image(systemName: "arrow.right").font(.system(size: large ? 12 : 10, weight: .medium)).foregroundStyle(Ink.secondary)
                    Text(Figures.bytes(after)).foregroundStyle(Ink.secondary)
                    if card.aggressive {
                        Image(systemName: "bolt.fill").foregroundStyle(Ink.warm).help(Strings.text("Optimise harder"))
                    }
                    if let rule = card.appliedRule {
                        Image(systemName: "pin.fill").foregroundStyle(Ink.text).help(rule.tooltip())
                    }
                }
                .font(.system(size: large ? 15 : 13, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                if !large { caption(info.caption) }
            }
        }
    }

    @ViewBuilder private var working: some View {
        let stop: CardPresentation.Action = info.actions.contains(.cancelUpload) ? .cancelUpload : .stop
        if large {
            // The detail already names the file, and its charcoal button stops the work.
            VStack(alignment: .leading, spacing: 8) {
                Text(info.headline).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.text).lineLimit(1)
                WorkBar(progress: info.progress, pulses: !reduceMotion)
            }
        } else {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.headline).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.text).lineLimit(1)
                    TimelineView(.periodic(from: card.startedAt, by: 1)) { context in
                        caption(workCaption(at: context.date))
                    }
                }
                Spacer(minLength: 0)
                if info.actions.contains(stop) { PillButton(action: stop, perform: perform) }
            }
            .frame(minHeight: slot)
            .overlay(alignment: .top) { WorkBar(progress: info.progress, pulses: !reduceMotion).offset(y: -4) }
        }
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
    // A failure (docs/design/targets: pr2-failed-not-uploaded): what did not happen, with the way
    // forward beside it, and under them why, across the width, and that nothing was lost.
    private var failed: some View {
        // In the detail, the charcoal button is the way forward.
        let action: CardPresentation.Action? = large ? nil : [.retryUpload, .retry, .reveal].first(where: info.actions.contains)
        let kept = card.failure == .upload ? Strings.text("The file is kept.") : Strings.text("The original is untouched.")
        let title = HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Ink.error)
            Text(info.headline)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Ink.text)
                .lineLimit(1)
        }
        return VStack(alignment: .leading, spacing: 5) {
            if let action {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        title.fixedSize()
                        Spacer(minLength: 0)
                        TextPill(action: action, title: Self.retryTitle(action), perform: perform)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        title
                        TextPill(action: action, title: Self.retryTitle(action), perform: perform)
                    }
                }
            } else {
                title
            }
            Text("\(info.caption) \(kept)")
                .font(.system(size: 11.5))
                .foregroundStyle(Ink.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .help(info.caption)
        }
    }

    /// A failure's way forward reads "Retry", whether it optimises or uploads again.
    static func retryTitle(_ action: CardPresentation.Action) -> String? {
        action == .retry || action == .retryUpload ? Strings.text("Retry") : nil
    }

    private func lines(mark: some View) -> some View {
        HStack(spacing: 10) {
            mark.frame(width: slot, height: slot)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.headline).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.text).lineLimit(1)
                caption(info.caption)
            }
        }
    }

    /// The ring's place: the empty ring for "already optimised", else the state's symbol.
    @ViewBuilder private func symbolSlot(_ symbol: String?) -> some View {
        if let symbol {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.text)
                .frame(width: slot - 8, height: slot - 8)
                .background(Circle().fill(NeutralFill.resting))
        } else {
            SavingGauge(saved: nil, lineWidth: Self.ring.lineWidth)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.middle)
    }
}

// MARK: - Parts

/// The picture's tone, worked out once per picture and appearance, not on every redraw.
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

/// A round cream button with a symbol: the card's buttons, its close button, Stop. One drawn
/// smaller than `Spacing.hit` still takes a whole pointer target around it.
struct PillButton: View {
    let action: CardPresentation.Action
    var size: CGFloat = Metrics.toolSize
    let perform: (CardPresentation.Action) -> Void

    var body: some View {
        Button { perform(action) } label: {
            Self.face(action.symbol, size: size)
                .padding(Self.slack(size))
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .help(action.accessibilityName)
        .accessibilityLabel(action.accessibilityName)
    }

    /// How far the pointer target reaches past a button drawn `size` wide.
    static func slack(_ size: CGFloat) -> CGFloat { max(0, Spacing.hit - size) / 2 }

    /// The round face: the card's buttons and the detail's, "…" included.
    static func face(_ symbol: String, size: CGFloat, glyph: CGFloat = 0.45) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size * glyph, weight: .medium))
            .foregroundStyle(Ink.text)
            .frame(width: size, height: size)
            .background(Circle().fill(Surface.cream))
            // The rim keeps it apart from a cream or charcoal surface, not only from a picture.
            .overlay(Circle().strokeBorder(Ink.secondary.opacity(0.22), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }
}

/// A white pill with a charcoal word: Retry, Show in Finder.
struct TextPill: View {
    let action: CardPresentation.Action
    /// The words on the pill when the place says more than the action's own title: a failure's
    /// way forward is "Retry", for an upload too.
    var title: String?
    let perform: (CardPresentation.Action) -> Void

    var body: some View {
        Button { perform(action) } label: {
            Text(title ?? action.title)
                .font(.system(size: 12, weight: .semibold))
                // Always on white, so always the light appearance's charcoal.
                .foregroundStyle(Ink.charcoal)
                .environment(\.colorScheme, .light)
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

extension CardPresentation {
    /// The card's surface, and the detail's: aqua while it works or uploads, amber when it
    /// failed, else cream.
    var surface: Color {
        if case .working = capsule { return Surface.progress }
        return tone == .error ? Surface.decision : Surface.cream
    }
}
