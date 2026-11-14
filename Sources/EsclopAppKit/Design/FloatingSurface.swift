// SPDX-License-Identifier: GPL-3.0-or-later
//
// The one material every floating object shares (docs/design/targets/README.md › Owner's
// decisions, and proposal.md › Tokens, Spark 4 and 5): opaque cream in light, warm charcoal in
// dark, with the one elevation. Opaque, so every ink holds its contrast over any desktop and
// nothing the app draws depends on what is behind it. A state may fill the surface with its own
// tint (work in progress, a decision); a picture may lend it its tone.
//
// - Reduce Transparency: nothing to remove; the surface is already opaque.
// - Increase Contrast: a 1 pt border in the label colour.

import AppKit
import SwiftUI

extension View {
    /// A floating surface of corner `radius`. `fill` replaces the cream for a state
    /// (`Surface.progress`, `Surface.decision`) or a selected tile (`Ink.charcoal`). `tone` is the
    /// picture's colour, lent to the surface that carries it.
    public func floatingSurface(_ radius: CGFloat, fill: Color = Surface.cream, tone: Color? = nil) -> some View {
        modifier(FloatingSurface(radius: radius, fill: fill, tone: tone))
    }

    /// The inner hairline every picture gets (black 14 %, one device pixel), so a white page does
    /// not dissolve into a light surface.
    public func pictureHairline(_ radius: CGFloat) -> some View {
        modifier(PictureHairline(radius: radius))
    }
}

struct FloatingSurface: ViewModifier {
    let radius: CGFloat
    var fill: Color = Surface.cream
    var tone: Color?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    private var dark: Bool { scheme == .dark }
    private var pixel: CGFloat { 1 / max(displayScale, 1) }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            // A 6 % wash of the tone in light. None in dark: on warm charcoal any wash pulls the
            // original size's brick red under 4.5:1 (3.95:1 under a yellow picture).
            .background { if let tone, !dark { shape.fill(tone.opacity(0.06)) } }
            .background { topLight(shape) }
            .background(shape.fill(fill))
            .overlay { edge(shape) }
            .overlay { if let tone { shape.strokeBorder(tone.opacity(0.2), lineWidth: 4).allowsHitTesting(false) } }
            .background { if let tone { halo(tone, shape) } }
            .background { shadow(shape) }
    }

    /// The edges: a light edge lit from the top left, an inner rim, an outer hairline; under
    /// Increase Contrast, one 1 pt border in the label colour.
    @ViewBuilder private func edge(_ shape: RoundedRectangle) -> some View {
        if contrast == .increased {
            shape.strokeBorder(Color(nsColor: .labelColor), lineWidth: 1).allowsHitTesting(false)
        } else {
            ZStack {
                shape.strokeBorder(
                    AngularGradient(stops: [
                        .init(color: .white.opacity(dark ? 0.04 : 0.15), location: 0),
                        .init(color: .white.opacity(dark ? 0.18 : 0.9), location: 0.62),
                        .init(color: .white.opacity(dark ? 0.04 : 0.15), location: 1),
                    ], center: .center),
                    lineWidth: 1
                )
                shape.strokeBorder(Color.white.opacity(Elevation.rimOpacity(dark: dark)), lineWidth: pixel)
                shape.inset(by: -pixel).strokeBorder(Color.black.opacity(Elevation.hairlineOpacity(dark: dark)), lineWidth: pixel)
            }
            .allowsHitTesting(false)
        }
    }

    /// Light from above: the top 10 pt fade from white to the fill, as in the targets. The
    /// surface stays opaque.
    private func topLight(_ shape: RoundedRectangle) -> some View {
        let stops: [Gradient.Stop] = dark
            ? [.init(color: .white.opacity(0.07), location: 0), .init(color: .clear, location: 1)]
            : [.init(color: .white.opacity(0.7), location: 0), .init(color: .white.opacity(0.25), location: 0.4), .init(color: .clear, location: 1)]
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
            .frame(height: 10)
            .frame(maxHeight: .infinity, alignment: .top)
            .clipShape(shape)
            .allowsHitTesting(false)
    }

    /// The picture's tone under the card: 32 pt blur, 14 pt down.
    private func halo(_ tone: Color, _ shape: RoundedRectangle) -> some View {
        shape.fill(tone.opacity(dark ? 0.35 : 0.4)).blur(radius: 32).offset(y: 14).padding(4).allowsHitTesting(false)
    }

    private func shadow(_ shape: RoundedRectangle) -> some View {
        shape.fill(fill)
            .shadow(color: .black.opacity(Elevation.shadowOpacity(dark: dark)), radius: Elevation.shadowBlur / 2, y: Elevation.shadowY)
            .allowsHitTesting(false)
    }
}

struct PictureHairline: ViewModifier {
    let radius: CGFloat
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.black.opacity(0.14), lineWidth: 1 / max(displayScale, 1))
                .allowsHitTesting(false)
        )
    }
}

/// A picture's dominant colour, pushed toward its own hue so that a grey average does not wash
/// the card. Nil for a picture with no colour of its own (most screenshots): it keeps the
/// neutral shadow. In dark, the lightness is capped at 60 % so a halo never reads as a selection.
public enum PictureTone {
    public static func of(_ image: NSImage, dark: Bool) -> Color? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return of(cg, dark: dark)
    }

    public static func of(_ image: CGImage, dark: Bool) -> Color? {
        guard let average = average(image) else { return nil }
        let color = NSColor(srgbRed: average.r, green: average.g, blue: average.b, alpha: 1)
        var (hue, saturation, brightness, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        guard saturation > 0.12 else { return nil }
        let pushed = min(1, saturation * 2.4 + 0.1)
        let value = dark ? min(0.6, max(0.45, brightness)) : max(0.6, brightness)
        return Color(nsColor: NSColor(hue: hue, saturation: pushed, brightness: value, alpha: 1))
    }

    /// The image's average colour in sRGB.
    static func average(_ image: CGImage) -> RGBA? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: 4)
        return RGBA(r: Double(bytes[0]) / 255, g: Double(bytes[1]) / 255, b: Double(bytes[2]) / 255, a: 1)
    }
}
