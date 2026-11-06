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
        .foregroundStyle(.secondary)
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

    var body: some View {
        Group {
            if let request, let bytes = model.estimate(request) {
                Text("≈\u{00A0}" + Figures.bytes(bytes))
            } else if let request, model.unavailable.contains(request) {
                Text(verbatim: "—").accessibilityLabel(Strings.text("No estimate"))
            } else if request != nil {
                Text("≈\u{00A0}000 kB").redacted(reason: .placeholder)
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

/// A format with its estimate, on two lines.
struct FormatTile: View {
    let title: String
    let model: OptionsModel
    let request: EstimateRequest
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title).font(OptionsType.bodyStrong)
                EstimateText(model: model, request: request).font(OptionsType.label).foregroundStyle(selected ? Palette.accent : .secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(TileStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct TileStyle: ButtonStyle {
    var selected: Bool
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .foregroundStyle(selected ? Palette.accent : .primary)
            .background(shape.fill(selected ? Palette.accent.opacity(0.12) : Color.primary.opacity(configuration.isPressed ? 0.1 : 0.05)))
            .overlay(shape.strokeBorder(selected ? Palette.accent : Color.primary.opacity(0.12), lineWidth: 1))
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

struct ChipStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Palette.accent : .primary)
            .background(Capsule().fill(selected ? Palette.accent.opacity(0.12) : Color.primary.opacity(configuration.isPressed ? 0.1 : 0.05)))
            .overlay(Capsule().strokeBorder(selected ? Palette.accent : Color.primary.opacity(0.12), lineWidth: 1))
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
                Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
                Text(title)
                Spacer(minLength: 8)
                if let detail { Text(detail).foregroundStyle(.secondary).monospacedDigit() }
                if chevron { Image(systemName: "chevron.right").font(OptionsType.label.weight(.semibold)).foregroundStyle(.tertiary) }
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
                .tint(Palette.accent)
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
                        .foregroundStyle(tint(option) ?? .primary)
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
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.07)))
    }
}
