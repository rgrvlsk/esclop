// SPDX-License-Identifier: GPL-3.0-or-later
//
// The cards at a screen corner: 8 pt apart, newest at the bottom, sliding in from the screen
// edge they belong to.

import EsclopCore
import SwiftUI

struct FloatingStackView: View {
    let model: AppModel
    /// The stack's size after each layout, so the panel can follow it.
    var onSize: (CGSize) -> Void = { _ in }

    var body: some View {
        let corner = model.corner
        VStack(alignment: corner.isRight ? .trailing : .leading, spacing: Metrics.stackGap) {
            ForEach(model.cards) { card in
                ResultCardView(card: card) { model.perform($0, on: card) }
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: corner.isRight ? .trailing : .leading).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
            }
        }
        .padding(Metrics.screenMargin)
        .animation(Motion.cards, value: model.cards.map(\.id))
        .fixedSize()
        .onGeometryChange(for: CGSize.self, of: \.size) { onSize($0) }
    }
}
