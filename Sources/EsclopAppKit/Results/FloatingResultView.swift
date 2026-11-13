// SPDX-License-Identifier: GPL-3.0-or-later
//
// One floating result (DESIGN.md › Floating result): a ~200 pt glass thumbnail with a capsule
// pinned to its bottom edge, a row of round glass buttons above it on hover, the 320 pt detail
// card it grows into, and the activity capsule out of its side for long jobs. The machine on the
// card decides the level; this view draws it and reports what the pointer and keyboard do.

import EsclopCore
import EsclopIPC
import SwiftUI

public struct FloatingResultView: View {
    let card: ResultCard
    let corner: ScreenCorner
    let perform: (CardPresentation.Action) -> Void
    let interact: (AppModel.Interaction) -> Void
    /// Makes the options popover's model when "…" opens it.
    let options: (() -> OptionsModel)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @FocusState private var focused: Bool
    /// 0 before the result's arrival plays, 1 after: drives the capsule count-down.
    @State private var arrival: Double
    @State private var deflateTrigger = 0

    public init(
        card: ResultCard, corner: ScreenCorner = .bottomRight,
        perform: @escaping (CardPresentation.Action) -> Void, interact: @escaping (AppModel.Interaction) -> Void = { _ in },
        options: (() -> OptionsModel)? = nil
    ) {
        self.card = card
        self.options = options
        self.corner = corner
        self.perform = perform
        self.interact = interact
        _arrival = State(initialValue: card.hasPlayedArrival || card.result == nil ? 1 : 0)
    }

