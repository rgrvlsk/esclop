// SPDX-License-Identifier: GPL-3.0-or-later
//
// The hovered card's halo (docs/design/targets: pr2-result-card-hover-halo): a glow in the
// picture's tone around the card, brightest near the pointer. It is the card's only hover and
// focus mark; there is no blue focus ring. The pointer's place lives in its own object that only
// this view reads, so a pointer move redraws the glow and nothing else of the card.

import Observation
import SwiftUI

/// Where the pointer is over one card, in the card's own space; nil when it is elsewhere.
@Observable @MainActor
final class PointerSpot {
    var location: CGPoint?
}

struct PointerGlow: View {
    let tone: Color
    let radius: CGFloat
    let spot: PointerSpot
    /// Brightest near the pointer. Off under Reduce Motion and for keyboard focus: one even glow.
    var follows: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                shape.stroke(tone.opacity(follows ? 0.6 : 0.85), lineWidth: 12).blur(radius: 10)
                if follows, let location = spot.location {
                    let centre = UnitPoint(x: location.x / max(size.width, 1), y: location.y / max(size.height, 1))
                    shape.stroke(
                        RadialGradient(colors: [tone, tone.opacity(0)], center: centre, startRadius: 0, endRadius: max(size.width, size.height) * 0.75),
                        lineWidth: 12
                    )
                    .blur(radius: 8)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
