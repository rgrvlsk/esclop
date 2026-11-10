// SPDX-License-Identifier: GPL-3.0-or-later
//
// Size: downscale in 10 % steps with the live dimensions and size, back to 100 %, fit under a
// size, and crop (aspect chips, then the editor with a free or locked rectangle and the size in
// pixels). Sound takes its place for audio: bitrate, loudness, speed and fit.

import EsclopCore
import EsclopIPC
import SwiftUI

struct SizeTab: View {
    @Bindable var model: OptionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.kind != .pdf {
                SectionLabel(title: Strings.text("Downscale")) {
                    HStack(spacing: 0) {
                        if let dimensions = model.scaledDimensions { Text(dimensions + " · ") }
                        EstimateText(model: model, request: model.scaleRequest)
                    }
                }
                Slider(value: $model.scale, in: 0.1 ... 1, step: 0.1) { editing in
                    if !editing, model.scale < 1 { model.commitScale() }
                }
                .tint(Palette.accent)
                .disabled(model.card.isWorking)
                .accessibilityLabel(Strings.text("Downscale"))
                .accessibilityValue("\(Int((model.scale * 100).rounded()))\u{00A0}%")
                HStack {
                    Text("10\u{00A0}%")
                    Spacer()
                    Text("50\u{00A0}%")
                    Spacer()
                    Text("100\u{00A0}%")
                }
                .font(OptionsType.label)
                .foregroundStyle(PopoverInk.secondary.color)
                Button(Strings.text("Restore original size (100 %)")) { model.restoreFullSize() }
                    .buttonStyle(.plain)
                    .foregroundStyle(PopoverInk.accent.color)
                    .font(OptionsType.body)
                    .disabled(model.card.isWorking)
            }
            FitChips(model: model)
            CropSection(model: model)
        }
    }
}

struct FitChips: View {
    @Bindable var model: OptionsModel
    @State private var custom = false
    static let targets = [500_000, 1_000_000, 2_000_000, 5_000_000]

    var body: some View {
        SectionLabel(title: Strings.text("Fit under"))
        FlowRow {
            ForEach(Self.targets, id: \.self) { bytes in
                Chip(title: Figures.bytes(bytes)) { model.fit(under: bytes) }
                    .disabled(model.card.isWorking || (model.card.result?.bytesAfter ?? .max) <= bytes && model.card.result != nil)
            }
            Chip(title: Strings.text("Custom…"), selected: custom) { custom.toggle() }
        }
        if custom {
            HStack {
                TextField(Strings.text("Size in kB"), text: $model.customFit)
                    .textFieldStyle(.roundedBorder)
                    .font(OptionsType.body)
                    .onSubmit(applyCustom)
                Text("kB").foregroundStyle(PopoverInk.secondary.color)
                Button(Strings.text("Fit"), action: applyCustom).disabled(Int(model.customFit) == nil)
            }
        }
    }

    private func applyCustom() {
        guard let kilobytes = Int(model.customFit.trimmingCharacters(in: .whitespaces)), kilobytes > 0 else { return }
        model.fit(under: kilobytes * 1000)
    }
}

struct CropSection: View {
    @Bindable var model: OptionsModel

    var body: some View {
        SectionLabel(title: Strings.text("Crop")) {
            if let crop = model.crop, model.cropping {
                HStack(spacing: 0) {
                    Text(verbatim: "\(crop.outputWidth) × \(crop.outputHeight) · ")
                    EstimateText(model: model, request: model.cropRequest)
                }
            }
        }
        FlowRow {
            ForEach(CropAspect.presets) { aspect in
                Chip(title: aspect.title, selected: model.cropping && model.crop?.aspect == aspect) {
                    if model.kind == .pdf {
                        if let ratio = aspect.value { model.app.cropPDF(model.card, aspect: ratio) }
                    } else {
                        model.startCrop(aspect: aspect)
                    }
                }
                .disabled(model.card.isWorking || model.kind == .pdf && aspect == .free)
            }
        }
        if model.kind != .pdf {
            if model.cropping, model.crop != nil {
                CropEditor(model: model)
            } else {
                Button {
                    model.startCrop(aspect: .free)
                } label: {
                    Label(Strings.text("Open the editor…"), systemImage: "crop")
                }
                .buttonStyle(.plain)
                    .foregroundStyle(PopoverInk.accent.color)
                .font(OptionsType.body)
                .disabled(model.facts.width == nil)
            }
        }
    }
}

