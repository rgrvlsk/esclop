// SPDX-License-Identifier: GPL-3.0-or-later
//
// Compare as a loupe (docs/design/targets: pr6-compare-loupe). "Compare" in the detail's "…"
// turns the picture into a loupe: a lens at true size (one pixel of the file to one pixel of the
// screen) follows the pointer, up and to the left of it so the pointer never hides what it
// points at. A click swaps the optimised file for the original and back; holding the button
// shows the other one until it is released. Space swaps, the arrows move the lens, Esc or Return
// ends it. Offered only where optimising loses detail (`CardPresentation.lossy`).

import AppKit
import EsclopCore
import ImageIO
import SwiftUI

/// The loupe of one card: which side it shows. The card owns it, so the hint under the picture
/// and the lens agree; nil when the loupe is off.
public struct LoupeState: Equatable, Sendable {
    /// A click swapped to the original, and it stays.
    public var original = false
    /// The button is down: the other side shows until it is released.
    public var pressed = false

    public var showsOriginal: Bool { original != pressed }

    /// What the hint under the picture says.
    var hint: String {
        switch (pressed, showsOriginal) {
        case (true, true): return Strings.text("Release to see optimised")
        case (true, false): return Strings.text("Release to see original")
        case (false, true): return Strings.text("Click or hold to see optimised")
        case (false, false): return Strings.text("Click or hold to see original")
        }
    }
}

/// Where the lens goes and how much it magnifies, for a picture fitted whole in `frame`.
struct LoupeGeometry: Equatable {
    /// The picture's frame in the detail, in points.
    var frame: CGSize
    /// The optimised file's size in pixels.
    var pixels: CGSize
    /// Screen pixels per point.
    var scale: CGFloat

    /// About 40 % of the picture's width, as in the target; smaller in a short picture.
    var diameter: CGFloat { max(48, min(124, frame.height - 2 * Self.margin - Self.label)) }

    /// Where the picture is drawn: fitted whole, centred.
    var picture: CGRect {
        guard pixels.width > 0, pixels.height > 0 else { return CGRect(origin: .zero, size: frame) }
        let fit = min(frame.width / pixels.width, frame.height / pixels.height)
        let size = CGSize(width: pixels.width * fit, height: pixels.height * fit)
        return CGRect(x: (frame.width - size.width) / 2, y: (frame.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// Points per pixel of the file inside the lens: one pixel of the file to one pixel of the
    /// screen, the only honest view of what compression did; at least twice the picture's size,
    /// so a small file still magnifies.
    var zoom: CGFloat {
        guard pixels.width > 0 else { return 2 }
        return max(1 / max(scale, 1), 2 * picture.width / pixels.width)
    }

    /// The point under the pointer, as a fraction of the picture, kept on it.
    func unit(_ pointer: CGPoint) -> CGPoint {
        let rect = picture
        guard rect.width > 0, rect.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(
            x: min(1, max(0, (pointer.x - rect.minX) / rect.width)),
            y: min(1, max(0, (pointer.y - rect.minY) / rect.height))
        )
    }

    /// The lens sits up and to the left of the pointer, the pointer on its lower-right rim, and
    /// inside the frame with room for its label above.
    func centre(_ pointer: CGPoint) -> CGPoint {
        let radius = diameter / 2
        let away = radius * 0.68
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            low <= high ? min(high, max(low, value)) : (low + high) / 2
        }
        return CGPoint(
            x: clamp(pointer.x - away, radius + Self.margin, frame.width - radius - Self.margin),
            y: clamp(pointer.y - away, radius + Self.margin + Self.label, frame.height - radius - Self.margin)
        )
    }

    /// The magnified file's size, and where its top-left corner goes in the lens so the point
    /// under the pointer sits in the lens's centre.
    func content(_ pointer: CGPoint) -> CGRect {
        let size = CGSize(width: pixels.width * zoom, height: pixels.height * zoom)
        let unit = unit(pointer)
        return CGRect(x: diameter / 2 - unit.x * size.width, y: diameter / 2 - unit.y * size.height, width: size.width, height: size.height)
    }

    static let margin: CGFloat = 6
    /// Room for the label that sits on the lens's top edge.
    static let label: CGFloat = 10
}

/// The lens over the detail's picture, and what the pointer and the keys do there.
struct Loupe: View {
    let card: ResultCard
    let before: URL
    let after: URL
    /// The panel the detail is in, for the keys (`SharingAnchor.window`).
    let share: SharingAnchor

    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var scheme
    @State private var images: Sides?
    @State private var pointer: CGPoint?
    @State private var pressedAt: (time: Date, point: CGPoint)?
    @State private var keys = MenuKeys()

    struct Sides {
        var before: CGImage
        var after: CGImage
    }

    var body: some View {
        GeometryReader { proxy in
            let geometry = LoupeGeometry(frame: proxy.size, pixels: pixels, scale: displayScale)
            let point = pointer ?? CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        if case let .active(location) = phase { pointer = location }
                    }
                    .gesture(press)
                lens(geometry, point: point)
                    .allowsHitTesting(false)
            }
            .onAppear { listen(size: proxy.size) }
        }
        .task(id: after) { images = await Self.load(before: before, after: after) }
        .onDisappear { keys.stop() }
    }

