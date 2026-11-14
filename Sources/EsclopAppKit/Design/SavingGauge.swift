// SPDX-License-Identifier: GPL-3.0-or-later
//
// A finished saving, drawn (docs/design/targets/README.md › Visual grammar): an arc or a ring
// from the original size to the new one, the saved part in `saving`, with a white dot where the
// new size is. Only a finished result gets one; work in progress is a straight bar, never a ring.
// The stroke fills the gauge's box; the dot overhangs it by 0.6 of the line width. The track is a
// hairline under the stroke (docs/design/targets: pr2-result-card-states). With nothing saved
// (already optimised, a result that grew) the track is drawn alone, without the dot.

import SwiftUI

public struct SavingGauge: View {
    public enum Shape: Sendable {
        /// A full circle around the figure (a card, the detail, a batch).
        case ring
        /// An open arc over the figure, the original size at its left end (the panel, results).
        case arc
    }

    /// The part saved, 0...1: 0.75 for "−75 %". Nil draws the empty track alone.
    public var saved: Double?
    public var shape: Shape = .ring
    public var lineWidth: CGFloat = 5

    public init(saved: Double?, shape: Shape = .ring, lineWidth: CGFloat = 5) {
        self.saved = saved
        self.shape = shape
        self.lineWidth = lineWidth
    }

    /// Where the drawing starts and how far it can go, in degrees clockwise from 3 o'clock.
    static func sweep(_ shape: Shape) -> (start: Double, span: Double) {
        switch shape {
        case .ring: (-90, 360)
        case .arc: (200, 140)
        }
    }

    /// The dot's angle for a saving.
    static func dotAngle(saved: Double, shape: Shape) -> Double {
        let (start, span) = sweep(shape)
        return start + span * min(max(saved, 0), 1)
    }

    /// The radius of the stroke's centre line in a box `side` wide: the stroke fills the box.
    static func radius(side: CGFloat, lineWidth: CGFloat) -> CGFloat { side / 2 - lineWidth / 2 }

    /// The track's width under a stroke of `lineWidth`: a hairline, never under 1 pt.
    static func trackWidth(lineWidth: CGFloat) -> CGFloat { max(1, lineWidth * 0.4) }

    /// The white dot's radius; it overhangs the stroke on both sides.
    static func dotRadius(lineWidth: CGFloat) -> CGFloat { lineWidth * 1.1 }

    public var body: some View {
        let (start, span) = Self.sweep(shape)
        GeometryReader { proxy in
            let side = min(proxy.size.width, shape == .ring ? proxy.size.height : proxy.size.width)
            let radius = Self.radius(side: side, lineWidth: lineWidth)
            let centre = CGPoint(x: proxy.size.width / 2, y: shape == .ring ? proxy.size.height / 2 : radius + lineWidth / 2)
            ZStack {
                arc(centre, radius, from: start, to: start + span)
                    .stroke(Ink.secondary.opacity(0.3), style: StrokeStyle(lineWidth: Self.trackWidth(lineWidth: lineWidth), lineCap: .round))
                if let saved {
                    let fraction = min(max(saved, 0), 1)
                    let dot = Self.dotAngle(saved: fraction, shape: shape) * .pi / 180
                    let dotSide = 2 * Self.dotRadius(lineWidth: lineWidth)
                    arc(centre, radius, from: start, to: start + span * fraction)
                        .stroke(Ink.saving, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    // A shadow, not an outline, sets the white dot off a cream card.
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                        .frame(width: dotSide, height: dotSide)
                        .position(x: centre.x + radius * cos(dot), y: centre.y + radius * sin(dot))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func arc(_ centre: CGPoint, _ radius: CGFloat, from: Double, to: Double) -> Path {
        Path { path in
            path.addArc(center: centre, radius: radius, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
        }
    }
}