/// The picture with the crop rectangle on top: drag inside to move, drag a handle to resize.
/// Below, the output size in pixels, then Cancel and Crop.
struct CropEditor: View {
    @Bindable var model: OptionsModel
    @State private var start: CropGeometry?
    @State private var widthText = ""
    @State private var heightText = ""

    var body: some View {
        if let crop = model.crop {
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { proxy in
                    let scale = proxy.size.width / CGFloat(crop.imageWidth)
                    let frame = CGRect(x: crop.rect.minX * scale, y: crop.rect.minY * scale, width: crop.rect.width * scale, height: crop.rect.height * scale)
                    ZStack(alignment: .topLeading) {
                        picture.frame(width: proxy.size.width, height: proxy.size.height).clipped()
                        // Everything outside the crop dims.
                        Path { path in
                            path.addRect(CGRect(origin: .zero, size: proxy.size))
                            path.addRect(frame)
                        }
                        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                        Rectangle()
                            .strokeBorder(Color.white, lineWidth: 1.5)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                            .gesture(drag(scale: scale) { geometry, delta in geometry.move(by: delta) })
                            .accessibilityLabel(Strings.text("Crop area"))
                        ForEach(CropGeometry.Handle.allCases, id: \.self) { handle in
                            Circle()
                                .fill(Color.white)
                                .overlay(Circle().strokeBorder(Color.black.opacity(0.3)))
                                .frame(width: 10, height: 10)
                                .position(position(of: handle, in: frame))
                                .gesture(drag(scale: scale) { geometry, delta in geometry.drag(handle, by: delta) })
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .aspectRatio(CGFloat(crop.imageWidth) / CGFloat(crop.imageHeight), contentMode: .fit)
                .frame(maxHeight: 220)

                HStack(spacing: 6) {
                    TextField(Strings.text("Width"), text: $widthText).frame(width: 64).onSubmit(applySize)
                    Text("×").foregroundStyle(PopoverInk.secondary.color)
                    TextField(Strings.text("Height"), text: $heightText).frame(width: 64).onSubmit(applySize)
                    Text("px").foregroundStyle(PopoverInk.secondary.color)
                    Spacer()
                    Button(Strings.text("Cancel")) { model.cropping = false; model.crop = nil }
                    Button(Strings.text("Crop")) { model.applyCrop() }
                        .keyboardShortcut(.defaultAction)
                        .primaryButton()
                        .disabled(crop.cropSize == nil || model.card.isWorking)
                }
                .textFieldStyle(.roundedBorder)
                .font(OptionsType.body)
                .monospacedDigit()
            }
            .onAppear(perform: syncFields)
            .onChange(of: crop) { syncFields() }
        }
    }

    @ViewBuilder private var picture: some View {
        if let image = model.card.originalThumbnail ?? model.card.thumbnail {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            Rectangle().fill(.quaternary)
        }
    }

    private func drag(scale: CGFloat, _ change: @escaping (inout CropGeometry, CGSize) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if start == nil { start = model.crop }
                guard var geometry = start else { return }
                change(&geometry, CGSize(width: value.translation.width / scale, height: value.translation.height / scale))
                model.crop = geometry
            }
            .onEnded { _ in start = nil }
    }

    private func position(of handle: CropGeometry.Handle, in frame: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: frame.minX, y: frame.minY)
        case .top: return CGPoint(x: frame.midX, y: frame.minY)
        case .topRight: return CGPoint(x: frame.maxX, y: frame.minY)
        case .right: return CGPoint(x: frame.maxX, y: frame.midY)
        case .bottomRight: return CGPoint(x: frame.maxX, y: frame.maxY)
        case .bottom: return CGPoint(x: frame.midX, y: frame.maxY)
        case .bottomLeft: return CGPoint(x: frame.minX, y: frame.maxY)
        case .left: return CGPoint(x: frame.minX, y: frame.midY)
        }
    }

    private func syncFields() {
        guard let crop = model.crop else { return }
        widthText = "\(crop.outputWidth)"
        heightText = "\(crop.outputHeight)"
    }

    private func applySize() {
        guard let width = Int(widthText), let height = Int(heightText) else { return syncFields() }
        model.crop?.setOutput(width: width, height: height)
        syncFields()
    }
}

struct SoundTab: View {
    let model: OptionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AudioControls(model: model)
            SpeedMenu(model: model)
            FitChips(model: model)
        }
    }
}

/// Chips that wrap onto the next line.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let width = proposal.width ?? 328
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += line + spacing
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += line + spacing
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
