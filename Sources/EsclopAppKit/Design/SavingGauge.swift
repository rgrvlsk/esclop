// SPDX-License-Identifier: GPL-3.0-or-later
//
// A finished saving, drawn (docs/design/targets/README.md › Visual grammar): an arc or a ring
// from the original size to the new one, the saved part in `saving`, with a white dot where the
// new size is. Only a finished result gets one; work in progress is a straight bar, never a ring.

import SwiftUI

public struct SavingGauge: View {
    public enum Shape: Sendable {
        /// A full circle around the figure (a card, the detail, a batch).
        case ring
        /// An open arc over the figure, the original size at its left end (the panel, results).
        case arc
    }

    /// The part saved, 0...1: 0.75 for "−75 %".
    public var saved: Double
    public var shape: Shape = .ring
    public var lineWidth: CGFloat = 5

    public init(saved: Double, shape: Shape = .ring, lineWidth: CGFloat = 5) {
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

    public var body: some View {
        let (start, span) = Self.sweep(shape)
        let fraction = min(max(saved, 0), 1)
        GeometryReader { proxy in
            let side = min(proxy.size.width, shape == .ring ? proxy.size.height : proxy.size.width)
            let radius = side / 2 - lineWidth
            let centre = CGPoint(x: proxy.size.width / 2, y: shape == .ring ? proxy.size.height / 2 : radius + lineWidth)
            let dot = Self.dotAngle(saved: fraction, shape: shape) * .pi / 180
            ZStack {
                arc(centre, radius, from: start, to: start + span)
                    .stroke(Ink.secondary.opacity(0.25), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                arc(centre, radius, from: start, to: start + span * fraction)
                    .stroke(Ink.saving, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(Ink.saving, lineWidth: 1.5))
                    .frame(width: lineWidth * 2.2, height: lineWidth * 2.2)
                    .position(x: centre.x + radius * cos(dot), y: centre.y + radius * sin(dot))
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
