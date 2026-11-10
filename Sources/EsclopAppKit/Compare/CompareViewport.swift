// SPDX-License-Identifier: GPL-3.0-or-later
//
// The arithmetic of the compare canvas: how large the picture is drawn (fit, or a zoom where
// 100 % is one image pixel per screen pixel), how far it may be panned, and where the split
// divider sits. Both sides share one viewport, so pan and zoom stay in step.

import CoreGraphics

public struct CompareViewport: Equatable, Sendable {
    /// Image pixels per screen pixel; nil fits the whole picture.
    public var zoom: Double?
    /// Offset of the picture's centre from the viewport's centre, in points.
    public var pan: CGSize = .zero
    /// Where the divider sits, 0 (left edge) to 1 (right edge).
    public var split: Double = 0.5

    public init(zoom: Double? = nil, pan: CGSize = .zero, split: Double = 0.5) {
        self.zoom = zoom
        self.pan = pan
        self.split = split
    }

    /// The zoom steps past "fit": 100 %, 200 %, 400 %, 800 %.
    public static let steps: [Double] = [1, 2, 4, 8]

    /// Points per image pixel that fit `pixels` inside `viewport`.
    public static func fitScale(pixels: CGSize, in viewport: CGSize) -> CGFloat {
        guard pixels.width > 0, pixels.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        return min(viewport.width / pixels.width, viewport.height / pixels.height)
    }

    /// Points per image pixel for this viewport.
    public func scale(pixels: CGSize, in viewport: CGSize, displayScale: CGFloat) -> CGFloat {
        guard let zoom else { return Self.fitScale(pixels: pixels, in: viewport) }
        return CGFloat(zoom) / max(displayScale, 1)
    }

    /// The zoom the picture is shown at, as image pixels per screen pixel (for "100 %").
    public func effectiveZoom(pixels: CGSize, in viewport: CGSize, displayScale: CGFloat) -> Double {
        Double(scale(pixels: pixels, in: viewport, displayScale: displayScale) * max(displayScale, 1))
    }

    /// The next step up from what is shown now.
    public mutating func zoomIn(pixels: CGSize, in viewport: CGSize, displayScale: CGFloat) {
        let now = effectiveZoom(pixels: pixels, in: viewport, displayScale: displayScale)
        zoom = Self.steps.first { $0 > now + 0.001 } ?? Self.steps.last
    }

    /// The next step down; below the smallest step the picture fits again.
    public mutating func zoomOut(pixels: CGSize, in viewport: CGSize, displayScale: CGFloat) {
        let now = effectiveZoom(pixels: pixels, in: viewport, displayScale: displayScale)
        let fitZoom = Double(Self.fitScale(pixels: pixels, in: viewport) * max(displayScale, 1))
        if let lower = Self.steps.last(where: { $0 < now - 0.001 }), lower > fitZoom {
            zoom = lower
        } else {
            fit(pixels: pixels)
        }
        pan = clamped(pan, pixels: pixels, in: viewport, displayScale: displayScale)
    }

    public mutating func fit(pixels _: CGSize = .zero) {
        zoom = nil
        pan = .zero
    }

    /// Keeps the picture covering the viewport where it can: no panning past its edges.
    public func clamped(_ pan: CGSize, pixels: CGSize, in viewport: CGSize, displayScale: CGFloat) -> CGSize {
        let s = scale(pixels: pixels, in: viewport, displayScale: displayScale)
        let maxX = max(0, (pixels.width * s - viewport.width) / 2)
        let maxY = max(0, (pixels.height * s - viewport.height) / 2)
        return CGSize(width: min(maxX, max(-maxX, pan.width)), height: min(maxY, max(-maxY, pan.height)))
    }

    /// The divider follows the pointer, kept a little inside the edges so it stays grabbable.
    public static func split(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0.5 }
        return min(0.98, max(0.02, Double(x / width)))
    }

    /// "Fit" or "200 %".
    public func label(pixels: CGSize, in viewport: CGSize, displayScale: CGFloat) -> String {
        guard zoom != nil else { return Strings.text("Fit") }
        return "\(Int((effectiveZoom(pixels: pixels, in: viewport, displayScale: displayScale) * 100).rounded()))\u{00A0}%"
    }
}