    public var body: some View {
        let info = card.presentation
        // One glass container per result, spacing 0: the thumbnail, its detail and the activity
        // capsule share it so they morph into each other, while the capsule and the buttons sit
        // outside it and never melt into the thumbnail.
        VStack(alignment: corner.isRight ? .trailing : .leading, spacing: Metrics.errorCapsuleGap) {
        GlassGroup(spacing: 0) {
            if case .notice = card.phase {
                NoticeCapsule(info: info)
            } else if card.machine.level == .detail {
                DetailCard(card: card, info: info, perform: perform)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.62, anchor: anchor).combined(with: .opacity))
            } else {
                thumbnailGlass(info)
                    .transition(reduceMotion ? .opacity : .scale(scale: 1.4, anchor: anchor).combined(with: .opacity))
            }
        }
        .overlay(alignment: corner.isRight ? .bottomTrailing : .bottomLeading) {
            if card.machine.level == .thumbnail, !isNotice { thumbnailControls(info) }
        }
            // An error hangs below the thumbnail, in the layout and clear of its red rim: laid
            // over the picture, the translucent capsule showed the rim through it.
            if showsErrorCapsule(info) { capsule(info) }
        }
        .animation(reduceMotion ? Motion.crossfade : Motion.detail, value: card.machine.level)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onChange(of: focused && activeState == .key) { _, value in interact(.focus(value)) }
        .onKeyPress(.escape) {
            // Innermost first: the popover, then the detail, then the result itself.
            if card.machine.menuOpen { interact(.menu(false)) } else if card.machine.level == .detail {
                interact(.closeDetail)
            } else {
                perform(.dismiss)
            }
            return .handled
        }
        // With the options popover open, Return and Space belong to it.
        .onKeyPress(.return) { card.machine.menuOpen ? .ignored : run(.openDetail, in: info) }
        .onKeyPress(.space) { card.machine.menuOpen ? .ignored : run(.openDetail, in: info) }
        .onKeyPress(characters: ["z", "c", "r"], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            switch press.characters {
            case "z": return run(.undo, in: info)
            case "c": return run(.copy, in: info)
            default: return run(.reveal, in: info)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(info.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityActions {
            ForEach(Self.actions(info, level: card.machine.level), id: \.self) { action in
                Button(action.accessibilityName) { perform(action) }
            }
        }
        .onAppear(perform: arrive)
        .onChange(of: card.result?.id) { arrive() }
    }

    /// The named actions for the level shown: an open detail offers "Hide details" in place of
    /// "Show details", so VoiceOver can close it without Esc.
    static func actions(_ info: CardPresentation, level: FloatingResultMachine.Level) -> [CardPresentation.Action] {
        guard level == .detail else { return info.actions }
        return info.actions.map { $0 == .openDetail ? .closeDetail : $0 }
    }

    private var anchor: UnitPoint {
        switch corner {
        case .bottomRight: return .bottomTrailing
        case .bottomLeft: return .bottomLeading
        case .topRight: return .topTrailing
        case .topLeft: return .topLeading
        }
    }

    // MARK: Thumbnail level

    private var isNotice: Bool {
        if case .notice = card.phase { return true }
        return false
    }

    /// The glass of the thumbnail level: the shell and, for long jobs, the activity capsule.
    @ViewBuilder private func thumbnailGlass(_ info: CardPresentation) -> some View {
        let wing = ActivityWing(card: card, info: info)
        HStack(alignment: .center, spacing: -Metrics.activityTuck) {
            if corner.isRight, showsWing { wing.transition(wingTransition) }
            shell(info).zIndex(1)
            if !corner.isRight, showsWing { wing.transition(wingTransition) }
        }
        .padding(.bottom, bottomRoom(info))
        .animation(reduceMotion ? Motion.crossfade : Motion.activity, value: showsWing)
    }

    /// The capsule on the thumbnail's bottom edge and the buttons above it, laid over the shell.
    /// The frame itself takes no clicks, so the picture under it still drags out.
    private func thumbnailControls(_ info: CardPresentation) -> some View {
        let isError = info.tone == .error
        return Color.clear
            .frame(width: Metrics.thumbnailWidth, height: shellHeight)
            .allowsHitTesting(false)
            .overlay(alignment: .bottom) {
                if !isError { capsule(info).alignmentGuide(.bottom) { $0[.bottom] - Metrics.capsuleOverhang } }
            }
            // Above the thumbnail at every corner, so the object never changes size under the pointer.
            .overlay(alignment: corner.isRight ? .topTrailing : .topLeading) {
                buttons(info).alignmentGuide(.top) { $0[.bottom] }
            }
            .padding(.bottom, bottomRoom(info))
    }

    /// Room under the thumbnail for the pinned capsule's overhang; an error capsule has its own row.
    private func bottomRoom(_ info: CardPresentation) -> CGFloat {
        info.tone == .error ? 0 : Metrics.capsuleOverhang
    }

    private func showsErrorCapsule(_ info: CardPresentation) -> Bool {
        info.tone == .error && card.machine.level == .thumbnail && !isNotice
    }

    private var shellHeight: CGFloat {
        Picture.height(for: card.thumbnail, width: Metrics.thumbnailWidth - 2 * Metrics.thumbnailPadding, range: 64...220)
            + 2 * Metrics.thumbnailPadding
    }

    private func hover(_ phase: HoverPhase) {
        switch phase {
        case .active: interact(card.machine.hovering ? .pointerMoved : .pointerEntered)
        case .ended: interact(.pointerExited)
        }
    }

    private var showsWing: Bool { card.machine.activity != .hidden }

    private var wingTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .scale(scale: 0.3, anchor: corner.isRight ? .trailing : .leading).combined(with: .opacity)
    }

    private func shell(_ info: CardPresentation) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.thumbnailRadius, style: .continuous)
        let isError = info.tone == .error
        let anchor = anchor
        return Picture(card: card, width: Metrics.thumbnailWidth - 2 * Metrics.thumbnailPadding, radius: Metrics.pictureRadius)
            .overlay { if info.isWorking && !reduceMotion { Sheen() } }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.pictureRadius, style: .continuous))
            .modifier(DragOut(file: card.draggableFile) { interact(.dragging(true)) })
            .padding(Metrics.thumbnailPadding)
            .glassSurface(shape, id: "shell-\(card.id)", rim: isError ? .red : nil)
            .overlay { if info.isWorking { ProgressRim(progress: info.progress, animated: !reduceMotion) } }
            .keyframeAnimator(initialValue: 1.0, trigger: deflateTrigger) { content, scale in
                content.scaleEffect(scale, anchor: anchor)
            } keyframes: { _ in
                CubicKeyframe(0.95, duration: 0.18)
                SpringKeyframe(1.0, duration: 0.27, spring: .init(duration: 0.27, bounce: 0.3))
            }
            .contentShape(Rectangle())
            .onContinuousHover(perform: hover)
    }

    // MARK: Capsule

    @ViewBuilder private func capsule(_ info: CardPresentation) -> some View {
        switch info.capsule {
        case let .error(title, message):
            Button { interact(.capsuleClicked) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.callout.weight(.semibold)).foregroundStyle(.red)
                    // Whole sentences: the messages are written to fit, and never end in an ellipsis.
                    Text(message).font(.subheadline).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                    Text(info.errorFooter).font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(width: Metrics.thumbnailWidth - 24, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .glassSurface(RoundedRectangle(cornerRadius: 13, style: .continuous), interactive: true)
            .help(message)
            .onContinuousHover(perform: hover)
        default:
            Button { interact(.capsuleClicked) } label: {
                capsuleLabel(info)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(minHeight: 32)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassSurface(Capsule(), interactive: true)
            .fixedSize()
            .onContinuousHover(perform: hover)
        }
    }

    @ViewBuilder private func capsuleLabel(_ info: CardPresentation) -> some View {
        let tint = info.tone == .warm ? Palette.warm : Ink.saving
        switch info.capsule {
        case let .working(text):
            Text(text).font(.callout.weight(.semibold))
        case let .result(before, after):
            HStack(spacing: 5) {
                if let rule = card.appliedRule {
                    // A clipboard rule chose this result.
                    Image(systemName: "pin.fill").font(.callout.weight(.semibold)).foregroundStyle(tint)
                        .help(rule.tooltip())
                        .accessibilityLabel(rule.tooltip())
                } else {
                    Image(systemName: "checkmark").font(.callout.weight(.semibold)).foregroundStyle(tint)
                }
                CountingResult(before: before, after: after, progress: arrival, tint: info.tone == .neutral ? .primary : tint)
            }
        case let .status(symbol, text):
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.callout.weight(.semibold)).foregroundStyle(tint)
                Text(text).font(.callout.weight(.semibold)).monospacedDigit()
            }
        case .error, .notice:
            EmptyView()
        }
    }

    // MARK: Hover buttons

    private func buttons(_ info: CardPresentation) -> some View {
        HStack(spacing: Metrics.toolGap) {
            ForEach(info.tools, id: \.self) { action in
                ToolButton(action: action) { perform(action) }
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
        // The gap down to the thumbnail belongs to the row, so crossing it keeps the hover.
        .padding(.bottom, Metrics.toolLift)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active: if !card.machine.hovering { interact(.pointerEnteredButtons) }
            case .ended: interact(.pointerExited)
            }
        }
        .opacity(card.machine.showsHoverButtons ? 1 : 0)
        .allowsHitTesting(card.machine.showsHoverButtons)
        .animation(Motion.hover, value: card.machine.showsHoverButtons)
    }

    // MARK: Behaviour

    private func run(_ action: CardPresentation.Action, in info: CardPresentation) -> KeyPress.Result {
        guard info.actions.contains(action) else { return .ignored }
        perform(action)
        return .handled
    }

    /// The result arrives: one deflate and the capsule counts down, once per card.
    private func arrive() {
        guard card.result != nil, !card.hasPlayedArrival else { return }
        card.hasPlayedArrival = true
        if reduceMotion {
            withAnimation(Motion.crossfade) { arrival = 1 }
        } else {
            deflateTrigger += 1
            withAnimation(Motion.count) { arrival = 1 }
        }
    }
}

