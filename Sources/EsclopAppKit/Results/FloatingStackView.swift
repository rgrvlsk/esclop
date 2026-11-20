// SPDX-License-Identifier: GPL-3.0-or-later
//
// The floating results at a screen corner: the newest three, 12 pt apart, newest nearest the
// corner, each sliding in from the screen edge. The hovered or open one draws over its
// neighbours, so its glow and its detail are not covered.

import EsclopCore
import SwiftUI

struct FloatingStackView: View {
    let model: AppModel
    /// The stack's size after each layout, so the panel can follow it.
    var onSize: (CGSize) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The cards measure where they are from here (`FloatingResultView`'s pointer rest).
    static let space = "FloatingStack"

    private var menuOpen: Bool {
        model.visibleCards.contains { $0.machine.detailMenuOpen }
    }

    /// Some card's menu, options, name, loupe or drag has the keys (`FloatingResultView.keysTaken`).
    private var keysTaken: Bool {
        model.visibleCards.contains { $0.machine.menuOpen || $0.renaming || $0.loupe != nil || $0.machine.dragging }
    }

    var body: some View {
        let corner = model.corner
        VStack(alignment: corner.isRight ? .trailing : .leading, spacing: Metrics.stackGap) {
            ForEach(model.visibleCards, id: \.id) { card in
                FloatingResultView(
                    card: card, corner: corner,
                    perform: { model.perform($0, on: card) },
                    interact: { model.interact(card, $0) },
                    options: { OptionsModel(card: card, app: model) },
                    press: { model.press($0, on: card) },
                    keysTaken: keysTaken,
                    pointerKeys: EsclopSettings.cardKeysUnderPointer.value(in: model.settings)
                )
                .zIndex(card.machine.hovering || card.machine.showsHoverButtons || card.machine.level == .detail ? 1 : 0)
                .transition(
                    .asymmetric(
                        insertion: reduceMotion ? .opacity : .move(edge: corner.isRight ? .trailing : .leading).combined(with: .opacity),
                        removal: .opacity
                    )
                )
            }
            if model.groupsFailures {
                FailureGroup(model: model)
                    .transition(reduceMotion ? .opacity : .move(edge: corner.isRight ? .trailing : .leading).combined(with: .opacity))
            }
        }
        .padding(Metrics.screenMargin)
        // Room for an open "…" menu beside its detail, toward the screen.
        .padding(corner.isRight ? .leading : .trailing, menuOpen ? LiquidMenu.room : 0)
        .overlayPreferenceValue(LiquidMenuKey.self) { anchors in
            GeometryReader { proxy in
                ForEach(anchors, id: \.card.id) { anchor in
                    LiquidMenu(
                        anchor: anchor, button: proxy[anchor.button], card: proxy[anchor.frame],
                        perform: { model.perform($0, on: anchor.card) },
                        close: { model.interact(anchor.card, .menu(false)) }
                    )
                }
            }
        }
        .animation(reduceMotion ? Motion.crossfade : Motion.enter, value: model.visibleCards.map(\.id))
        .animation(reduceMotion ? Motion.crossfade : Motion.enter, value: model.groupsFailures)
        .fixedSize()
        .coordinateSpace(.named(Self.space))
        .onGeometryChange(for: CGSize.self, of: \.size) { onSize($0) }
    }
}
