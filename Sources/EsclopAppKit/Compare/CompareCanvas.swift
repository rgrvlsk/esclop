// SPDX-License-Identifier: GPL-3.0-or-later
//
// Two pictures (an image, or a PDF page) laid out the way the mode asks: split by a draggable
// divider, side by side, or one in place of the other. Both share one zoom and pan: drag pans
// when zoomed (in split mode at fit size it moves the divider, as in Clop), pinch zooms, a double
// click flips between fit and 100 %. The difference overlay marks in red where they differ.

import AppKit
import SwiftUI

struct CompareCanvas: View {
    @Bindable var model: CompareModel
    @Environment(\.displayScale) private var displayScale
    @State private var panStart: CGSize?
    @State private var zoomStart: Double?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Group {
                switch model.mode {
                case .split: split(in: size)
                case .sideBySide: sideBySide(in: size)
                case .flip: flip(in: size)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(drag(in: model.mode == .sideBySide ? CGSize(width: (size.width - 8) / 2, height: size.height) : size))
            .simultaneousGesture(magnify(in: size))
            .onTapGesture(count: 2) { toggleZoom(in: size) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Strings.text("Comparison"))
            .accessibilityValue(accessibilityValue(in: size))
            .accessibilityAdjustableAction { direction in
                guard model.mode == .split else { return }
                model.viewport.split = min(0.98, max(0.02, model.viewport.split + (direction == .increment ? 0.1 : -0.1)))
            }
        }
        .clipped()
    }

    // MARK: Layouts

    private func split(in size: CGSize) -> some View {
        let divider = size.width * model.viewport.split
        return ZStack(alignment: .topLeading) {
            picture(model.beforeImage, in: size)
            picture(model.afterImage, in: size)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: max(0, size.width - divider)).offset(x: divider)
                }
            if model.showsDifference { differenceOverlay(in: size) }
            CompareDivider(x: divider, height: size.height) { x in
                model.viewport.split = CompareViewport.split(at: x, width: size.width)
            }
            HStack {
                CompareChip(text: Strings.text("Original"))
                Spacer()
                CompareChip(text: Strings.text("Optimised"))
            }
            .padding(10)
        }
        .coordinateSpace(.named("compareCanvas"))
    }


    private func sideBySide(in size: CGSize) -> some View {
        let pane = CGSize(width: max(0, (size.width - 8) / 2), height: size.height)
        return HStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                picture(model.beforeImage, in: pane)
                CompareChip(text: Strings.text("Original")).padding(10)
            }
            .frame(width: pane.width, height: pane.height)
            .clipped()
            ZStack(alignment: .topLeading) {
                picture(model.afterImage, in: pane)
                if model.showsDifference { differenceOverlay(in: pane) }
                CompareChip(text: Strings.text("Optimised")).padding(10)
            }
            .frame(width: pane.width, height: pane.height)
            .clipped()
        }
    }

    private func flip(in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            picture(model.showsOriginal ? model.beforeImage : model.afterImage, in: size)
            if model.showsDifference, !model.showsOriginal { differenceOverlay(in: size) }
            CompareChip(text: model.showsOriginal ? Strings.text("Original") : Strings.text("Optimised")).padding(10)
        }
    }

    // MARK: Pictures

    /// A picture at the shared zoom and pan, laid out at the original's pixel size so both
    /// sides line up even when the optimised one was scaled down.
    @ViewBuilder
    private func picture(_ image: CGImage?, in viewport: CGSize) -> some View {
        let scale = model.viewport.scale(pixels: model.pixels, in: viewport, displayScale: displayScale)
        let drawn = CGSize(width: model.pixels.width * scale, height: model.pixels.height * scale)
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(model.viewport.effectiveZoom(pixels: model.pixels, in: viewport, displayScale: displayScale) >= 2 ? .none : .high)
                .frame(width: drawn.width, height: drawn.height)
                .offset(model.viewport.pan)
                .frame(width: viewport.width, height: viewport.height)
        } else {
            Color.clear.frame(width: viewport.width, height: viewport.height)
        }
    }

    private func differenceOverlay(in viewport: CGSize) -> some View {
        picture(model.difference?.mask, in: viewport).allowsHitTesting(false)
    }

    // MARK: Gestures

    private func drag(in viewport: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if model.mode == .split, model.viewport.zoom == nil {
                    model.viewport.split = CompareViewport.split(at: value.location.x, width: viewport.width)
                    return
                }
                let start = panStart ?? model.viewport.pan
                panStart = start
                let wanted = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                model.viewport.pan = model.viewport.clamped(wanted, pixels: model.pixels, in: viewport, displayScale: displayScale)
            }
            .onEnded { _ in panStart = nil }
    }

    private func magnify(in viewport: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = zoomStart ?? model.viewport.effectiveZoom(pixels: model.pixels, in: viewport, displayScale: displayScale)
                zoomStart = start
                model.viewport.zoom = min(CompareViewport.steps.last ?? 8, max(0.05, start * value.magnification))
                model.viewport.pan = model.viewport.clamped(model.viewport.pan, pixels: model.pixels, in: viewport, displayScale: displayScale)
            }
            .onEnded { _ in zoomStart = nil }
    }

    private func toggleZoom(in viewport: CGSize) {
        if model.viewport.zoom == nil { model.viewport.zoom = 1 } else { model.viewport.fit() }
        model.viewport.pan = model.viewport.clamped(model.viewport.pan, pixels: model.pixels, in: viewport, displayScale: displayScale)
    }

    private func accessibilityValue(in size: CGSize) -> String {
        let zoom = model.viewport.label(pixels: model.pixels, in: size, displayScale: displayScale)
        switch model.mode {
        case .split: return Strings.format("Divider at %d %%, zoom %@", Int((model.viewport.split * 100).rounded()), zoom)
        case .sideBySide: return Strings.format("Side by side, zoom %@", zoom)
        case .flip: return model.showsOriginal ? Strings.format("Showing the original, zoom %@", zoom) : Strings.format("Showing the optimised file, zoom %@", zoom)
        }
    }
}

/// The split's divider: a line with a round handle that drags on its own, whatever the zoom.
struct CompareDivider: View {
    let x: CGFloat
    let height: CGFloat
    let move: (CGFloat) -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.white).frame(width: 2, height: height).shadow(color: .black.opacity(0.45), radius: 1.5)
            Circle()
                .fill(Color.black.opacity(0.72))
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
                .frame(width: 30, height: 30)
        }
        .frame(width: 30, height: height)
        .contentShape(Rectangle())
        .position(x: x, y: height / 2)
        .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("compareCanvas")).onChanged { move($0.location.x) })
        .accessibilityHidden(true)
    }
}

/// "Original" / "Optimised" over the pictures: white on a dark chip, readable on any picture.
struct CompareChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.72)))
            .accessibilityHidden(true)
    }
}
