// SPDX-License-Identifier: GPL-3.0-or-later
//
// Size (docs/design/targets: pr4-options-popover-size-actions): the original's size as the
// heading, then Original, 2000 px, 1280 px and Half with their sizes, a custom width and height
// that keep the aspect ratio, and fit under a size. Crop is a tab of its own (aspect chips, then
// the editor with a free or locked rectangle and the size in pixels). Sound takes Size's place
// for audio: bitrate, loudness, speed and fit.

import EsclopCore
import EsclopIPC
import SwiftUI

struct SizeTab: View {
    @Bindable var model: OptionsModel
    @State private var width = ""
    @State private var height = ""
    /// Only the field being typed in sets the other, so the two never chase each other.
    @FocusState private var typing: Side?

    enum Side: Hashable { case width, height }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.kind != .pdf, let originalWidth = model.facts.width, let originalHeight = model.facts.height {
                Text(Strings.format("Original %@", Figures.bytes(model.card.result?.bytesBefore ?? model.card.bytesBefore)))
                    .font(Typeface.smallHeading)
                    .foregroundStyle(PopoverInk.primary.color)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(model.sizePresets) { preset in tile(preset) }
                }
                OptionsRow {
                    HStack(spacing: 8) {
                        Text(Strings.text("Custom")).font(OptionsType.bodyStrong)
                        Spacer(minLength: 4)
                        field($width, .width, Strings.text("Width")) { value in
                            height = String(Int((Double(value) * Double(originalHeight) / Double(originalWidth)).rounded()))
                        }
                        Image(systemName: "lock")
                            .font(.system(size: 12))
                            .foregroundStyle(PopoverInk.secondary.color)
                            .help(Strings.text("Keeps the aspect ratio"))
                        Text(verbatim: "×").foregroundStyle(PopoverInk.secondary.color)
                        field($height, .height, Strings.text("Height")) { value in
                            width = String(Int((Double(value) * Double(originalWidth) / Double(originalHeight)).rounded()))
                        }
                    }
                }
                .onAppear { setCustom(originalWidth, originalHeight) }
                .onChange(of: model.currentScale) { setCustom(originalWidth, originalHeight) }
                Text(Strings.text("Never enlarges. Keeps the aspect ratio."))
                    .font(OptionsType.label)
                    .foregroundStyle(PopoverInk.secondary.color)
            }
            FitChips(model: model)
        }
    }

    private func tile(_ preset: OptionsModel.SizePreset) -> some View {
        let selected = model.isCurrent(preset.factor)
        return Button { model.scale(to: preset.factor) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.title).font(OptionsType.bodyStrong)
                Group {
                    if preset.factor == 1 {
                        Text(Figures.bytes(model.card.result?.bytesBefore ?? model.card.bytesBefore))
                    } else if selected, let bytes = model.card.result?.bytesAfter {
                        Text(Figures.bytes(bytes))
                    } else {
                        EstimateText(model: model, request: model.scaleRequest(preset.factor), silentWhenUnavailable: true)
                    }
                }
                .font(OptionsType.label)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(TileStyle(selected: selected))
        .disabled(model.card.isWorking)
        .accessibilityLabel(preset.spoken)
        .accessibilityValue(spokenSize(preset, selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The size VoiceOver hears with a tile, as the tile shows it.
    private func spokenSize(_ preset: OptionsModel.SizePreset, selected: Bool) -> String {
        if preset.factor == 1 { return Figures.bytes(model.card.result?.bytesBefore ?? model.card.bytesBefore) }
        if selected, let bytes = model.card.result?.bytesAfter { return Figures.bytes(bytes) }
        return model.estimate(model.scaleRequest(preset.factor)).map { Strings.format("about %@", Figures.bytes($0)) } ?? ""
    }

    /// A number field; Return scales to the width it gives.
    private func field(_ text: Binding<String>, _ side: Side, _ title: String, follow: @escaping (Int) -> Void) -> some View {
        OptionsNumberField(title: title, text: text)
            .focused($typing, equals: side)
            .onChange(of: text.wrappedValue) { _, value in
                if typing == side, let number = Int(value), number > 0 { follow(number) }
            }
            .onSubmit(applyCustom)
            .disabled(model.card.isWorking)
    }

    private func setCustom(_ originalWidth: Int, _ originalHeight: Int) {
        width = String(Int((Double(originalWidth) * model.currentScale).rounded()))
        height = String(Int((Double(originalHeight) * model.currentScale).rounded()))
    }

    private func applyCustom() {
        guard let value = Int(width), value > 0, let original = model.facts.width, original > 0, let originalHeight = model.facts.height else { return }
        model.scale(to: Double(value) / Double(original))
        // A width past the original's is the original's: the fields say so.
        if value > original { typing = nil; setCustom(original, originalHeight) }
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
                OptionsNumberField(title: Strings.text("Size in kB"), text: $model.customFit, width: 80)
                    .onSubmit(applyCustom)
                Text(verbatim: "kB").foregroundStyle(PopoverInk.secondary.color)
                Spacer()
                CharcoalButton(title: Strings.text("Fit"), action: applyCustom).disabled(Int(model.customFit) == nil)
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
        VStack(alignment: .leading, spacing: 6) { sections }
    }

    @ViewBuilder private var sections: some View {
        // The tab says "Crop"; once a frame is drawn, the line gives the size it makes.
        if let crop = model.crop, model.cropping, crop.cropSize != nil {
            SectionLabel(title: Strings.text("Crop")) {
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
        // The picture is always there with its frame (owner's request: a crop needs to be seen):
        // the tab opens on the whole picture, a ratio chip or a handle frames it.
        if model.kind != .pdf, model.facts.width != nil {
            if model.crop != nil {
                CropEditor(model: model)
            } else {
                Color.clear.frame(height: 1).onAppear { model.startCrop(aspect: .free) }
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
                    // No "px": the heading says the size, and Catalan's Restableix and Retalla
                    // need the room.
                    OptionsNumberField(title: Strings.text("Width"), text: $widthText, width: 64).onSubmit(applySize)
                    Text("×").foregroundStyle(PopoverInk.secondary.color)
                    OptionsNumberField(title: Strings.text("Height"), text: $heightText, width: 64).onSubmit(applySize)
                    Spacer(minLength: 4)
                    // Back to the whole picture; the preview stays.
                    Button(Strings.text("Reset")) { model.resetCrop() }
                        .buttonStyle(.plain)
                        .font(OptionsType.bodyStrong)
                        .foregroundStyle(Ink.charcoalText)
                        .disabled(crop.cropSize == nil)
                    CharcoalButton(title: Strings.text("Crop")) { model.applyCrop() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(crop.cropSize == nil || model.card.isWorking)
                }
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