// MARK: - Parts

/// The file's picture at its own aspect ratio, or a symbol until the thumbnail loads.
struct Picture: View {
    let card: ResultCard
    let width: CGFloat
    let radius: CGFloat
    var image: NSImage?

    init(card: ResultCard, width: CGFloat, radius: CGFloat, image: NSImage? = nil) {
        self.card = card
        self.width = width
        self.radius = radius
        self.image = image
    }

    static func height(for image: NSImage?, width: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        guard let image, image.size.width > 0 else { return (width * 0.62).rounded() }
        return min(range.upperBound, max(range.lowerBound, (width * image.size.height / image.size.width).rounded()))
    }

    var body: some View {
        let picture = image ?? card.thumbnail
        let height = Self.height(for: picture, width: width, range: 64...220)
        Group {
            if let picture {
                Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.06))
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch card.result?.kind ?? MediaKind.of(card.source) {
        case .video: return "film"
        case .pdf: return "doc.richtext"
        case .audio: return "waveform"
        default: return "photo"
        }
    }
}

/// "612 kB · −75 %", interpolating while it animates so the figures count down.
struct CountingResult: View, Animatable {
    let before: Int
    let after: Int
    var progress: Double
    let tint: Color

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let shown = Int((Double(before) + Double(after - before) * progress).rounded())
        HStack(spacing: 4) {
            Text("\(Figures.bytes(shown)) ·").font(.callout.weight(.semibold))
            Text(Figures.percent(before: before, after: after, progress: progress))
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .foregroundStyle(tint)
        }
        .monospacedDigit()
    }
}

