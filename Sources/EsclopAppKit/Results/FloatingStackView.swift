// SPDX-License-Identifier: GPL-3.0-or-later
//
// The floating results at a screen corner: the newest three, 8 pt apart, newest nearest the
// corner, each sliding in from the screen edge. One glass container holds them, so shapes that
// share a glass ID morph (thumbnail into detail, activity capsule out of the thumbnail).

import EsclopCore
import SwiftUI

struct FloatingStackView: View {
    let model: AppModel
    /// The stack's size after each layout, so the panel can follow it.
    var onSize: (CGSize) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let corner = model.corner
        VStack(alignment: corner.isRight ? .trailing : .leading, spacing: Metrics.stackGap) {
            ForEach(model.visibleCards) { card in
                FloatingResultView(
                    card: card, corner: corner,
                    perform: { model.perform($0, on: card) },
                    interact: { model.interact(card, $0) },
                    options: { OptionsModel(card: card, app: model) }
                )
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
        .fixedSize()
        .onGeometryChange(for: CGSize.self, of: \.size) { onSize($0) }
    }
}
