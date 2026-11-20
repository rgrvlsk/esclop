// SPDX-License-Identifier: GPL-3.0-or-later
//
// The popover's parts, from the components table: 16 pt padding; 14 pt for the file name, 13 pt
// for controls and rows, 12 pt for labels and secondary lines (nothing smaller, and type never
// shrinks to fit); two-line format tiles; section labels carrying their live value; switches for
// on/off options; drill-down rows with a chevron.

import EsclopCore
import SwiftUI

enum OptionsType {
    static let title = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyStrong = Font.system(size: 13, weight: .semibold)
    static let label = Font.system(size: 12)
    static let padding: CGFloat = 16
    static let width: CGFloat = 360
    static let maxHeight: CGFloat = 560
    static let radius: CGFloat = 12
    /// A flat row that holds a control: a switch, a picker, two number fields.
    static let rowHeight: CGFloat = 44
}

/// "Quality" on the left, "82 % · ≈ 612 kB" on the right.
struct SectionLabel<Value: View>: View {
    let title: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 8)
            value.monospacedDigit()
        }
        .font(OptionsType.label)
        .foregroundStyle(PopoverInk.secondary.color)
        .padding(.top, 8)
    }
}

extension SectionLabel where Value == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// "≈ 410 kB", or a placeholder while it is worked out.
struct EstimateText: View {
    let model: OptionsModel
    let request: EstimateRequest?
    /// "≈" before the size; off where the sentence already says "would be".
    var approximate = true
    /// Nothing at all when there is no estimate, instead of "—" (a tile's second line).
    var silentWhenUnavailable = false

    var body: some View {
        Group {
            if let request, let bytes = model.estimate(request) {
                Text((approximate ? "≈\u{00A0}" : "") + Figures.bytes(bytes))
            } else if let request, model.unavailable.contains(request) {
                if !silentWhenUnavailable { Text(verbatim: "—").accessibilityLabel(Strings.text("No estimate")) }
            } else if request != nil {
                Text(verbatim: "≈\u{00A0}000 kB").redacted(reason: .placeholder)
                    .accessibilityLabel(Strings.text("Estimating"))
            }
        }
        .monospacedDigit()
        // The original is unknown while the file runs again; start over once it is back.
        .task(id: Load(request: request, original: model.original)) {
            if let request { await model.load(request) }
        }
    }
}

private struct Load: Hashable {
    var request: EstimateRequest?
    var original: URL?
}

/// A format with its size, on two lines: the file's own size on the tile it has now, an
/// estimate on the others; an amber dot on the suggested one.
struct FormatTile: View {
    let title: String
    let model: OptionsModel
    let request: EstimateRequest
    let selected: Bool
    var suggested = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(OptionsType.bodyStrong)
                Group {
                    if selected, model.armed == nil, let bytes = model.card.result?.bytesAfter {
                        Text(Figures.bytes(bytes))
                    } else {
                        EstimateText(model: model, request: request, silentWhenUnavailable: true)
                    }
                }
                .font(OptionsType.label)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                if suggested {
                    SuggestedMark().accessibilityLabel(Strings.text("Suggested"))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(TileStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Resting content is a cream tile; the chosen one is charcoal (docs/design/targets/README.md ›
/// Visual grammar).
struct TileStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? AnyShapeStyle(Ink.onCharcoal) : AnyShapeStyle(PopoverInk.primary.color))
            .raised(RoundedRectangle(cornerRadius: OptionsType.radius, style: .continuous), fill: selected ? Ink.charcoal : Surface.cream)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// A capsule choice: "1 MB", "16:9".
struct Chip: View {
    let title: String
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(OptionsType.body).monospacedDigit().padding(.horizontal, 10).padding(.vertical, 4).contentShape(Capsule())
        }
        .buttonStyle(ChipStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A chip: cream at rest, charcoal when chosen (teal is the saving's alone).
struct ChipStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? AnyShapeStyle(Ink.onCharcoal) : AnyShapeStyle(PopoverInk.primary.color))
            .raised(Capsule(), fill: selected ? Ink.charcoal : Surface.cream)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// A row that opens a list inside the popover.
struct DrillRow: View {
    let symbol: String
    let title: String
    var detail: String?
    var chevron = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(PopoverInk.icon.color)
                Text(title)
                Spacer(minLength: 8)
                if let detail { Text(detail).foregroundStyle(PopoverInk.secondary.color).monospacedDigit() }
                if chevron { Image(systemName: "chevron.right").font(OptionsType.label.weight(.semibold)).foregroundStyle(PopoverInk.icon.color) }
            }
            .font(OptionsType.body)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A switch row: label on the left, the switch on the right.
struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title).font(OptionsType.body)
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                // Charcoal when on: no system blue (docs/design/targets/README.md › Visual grammar).
                .tint(Ink.charcoal)
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
    }
}

/// The inside of a drill-down: a back button with the title, then the list.
struct DrillPage<Content: View>: View {
    let title: String
    let back: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: back) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(OptionsType.label.weight(.semibold))
                    Text(title).font(OptionsType.bodyStrong)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.leftArrow, modifiers: [])
            Divider()
            content
        }
    }
}

