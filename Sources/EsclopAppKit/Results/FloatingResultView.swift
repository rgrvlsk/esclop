// SPDX-License-Identifier: GPL-3.0-or-later
//
// One floating result (docs/design/targets/README.md › Surfaces): the card at rest
// (`CardFace`), the detail card it grows into, or a notice. The machine on the card decides the
// level; this view draws it and takes the keys and VoiceOver's actions.

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
    }

    public var body: some View {
        let info = card.presentation
        Group {
            if case .notice = card.phase {
                NoticeCapsule(info: info)
            } else if card.machine.level == .detail {
                DetailCard(card: card, info: info, corner: corner, perform: perform, interact: interact)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.62, anchor: anchor).combined(with: .opacity))
            } else {
                CardFace(
                    card: card, info: info, corner: corner, focused: focused && activeState == .key,
                    perform: perform, interact: interact, options: options
                )
                .transition(reduceMotion ? .opacity : .scale(scale: 1.4, anchor: anchor).combined(with: .opacity))
            }
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
        .onKeyPress(.return) { enter(info) }
        .onKeyPress(.space) { enter(info) }
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
    }

    /// The named actions for the level shown: an open detail offers "Hide details" in place of
    /// "Show details", so VoiceOver can close it without Esc, and everything its buttons and its
    /// "…" menu do.
    static func actions(_ info: CardPresentation, level: FloatingResultMachine.Level) -> [CardPresentation.Action] {
        guard level == .detail else { return info.actions }
        let shown = info.actions.map { $0 == .openDetail ? .closeDetail : $0 }
        let restore: [CardPresentation.Action] = info.removedMetadata.isEmpty ? [] : [.keepMetadata]
        return CardPresentation.distinct(shown + [info.primary].compactMap { $0 } + info.secondary + restore + info.menu)
    }

    private var anchor: UnitPoint {
        switch corner {
        case .bottomRight: return .bottomTrailing
        case .bottomLeft: return .bottomLeading
        case .topRight: return .topTrailing
        case .topLeft: return .topLeading
        }
    }

    /// Return and Space open the detail, and there run its charcoal button. With the options
    /// popover open they belong to it.
    private func enter(_ info: CardPresentation) -> KeyPress.Result {
        if card.machine.menuOpen { return .ignored }
        guard card.machine.level == .detail else { return run(.openDetail, in: info) }
        return info.primary.map { run($0, in: info) } ?? .ignored
    }

    private func run(_ action: CardPresentation.Action, in info: CardPresentation) -> KeyPress.Result {
        guard info.actions.contains(action) else { return .ignored }
        perform(action)
        return .handled
    }
}

// MARK: - Parts

/// The file's picture at its own aspect ratio, or a symbol until the thumbnail loads. The card
/// fills its frame; the detail fits the whole picture, on a neutral fill where it does not reach.
struct Picture: View {
    let card: ResultCard
    let width: CGFloat
    let radius: CGFloat
    var heights: ClosedRange<CGFloat> = Picture.heights
    var fits = false

    /// The card's picture keeps its aspect ratio within these heights.
    static let heights: ClosedRange<CGFloat> = 72...190

    static func height(for image: NSImage?, width: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        guard let image, image.size.width > 0 else { return (width * 0.62).rounded() }
        return min(range.upperBound, max(range.lowerBound, (width * image.size.height / image.size.width).rounded()))
    }

    var body: some View {
        let picture = card.thumbnail
        let height = Self.height(for: picture, width: width, range: heights)
        Group {
            if let picture {
                Image(nsImage: picture).resizable().aspectRatio(contentMode: fits ? .fit : .fill)
            } else {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(Ink.secondary)
            }
        }
        .frame(width: width, height: height)
        .background {
            if picture == nil || fits { Rectangle().fill(NeutralFill.resting) }
        }
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

/// The pause hotkey's messages: a cream capsule with no picture.
struct NoticeCapsule: View {
    let info: CardPresentation

    var body: some View {
        if case let .notice(title, detail) = info.capsule {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(Ink.secondary)
            }
            .foregroundStyle(Ink.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .floatingSurface(16)
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
