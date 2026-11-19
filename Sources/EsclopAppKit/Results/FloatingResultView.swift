// SPDX-License-Identifier: GPL-3.0-or-later
//
// One floating result (docs/design/targets/README.md › Surfaces): the card at rest
// (`CardFace`), the detail card it grows into, or a notice. The machine on the card decides the
// level; this view draws it and takes the keys and VoiceOver's actions. The card keys
// (`CardKeys`: ⌘ and a key, Space alone) work on the card with the keys and on the card the
// pointer rests on.

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
    /// Runs a card key (`CardKeys`); false when it does nothing on this card.
    let press: (Character) -> Bool
    /// A menu, the options, a name, the loupe or a drag on any card has the keys: the card keys
    /// stand aside on every card.
    let keysTaken: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @FocusState private var focused: Bool
    /// Whether the pointer moved onto the card or its detail (the card's own hover ends with the
    /// card face).
    @State private var rest = PointerRest()

    public init(
        card: ResultCard, corner: ScreenCorner = .bottomRight,
        perform: @escaping (CardPresentation.Action) -> Void, interact: @escaping (AppModel.Interaction) -> Void = { _ in },
        options: (() -> OptionsModel)? = nil, press: @escaping (Character) -> Bool = { _ in false }, keysTaken: Bool = false
    ) {
        self.card = card
        self.options = options
        self.corner = corner
        self.perform = perform
        self.interact = interact
        self.press = press
        self.keysTaken = keysTaken
    }

    public var body: some View {
        let info = card.presentation
        Group {
            if case .notice = card.phase {
                NoticeCapsule(info: info, perform: perform)
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
        // Screen points: the panel and the stack move the card, the pointer only moves itself.
        .onContinuousHover { phase in
            if case .active = phase { rest.pointer(at: NSEvent.mouseLocation) } else { rest.reset() }
        }
        // A card that comes or moves under a still pointer hears no leave, and one that appears
        // under a parked pointer has not been pointed at: neither takes the keys until the
        // pointer moves on it. Measured from the stack's anchored corner, which stays put on the
        // screen while the panel and the stack grow and shrink, and from the card's own corner on
        // that side, which stays put while its detail opens.
        .onGeometryChange(for: CGPoint.self, of: { proxy in
            guard let stack = proxy.bounds(of: .named(FloatingStackView.space)) else { return .zero }
            return CGPoint(
                x: corner.isRight ? stack.maxX - proxy.size.width : stack.minX,
                y: corner.isTop ? stack.minY : stack.maxY - proxy.size.height
            )
        }) { _ in rest.reset() }
        // The resting pointer's keys: held after a short rest, given back when it leaves, and
        // while a menu, the name, the loupe or a drag has the keys.
        .task(id: hoverKeys) {
            // The rest is for a pointer arriving; a card that changed under it keeps its keys.
            let arriving = HoverKeys.shared.owner != card.id
            HoverKeys.shared.release(from: card.id)
            let keys = hoverKeys
            guard !keys.isEmpty else { return }
            if arriving { try? await Task.sleep(for: HoverKeys.rest) }
            // A field of this app's being typed in (Settings) keeps its letters. ponytail: not
            // retried when the field is left; the keys come with the pointer's next arrival.
            guard !Task.isCancelled, !Self.editingText else { return }
            HoverKeys.shared.hold(keys, for: card.id) { _ = press($0) }
        }
        .onDisappear { HoverKeys.shared.release(from: card.id) }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onChange(of: focused && activeState == .key) { _, value in interact(.focus(value)) }
        // "Go to the newest result": the keys come to this card, and VoiceOver's cursor with
        // them where it follows the keyboard focus; where it does not, VoiceOver says the card.
        // ponytail: no AccessibilityFocusState; it stops ImageRenderer drawing the card.
        .onChange(of: card.wantsFocus, initial: true) { _, wants in
            guard wants else { return }
            card.wantsFocus = false
            focused = true
            AccessibilityNotification.Announcement(info.accessibilityLabel).post()
        }
        // The detail's "…" menu takes the keys while open; they come back here when it closes.
        .onChange(of: card.machine.menuOpen) { _, open in
            if !open, card.machine.level == .detail { focused = true }
        }
        // A click that opens the detail gives it the keys too, so Space and ⌘C work there at once.
        .onChange(of: card.machine.level) { _, level in
            if level == .detail { focused = true }
        }
        // And after the name was edited.
        .onChange(of: card.renaming) { _, renaming in
            if !renaming, card.machine.level == .detail { focused = true }
        }
        .onKeyPress(.escape) {
            // The detail's name being edited takes its own keys.
            if Self.editingText { return .ignored }
            // Innermost first: the popover, then the detail, then the keys the hotkey lent (back to
            // the app in front), then the result itself.
            if card.machine.menuOpen { interact(.menu(false)) } else if card.machine.level == .detail {
                interact(.closeDetail)
            } else if card.lentKeys {
                interact(.returnKeys)
            } else {
                perform(.dismiss)
            }
            return .handled
        }
        .onKeyPress(.return) { Self.editingText ? .ignored : enter(info) }
        .onKeyPress(phases: .down) { key in
            if Self.editingText || keysTaken { return .ignored }
            let modifiers = key.modifiers.subtracting([.capsLock, .numericPad])
            guard key.characters.count == 1, let character = key.characters.first?.lowercased().first else { return .ignored }
            // ⌘R stays Show in Finder here, beside Clop's ⌘F.
            if modifiers == .command, character == "r" { return run(.reveal, in: info) }
            guard modifiers == (CardKeys.needsCommand(character) ? .command : []) else { return .ignored }
            return press(character) ? .handled : .ignored
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(info.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityActions {
            ForEach(Self.actions(info, level: card.machine.level), id: \.self) { action in
                Button(action.accessibilityName) { perform(action) }
            }
            if CardKeys.command(for: " ", on: card) != nil {
                Button(Strings.text("Quick Look")) { _ = press(" ") }
            }
        }
    }

    /// The named actions for the level shown: an open detail offers "Hide details" in place of
    /// "Show details", so VoiceOver can close it without Esc, and everything its buttons and its
    /// "…" menu do.
    static func actions(_ info: CardPresentation, level: FloatingResultMachine.Level) -> [CardPresentation.Action] {
        guard level == .detail else { return info.actions }
        let shown = info.actions.map { $0 == .openDetail ? .closeDetail : $0 }
        let restore: [CardPresentation.Action] = info.restorable && !info.removedMetadata.isEmpty ? [.keepMetadata] : []
        return CardPresentation.distinct(shown + [info.primary].compactMap { $0 } + info.secondary + restore + info.editing + info.menu)
    }

    private var anchor: UnitPoint {
        switch corner {
        case .bottomRight: return .bottomTrailing
        case .bottomLeft: return .bottomLeading
        case .topRight: return .topTrailing
        case .topLeft: return .topLeading
        }
    }

    /// A text field has the keys (the detail's name being renamed): Return, Space, Esc and the
    /// ⌘ keys are its own, not the card's.
    static var editingText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.isFieldEditor == true
    }

    /// The keys the resting pointer holds for this card now: none while the pointer is away, or
    /// while the options, the "…" menu, the name, the loupe or a drag take keys of their own.
    private var hoverKeys: [Character] {
        guard rest.moved, !keysTaken else { return [] }
        return CardKeys.keys(on: card)
    }

    /// Return opens the detail, and there runs its charcoal button. With the options popover
    /// open it belongs to the popover. Space is Quick Look (`CardKeys`), as in Finder and Clop.
    private func enter(_ info: CardPresentation) -> KeyPress.Result {
        if card.machine.menuOpen { return .ignored }
        if case .notice = card.phase { return run(.optimiseAnyway, in: info) }
        guard card.machine.level == .detail else { return run(.openDetail, in: info) }
        return info.primary.map { run($0, in: info) } ?? .ignored
    }

    private func run(_ action: CardPresentation.Action, in info: CardPresentation) -> KeyPress.Result {
        guard info.actions.contains(action) else { return .ignored }
        perform(action)
        return .handled
    }
}

/// Tells a pointer that moved onto a card from a card that came to a still pointer: only the
/// first takes the card keys (a parked pointer must not take ⌘Z from the app in front).
struct PointerRest: Equatable {
    private var start: CGPoint?
    private(set) var moved = false

    /// The pointer is inside, at `point` on the screen.
    mutating func pointer(at point: CGPoint) {
        if let start {
            if point != start { moved = true }
        } else {
            start = point
        }
    }

    /// It left, or the card moved under it: it has to move on the card again.
    mutating func reset() { self = PointerRest() }
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
                Image(systemName: Self.symbol(for: card.result?.kind ?? MediaKind.of(card.source)))
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

    /// The stand-in until the thumbnail loads, by kind (the menu panel's rows use it too).
    static func symbol(for kind: MediaKind?) -> String {
        switch kind {
        case .video: return "film"
        case .pdf: return "doc.richtext"
        case .audio: return "waveform"
        default: return "photo"
        }
    }
}

/// The pause hotkey's messages: a cream capsule with no picture. A watched folder's "too many
/// at once" adds its one action under the words.
struct NoticeCapsule: View {
    let info: CardPresentation
    var perform: (CardPresentation.Action) -> Void = { _ in }

    var body: some View {
        if case let .notice(title, detail) = info.capsule {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(Ink.secondary)
                if info.actions.contains(.optimiseAnyway) {
                    // The most likely action, in charcoal, as the detail card's is.
                    Button { perform(.optimiseAnyway) } label: {
                        Text(CardPresentation.Action.optimiseAnyway.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Ink.onCharcoal)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 28)
                            .background(Capsule().fill(Ink.charcoal))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressScale())
                    .padding(.top, 8)
                }
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
