// SPDX-License-Identifier: GPL-3.0-or-later
//
// The floating results at a screen corner: the newest three, 12 pt apart, newest nearest the
// corner, each sliding in from the screen edge. One glass container holds them, so shapes that
// share a glass ID morph (thumbnail into detail, activity capsule out of the thumbnail).

import EsclopCore
import SwiftUI

struct FloatingStackView: View {
    /// Room above a result for its row of round buttons, so the row never covers the result
    /// above it (its capsule, or the buttons of an open detail). At the bottom corners the room
    /// opens only while the row shows: the stack is pinned to the bottom, so the results above
    /// move away and the one under the pointer stays still. At the top corners the stack is
    /// pinned to the top and opening room would move the result under the pointer, so the room
    /// is always there. The top result uses the stack's own top padding.
    static func rowRoom(for card: ResultCard, isFirst: Bool, corner: ScreenCorner) -> CGFloat {
        guard !isFirst else { return 0 }
        let row = Metrics.toolSize + Metrics.toolLift
        if corner.isTop { return row }
        return card.machine.showsHoverButtons ? row : 0
    }

    let model: AppModel
    /// The stack's size after each layout, so the panel can follow it.
    var onSize: (CGSize) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let corner = model.corner
        VStack(alignment: corner.isRight ? .trailing : .leading, spacing: Metrics.stackGap) {
            ForEach(Array(model.visibleCards.enumerated()), id: \.element.id) { index, card in
                FloatingResultView(
                    card: card, corner: corner,
                    perform: { model.perform($0, on: card) },
                    interact: { model.interact(card, $0) },
                    options: { OptionsModel(card: card, app: model) }
                )
                .padding(.top, Self.rowRoom(for: card, isFirst: index == 0, corner: corner))
                .zIndex(card.machine.showsHoverButtons || card.machine.level == .detail ? 1 : 0)
                .transition(
                    .asymmetric(
                        insertion: reduceMotion ? .opacity : .move(edge: corner.isRight ? .trailing : .leading).combined(with: .opacity),
                        removal: .opacity
                    )
                )
            }
        }
        // Room above the top result for its row of buttons.
        .padding(.top, Metrics.toolSize + Metrics.toolLift)
        .padding(Metrics.screenMargin)
        .animation(reduceMotion ? Motion.crossfade : Motion.enter, value: model.visibleCards.map(\.id))
        .animation(reduceMotion ? nil : Motion.hover, value: model.visibleCards.map(\.machine.showsHoverButtons))
        .fixedSize()
        .onGeometryChange(for: CGSize.self, of: \.size) { onSize($0) }
    }
}
