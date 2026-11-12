// SPDX-License-Identifier: GPL-3.0-or-later
//
// The one material every floating object shares (docs/design/proposal.md › Tokens, Spark 4
// and 5): Liquid Glass as a layer under the content, with a backing in the appearance's own
// tone over it, so the ground under the ink is bounded whatever the desktop is. The content is
// not "on" the glass, so the system cannot flip what the app draws to suit the desktop: inks
// stay the pinned ones (`Ink`). Before macOS 26, the HUD material stands in for the glass.
//
// - Reduce Transparency: the window background colour, opaque, with a 1 pt border.
// - Increase Contrast: opaque as well, the border in the label colour.
// - Still renders (`PanelBackdrop.flat`): the backing alone, opaque.

import AppKit
import SwiftUI

extension View {
    /// A floating surface of corner `radius`. `small` is for shapes shorter than 44 pt, which
    /// take more of the desktop's tone and get a denser backing. `tint` makes it a lit tile, an
    /// opaque fill. `tone` is the picture's colour, lent to the surface that carries it.
    public func floatingSurface(_ radius: CGFloat, small: Bool = false, tint: Color? = nil, tone: Color? = nil) -> some View {
        modifier(FloatingSurface(radius: radius, small: small, tint: tint, tone: tone))
    }

    /// The inner hairline every picture gets (black 14 %, one device pixel), so a white page does
    /// not dissolve into a light surface.
    public func pictureHairline(_ radius: CGFloat) -> some View {
        modifier(PictureHairline(radius: radius))
    }
}

struct FloatingSurface: ViewModifier {
    let radius: CGFloat
    var small = false
    var tint: Color?
    var tone: Color?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.panelBackdrop) private var backdrop
    @Environment(\.displayScale) private var displayScale

    /// The backing's tone: white 97 % in light, 13 % in dark.
    static func backing(dark: Bool) -> Color { Color(white: dark ? 0.13 : 0.97) }
    /// How much of the backing covers the glass.
    static func backingOpacity(small: Bool) -> Double { small ? 0.94 : 0.88 }

    private var dark: Bool { scheme == .dark }
    private var opaque: Bool { reduceTransparency || contrast == .increased }
    private var pixel: CGFloat { 1 / max(displayScale, 1) }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        surface(content, shape)
            .overlay { edge(shape) }
            .overlay { if let tone, tint == nil, !opaque { shape.strokeBorder(tone.opacity(0.2), lineWidth: 4).allowsHitTesting(false) } }
            .background { if let tone, tint == nil { halo(tone, shape) } }
            .background { shadow(shape) }
    }

    @ViewBuilder private func surface(_ content: Content, _ shape: RoundedRectangle) -> some View {
        if let tint {
            // A lit tile: the colour itself, opaque, so the state survives any wallpaper.
            content.background(shape.fill(tint))
        } else if opaque {
            content.background(shape.fill(Color(nsColor: .windowBackgroundColor)))
        } else if backdrop == .flat {
            content
                .background { if let tone { shape.fill(tone.opacity(0.06)) } }
                .background(shape.fill(Self.backing(dark: dark)))
        } else {
            content
                .background { if let tone { shape.fill(tone.opacity(0.06)) } }
                .background(shape.fill(Self.backing(dark: dark).opacity(Self.backingOpacity(small: small))))
                .background { glass(shape) }
        }
    }

    @ViewBuilder private func glass(_ shape: RoundedRectangle) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            VisualEffectBackground().clipShape(shape)
        }
        #else
        VisualEffectBackground().clipShape(shape)
        #endif
    }

    /// The edges: a glass edge lit from the top left, an inner rim, an outer hairline. Under
    /// Reduce Transparency or Increase Contrast, one 1 pt border instead.
    @ViewBuilder private func edge(_ shape: RoundedRectangle) -> some View {
        if opaque, tint == nil {
            shape.strokeBorder(contrast == .increased ? Color(nsColor: .labelColor) : Color.primary.opacity(0.45), lineWidth: 1).allowsHitTesting(false)
        } else {
            ZStack {
                if tint == nil {
                    shape.strokeBorder(
                        AngularGradient(stops: [
                            .init(color: .white.opacity(dark ? 0.06 : 0.15), location: 0),
                            .init(color: .white.opacity(dark ? 0.4 : 0.9), location: 0.62),
                            .init(color: .white.opacity(dark ? 0.06 : 0.15), location: 1),
                        ], center: .center),
                        lineWidth: 1
                    )
                }
                shape.strokeBorder(Color.white.opacity(Elevation.rimOpacity(dark: dark)), lineWidth: pixel)
                shape.inset(by: -pixel).strokeBorder(Color.black.opacity(Elevation.hairlineOpacity(dark: dark)), lineWidth: pixel)
            }
            .allowsHitTesting(false)
        }
    }

    /// The picture's tone under the card: 32 pt blur, 14 pt down.
    private func halo(_ tone: Color, _ shape: RoundedRectangle) -> some View {
        shape.fill(tone.opacity(dark ? 0.35 : 0.4)).blur(radius: 32).offset(y: 14).padding(4).allowsHitTesting(false)
    }

    /// The shadow, kept outside the shape so it never darkens the glass from below.
    private func shadow(_ shape: RoundedRectangle) -> some View {
        shape.fill(.black)
            .shadow(color: .black.opacity(Elevation.shadowOpacity(dark: dark)), radius: Elevation.shadowBlur / 2, y: Elevation.shadowY)
            .mask { Rectangle().padding(-60).overlay(shape.blendMode(.destinationOut)).compositingGroup() }
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