extension FileOrigin {
    var title: String {
        switch self {
        case .screenshot: return Strings.text("Screenshot")
        case .photos: return Strings.text("Photo from Photos")
        case .browser: return Strings.text("Image from a browser")
        case .graphic: return Strings.text("Graphic with transparency")
        case .animatedGIF: return Strings.text("Animated GIF")
        case .screenRecording: return Strings.text("Screen recording")
        case .pdfExport: return Strings.text("Exported document")
        case .voiceMemo: return Strings.text("Voice memo")
        case .unknown: return Strings.text("Unknown origin")
        }
    }

    var symbol: String {
        switch self {
        case .screenshot: return "camera.viewfinder"
        case .photos: return "photo.on.rectangle"
        case .browser: return "globe"
        case .graphic: return "square.on.square.dashed"
        case .animatedGIF: return "play.square.stack"
        case .screenRecording: return "record.circle"
        case .pdfExport: return "doc.richtext"
        case .voiceMemo: return "waveform"
        case .unknown: return "questionmark.square.dashed"
        }
    }
}

/// Equal-width segments with a raised selection, like the prototype's tabs: native segmented
/// controls size each segment to its label and do not fill the popover's width.
struct Segments<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var tint: (Value) -> Color? = { _ in nil }
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(title(option))
                        .font(selected ? OptionsType.bodyStrong : OptionsType.body)
                        .foregroundStyle(tint(option) ?? PopoverInk.primary.color)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.white.opacity(scheme == .dark ? 0.16 : 0.85))
                                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Each segment by its own name; the control's name goes on the group.
                .accessibilityLabel(title(option))
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .accessibilityElement(children: .contain)
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.07)))
    }
}

// MARK: - One elevation

/// Raised: a control resting on the panel, at the one height every pressable thing shares.
struct Raised<S: InsettableShape>: ViewModifier {
    let shape: S
    var fill: Color = Surface.cream

    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        content
            .background {
                shape.fill(fill)
                    .overlay(shape.strokeBorder(Elevation.controlEdge(dark: dark), lineWidth: 0.5))
                    .shadow(color: .black.opacity(Elevation.controlOpacity(dark: dark)), radius: Elevation.controlBlur / 2, y: Elevation.controlY)
            }
    }
}

/// Inset: what takes typing, a shade into the panel, with a hairline and no shadow.
struct Inset<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        content.background {
            shape.fill(Surface.tile)
                .overlay(shape.strokeBorder(PopoverInk.secondary.color.opacity(0.3), lineWidth: 0.5))
        }
    }
}

extension View {
    func raised<S: InsettableShape>(_ shape: S, fill: Color = Surface.cream) -> some View {
        modifier(Raised(shape: shape, fill: fill))
    }

    func inset<S: InsettableShape>(_ shape: S) -> some View {
        modifier(Inset(shape: shape))
    }
}

/// The popover's number field (a width, a height, a size in kB): inset, centred digits.
struct OptionsNumberField: View {
    let title: String
    @Binding var text: String
    var width: CGFloat = 58

    var body: some View {
        TextField(title, text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(OptionsType.body.monospacedDigit())
            .frame(width: width, height: 26)
            .inset(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityLabel(title)
    }
}

/// The popover's one charcoal action (Crop, Fit): raised like every control, chosen-charcoal.
struct CharcoalButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(OptionsType.bodyStrong)
                .foregroundStyle(Ink.onCharcoal)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .raised(Capsule(), fill: Ink.charcoal)
                .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
    }
}

/// The amber dot on the suggested tile; with "Differentiate without colour" on, a symbol.
private struct SuggestedMark: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

    var body: some View {
        if differentiate {
            StateMark(meaning: .decision).font(.system(size: 10, weight: .semibold)).padding(5)
        } else {
            Circle().fill(Ink.warm).frame(width: 6, height: 6).padding(7)
        }
    }
}