/// A specular sheen sweeping the picture while it compresses.
struct Sheen: View {
    var body: some View {
        TimelineView(.animation) { context in
            GeometryReader { proxy in
                let width = proxy.size.width
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0), location: 0.34),
                        .init(color: .white.opacity(0.55), location: 0.5),
                        .init(color: .white.opacity(0), location: 0.59),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: width * 1.6)
                .rotationEffect(.degrees(20))
                .offset(x: -width * 1.6 + phase * width * 2.6)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The progress hairline along the glass rim. Without a fraction a short segment circles.
struct ProgressRim: View {
    var progress: Double?
    var animated: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.thumbnailRadius, style: .continuous).inset(by: 0.75)
        let style = StrokeStyle(lineWidth: 1.5, lineCap: .round)
        Group {
            if let progress {
                shape.trim(from: 0, to: max(0.02, progress)).stroke(Ink.progress, style: style)
                    .animation(.linear(duration: 0.2), value: progress)
            } else if animated {
                TimelineView(.animation) { context in
                    let start = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    ZStack {
                        shape.trim(from: start, to: min(1, start + 0.22)).stroke(Ink.progress, style: style)
                        if start + 0.22 > 1 { shape.trim(from: 0, to: start + 0.22 - 1).stroke(Ink.progress, style: style) }
                    }
                }
            } else {
                shape.trim(from: 0, to: 0.22).stroke(Ink.progress, style: style)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A round glass button in the hover row.
struct ToolButton: View {
    let action: CardPresentation.Action
    let run: () -> Void

    var body: some View {
        Button(action: run) {
            Image(systemName: action.symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: Metrics.toolSize, height: Metrics.toolSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassSurface(Circle(), interactive: true)
        .help(action.accessibilityName)
        .accessibilityLabel(action.accessibilityName)
    }
}

/// The activity capsule: out of the thumbnail's side with a ring and the time left while a long
/// job runs, then the result for two seconds before it retracts.
struct ActivityWing: View {
    let card: ResultCard
    let info: CardPresentation

    var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 38, bottomLeadingRadius: 38, bottomTrailingRadius: 15, topTrailingRadius: 15, style: .continuous
        )
        HStack(spacing: 10) {
            if let result = card.result {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Ink.saving)
                    .frame(width: 29, height: 29)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(Figures.bytes(result.bytesAfter)) · \(Figures.percent(before: result.bytesBefore, after: result.bytesAfter))")
                        .font(.body.weight(.semibold))
                    Text(Self.optimisedName(result.kind)).font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = context.date.timeIntervalSince(card.startedAt)
                    let fraction = info.progress ?? -1
                    HStack(spacing: 10) {
                        ProgressRing(progress: info.progress)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Figures.timeLeft(JobEstimate.secondsLeft(elapsed: elapsed, fraction: fraction, expected: card.expectedDuration)))
                                .font(.body.weight(.semibold))
                            Text("\(Self.kindName(MediaKind.of(card.source))) · \(Figures.bytes(card.bytesBefore))")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .padding(.leading, 18)
        .padding(.trailing, 18 + Metrics.activityTuck)
        .frame(width: Metrics.activityWidth, alignment: .leading)
        .frame(minHeight: Metrics.activityHeight)
        .glassSurface(shape, id: "wing-\(card.id)")
    }

    static func kindName(_ kind: MediaKind?) -> String {
        switch kind {
        case .video: return Strings.text("Video")
        case .pdf: return "PDF"
        case .audio: return Strings.text("Audio")
        case .image, nil: return Strings.text("Image")
        }
    }

    /// "Video optimised": whole phrases, since Catalan puts the adjective after a gendered noun.
    static func optimisedName(_ kind: MediaKind?) -> String {
        switch kind {
        case .video: return Strings.text("Video optimised")
        case .pdf: return Strings.text("PDF optimised")
        case .audio: return Strings.text("Audio optimised")
        case .image, nil: return Strings.text("Image optimised")
        }
    }
}

struct ProgressRing: View {
    var progress: Double?

    var body: some View {
        ZStack {
            Circle().stroke(Ink.progress.opacity(0.2), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.04, progress ?? 0.25))
                .stroke(Ink.progress, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: progress)
        }
        .frame(width: 26, height: 26)
        .padding(1.5)
        .accessibilityHidden(true)
    }
}

/// The pause hotkey's messages: a glass capsule with no picture.
struct NoticeCapsule: View {
    let info: CardPresentation

    var body: some View {
        if case let .notice(title, detail) = info.capsule {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

/// Lets the thumbnail be dragged into another app as the finished file. Only the picture takes
/// the drag, so the object's own state never rebuilds when it becomes draggable. Copy (⌘C) is the
/// keyboard and VoiceOver route to the same file.
struct DragOut: ViewModifier {
    let file: URL?
    var began: () -> Void = {}

    func body(content: Content) -> some View {
        if let file {
            content
                .onDrag {
                    began()
                    return NSItemProvider(contentsOf: file) ?? NSItemProvider(object: file as NSURL)
                }
                .help(Strings.text("Drag the file into another app"))
        } else {
            content
        }
    }
}