    /// The optimised file's size in pixels: the decoded file, or the result's own numbers until
    /// it is decoded.
    private var pixels: CGSize {
        if let after = images?.after { return CGSize(width: after.width, height: after.height) }
        if let width = card.result?.width, let height = card.result?.height { return CGSize(width: width, height: height) }
        return card.thumbnail?.size ?? CGSize(width: 1, height: 1)
    }

    private var showsOriginal: Bool { card.loupe?.showsOriginal ?? false }

    @ViewBuilder private func lens(_ geometry: LoupeGeometry, point: CGPoint) -> some View {
        let diameter = geometry.diameter
        let centre = geometry.centre(point)
        let content = geometry.content(point)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(NeutralFill.resting)
            picture
                .frame(width: content.width, height: content.height)
                .offset(x: content.minX, y: content.minY)
        }
        .frame(width: diameter, height: diameter, alignment: .topLeading)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Surface.cream, lineWidth: 5))
        .overlay(Circle().strokeBorder(Color.black.opacity(scheme == .dark ? 0.4 : 0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.22), radius: 8, y: 3)
        .overlay(alignment: .top) { label.offset(y: -Self.labelHeight / 2) }
        .position(centre)
    }

    /// The side shown, at the file's own pixels; the thumbnail stands in until it is decoded.
    @ViewBuilder private var picture: some View {
        if let images {
            Image(decorative: showsOriginal ? images.before : images.after, scale: 1)
                .resizable()
                .interpolation(.none)
        } else if let thumbnail = card.thumbnail {
            Image(nsImage: thumbnail).resizable()
        }
    }

    /// "ORIGINAL" in charcoal, "OPTIMISED" in cream, on the lens's top edge.
    private var label: some View {
        Text(showsOriginal ? Strings.text("Original") : Strings.text("Optimised"))
            .font(Typeface.section)
            .textCase(.uppercase)
            .tracking(1.6)
            .foregroundStyle(showsOriginal ? Ink.onCharcoal : Ink.charcoalText)
            .padding(.horizontal, 9)
            .frame(height: Self.labelHeight)
            .background(Capsule().fill(showsOriginal ? Ink.charcoal : Surface.cream))
            .fixedSize()
    }

    static let labelHeight: CGFloat = 20

    /// A press swaps at once. Released within 250 ms and 4 pt it was a click, and the swap stays;
    /// held longer, or moved, the side swaps back on release. The lens follows the pointer
    /// while the button is down.
    private var press: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                pointer = value.location
                if pressedAt == nil {
                    pressedAt = (Date(), value.startLocation)
                    card.loupe?.pressed = true
                }
            }
            .onEnded { value in
                guard let start = pressedAt else { return }
                pressedAt = nil
                let moved = hypot(value.location.x - start.point.x, value.location.y - start.point.y)
                let click = Date().timeIntervalSince(start.time) < Self.click && moved < 4
                if click { card.loupe?.original.toggle() }
                card.loupe?.pressed = false
            }
    }

    static let click: TimeInterval = 0.25

    /// Makes the panel key, so the keys reach the loupe even while another app is in front.
    private func listen(size: CGSize) {
        guard let window = share.window else { return }
        window.makeKey()
        keys.start(window: window) { code in
            switch code {
            case 49:
                card.loupe?.original.toggle()
            case 36, 76, 53:
                card.loupe = nil
            case 123, 124, 125, 126:
                var point = pointer ?? CGPoint(x: size.width / 2, y: size.height / 2)
                switch code {
                case 123: point.x -= Self.step
                case 124: point.x += Self.step
                case 125: point.y += Self.step
                default: point.y -= Self.step
                }
                pointer = CGPoint(x: min(size.width, max(0, point.x)), y: min(size.height, max(0, point.y)))
            default:
                return false
            }
            return true
        }
    }

    static let step: CGFloat = 8

    /// Both files, upright, decoded off the main thread.
    static func load(before: URL, after: URL) async -> Sides? {
        await Task.detached(priority: .userInitiated) {
            guard let old = decode(before), let new = decode(after) else { return nil }
            return Sides(before: old, after: new)
        }.value
    }

    /// The file's pixels, upright. ponytail: capped at 6000 pixels on the long side, so two
    /// pictures stay under about 300 MB; past that the lens shows slightly less than true size.
    /// Trigger: decode a tile around the pointer instead, if bigger files need true size.
    nonisolated static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), 6000),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Under the picture while the loupe is on, in place of the action row and at its height, so
/// nothing in the detail moves: what a click or a hold does, and Done.
struct LoupeHint: View {
    let state: LoupeState
    let done: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Done's twin, unseen, so the hint sits in the middle of the card.
            doneButton(Strings.text("Done")).hidden().accessibilityHidden(true)
            Spacer(minLength: 0)
            Text(state.hint)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Ink.text)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background(Capsule().fill(Surface.tile))
                .overlay(Capsule().strokeBorder(Ink.secondary.opacity(0.18), lineWidth: 0.5))
                .accessibilityAddTraits(.updatesFrequently)
            Spacer(minLength: 0)
            doneButton(Strings.text("Done"))
                .help(Strings.text("End the comparison"))
        }
        .frame(maxHeight: .infinity)
    }

    private func doneButton(_ title: String) -> some View {
        Button(title, action: done)
            .font(Typeface.label.weight(.semibold))
            .foregroundStyle(Ink.charcoalText)
            .buttonStyle(.plain)
            .fixedSize()
    }
}
