// SPDX-License-Identifier: GPL-3.0-or-later
//
// Format (docs/design/targets: pr4-options-popover-tabs): the suggestion first, when there is one
// to make, then the format tiles with their sizes up front, quality, metadata and the kind's own
// controls, then the rule. A click on an image's tile converts at once; a video's tile arms
// Convert, since a video takes a while (owner's decision). Compression's Adaptive · Lossless ·
// Aggressive lives in Settings; "Optimise harder" is one row here (lead's decision, after Clop).

import AppKit
import EsclopCore
import SwiftUI

struct OptimiseTab: View {
    @Bindable var model: OptionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.isSuggestionApplied, model.card.appliedRule == nil {
                SuggestionCard(model: model)
            } else if let rule = model.card.appliedRule {
                Label(Strings.format("Rule: %@", rule.choice.summary(input: model.inputFormat)), systemImage: "wand.and.stars")
                    .font(OptionsType.label)
                    .foregroundStyle(PopoverInk.secondary.color)
            }
            FormatOptions(model: model)
            if model.canMakeRule {
                RuleCheckbox(model: model)
            }
        }
    }
}

/// "WebP would be 410 kB · 33 % lighter, keep transparency", with Convert: the suggestion for the
/// file's origin, only while it is not the one applied.
struct SuggestionCard: View {
    let model: OptionsModel

    var body: some View {
        let suggestion = model.suggestion
        let request = EstimateRequest(choice: suggestion)
        let converts = suggestion.format.map { $0 != model.currentFormat } ?? false
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Group {
                    if converts, let format = suggestion.format, model.unavailable.contains(request) {
                        Text(Strings.format("Suggested: %@", format.displayName))
                    } else if converts, let format = suggestion.format {
                        HStack(spacing: 0) {
                            Text(Strings.format("%@ would be ", format.displayName))
                            EstimateText(model: model, request: request, approximate: false)
                        }
                    } else {
                        Text(Strings.text("Suggested for this file"))
                    }
                }
                .font(Typeface.smallHeading)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                Text(subtitle(request, namingFormat: !converts))
                    .font(OptionsType.label)
                    .foregroundStyle(PopoverInk.primary.color.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            Button { model.apply(suggestion) } label: {
                Text(converts ? Strings.text("Convert") : Strings.text("Apply"))
                    .font(OptionsType.bodyStrong)
                    .foregroundStyle(Ink.charcoal)
                    .environment(\.colorScheme, .light)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .raised(Capsule(), fill: .white)
                    .contentShape(Capsule())
            }
            .buttonStyle(PressScale())
            .disabled(model.card.isWorking)
            .accessibilityLabel(converts ? Strings.format("Convert to %@", suggestion.format?.displayName ?? "") : Strings.text("Apply"))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: OptionsType.radius, style: .continuous).fill(Surface.decision))
        .accessibilityElement(children: .combine)
    }

    /// "33 % lighter, keep transparency", or the suggestion in words: without the format when
    /// the heading already names it.
    private func subtitle(_ request: EstimateRequest, namingFormat: Bool) -> String {
        var parts: [String] = []
        if let bytes = model.estimate(request), let now = model.card.result?.bytesAfter, bytes < now {
            parts.append(Strings.format("%@ lighter", Figures.percent(before: now, after: bytes).replacingOccurrences(of: "−", with: "")))
        }
        parts.append(Suggestion.note(for: model.origin) ?? model.suggestion.summary(input: model.inputFormat, namingFormat: namingFormat))
        return parts.joined(separator: ", ")
    }
}

struct FormatOptions: View {
    @Bindable var model: OptionsModel

    /// Four tiles in a row; the rest are behind "More formats".
    static let shown = 4

    /// The tiles in view: the first four, with the file's own format always among them.
    static func shownFormats(_ formats: [OutputFormat], current: OutputFormat?) -> [OutputFormat] {
        let first = Array(formats.prefix(shown))
        guard let current, formats.contains(current), !first.contains(current) else { return first }
        return Array(first.prefix(shown - 1)) + [current]
    }

    var body: some View {
        let choice = model.card.choice
        let formats = model.formats
        let tiles = Self.shownFormats(formats, current: model.currentFormat)
        VStack(alignment: .leading, spacing: 8) {
            if !formats.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: Self.shown), spacing: 8) {
                    ForEach(tiles, id: \.self) { format in tile(format) }
                }
                HStack(alignment: .firstTextBaseline) {
                    if let note = Self.note(for: model.armed ?? model.currentFormat) {
                        Text(note).font(OptionsType.label).foregroundStyle(PopoverInk.secondary.color)
                    }
                    Spacer(minLength: 6)
                    if formats.count > tiles.count {
                        Menu(Strings.text("More formats")) {
                            ForEach(formats.filter { !tiles.contains($0) }, id: \.self) { format in
                                Button(format.displayName) { model.pick(format, keepBoth: NSEvent.modifierFlags.contains(.option)) }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .font(OptionsType.label)
                    }
                }
                if let armed = model.armed {
                    // A video's tile arms; this runs it.
                    Button { model.convertArmed() } label: {
                        Text(Strings.format("Convert to %@", armed.displayName))
                            .font(OptionsType.bodyStrong)
                            .foregroundStyle(Ink.onCharcoal)
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(Capsule().fill(Ink.charcoal))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressScale())
                }
            }

            if Self.hasQuality(model.armed ?? model.currentFormat, kind: model.kind) {
                HStack(spacing: 12) {
                    Text(Strings.text("Quality")).sectionLabel()
                    Slider(value: $model.quality, in: 5 ... 100) { editing in
                        if !editing { model.commitQuality() }
                    }
                    .tint(Ink.saving)
                    .disabled(model.card.isWorking)
                    .accessibilityLabel(Strings.text("Quality"))
                    .accessibilityValue(Text(verbatim: "\(Int(model.quality.rounded()))"))
                    Text(verbatim: "\(Int(model.quality.rounded()))")
                        .font(OptionsType.bodyStrong)
                        .monospacedDigit()
                        .frame(minWidth: 26, alignment: .trailing)
                }
                .padding(.top, 2)
            }

            OptionsRow {
                SwitchRow(title: Strings.text("Remove metadata"), isOn: Binding(
                    get: { choice.stripMetadata ?? model.stripsByDefault },
                    set: { value in model.update { $0.stripMetadata = value } }
                ))
            }
            if model.facts.hdr {
                OptionsRow {
                    SwitchRow(title: Strings.text("Convert HDR to SDR"), isOn: Binding(
                        get: { choice.keepHDR == false },
                        set: { value in model.update { $0.keepHDR = !value } }
                    ))
                }
            }
            kindControls(choice)
            HStack(spacing: 16) {
                if model.card.result?.backup != nil {
                    Button(Strings.text("Restore original")) { model.app.perform(.undo, on: model.card) }
                        .help("⌘Z")
                }
                // Charcoal like every text button: amber means a decision is needed.
                Button(Strings.text("Optimise harder")) { model.optimiseHarder() }
                    .help(CardKeys.onTheResult(Strings.text("Run it again with aggressive compression"), key: "⌘A"))
            }
            .buttonStyle(.plain)
            .font(OptionsType.label.weight(.semibold))
            .foregroundStyle(Ink.charcoalText)
            .disabled(model.card.isWorking)
        }
    }

    private func tile(_ format: OutputFormat) -> some View {
        FormatTile(
            title: format.displayName, model: model, request: model.request(format: format),
            selected: (model.armed ?? model.currentFormat) == format,
            suggested: model.suggestion.format == format && model.currentFormat != format
        ) { model.pick(format, keepBoth: NSEvent.modifierFlags.contains(.option)) }
        .disabled(model.card.isWorking)
        .contextMenu {
            Button(Strings.text("Convert and Keep Both")) { model.choose(format: format, keepBoth: true) }
        }
    }

    /// Every picture and video has a quality: for PNG and GIF it sets how far their colours are
    /// reduced, for the rest the encoder's quality.
    static func hasQuality(_ format: OutputFormat?, kind: MediaKind?) -> Bool {
        kind == .image || kind == .video
    }

    /// What the chosen format is good for, in one line.
    static func note(for format: OutputFormat?) -> String? {
        switch format {
        case .png?: return Strings.text("PNG keeps sharp edges and transparency; its colours are reduced.")
        case .jpeg?: return Strings.text("JPEG suits photos; it has no transparency.")
        case .webp?: return Strings.text("WebP is small and opens everywhere.")
        case .avif?: return Strings.text("AVIF is the smallest; older apps may not open it.")
        default: return nil
        }
    }

    @ViewBuilder private func kindControls(_ choice: OptimiseChoice) -> some View {
        switch model.kind {
        case .video?:
            OptionsRow { SpeedMenu(model: model) }
            OptionsRow {
                SwitchRow(title: Strings.text("Remove audio"), isOn: Binding(get: { choice.removeAudio }, set: { value in model.update { $0.removeAudio = value } }))
            }
        case .pdf?:
            Text(Strings.text("Resolution")).sectionLabel()
            Segments(options: [72, 150, 300], selection: Binding(get: { choice.pdfDPI ?? 150 }, set: { value in model.update { $0.pdfDPI = value } }), title: { "\($0) DPI" })
                .accessibilityLabel(Strings.text("Resolution"))
        case .audio?:
            AudioControls(model: model)
        default:
            EmptyView()
        }
    }
}

/// A row that holds a control ("Remove metadata" and its switch): flat, since only what is
/// pressed is raised.
struct OptionsRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            // One height for every flat row.
            .frame(minHeight: OptionsType.rowHeight)
            .background(RoundedRectangle(cornerRadius: OptionsType.radius, style: .continuous).fill(Surface.cream))
    }
}

struct SpeedMenu: View {
    let model: OptionsModel

    var body: some View {
        let speed = model.card.choice.playbackSpeed ?? 1
        HStack {
            Text(Strings.text("Playback speed"))
            Spacer()
            Picker(Strings.text("Playback speed"), selection: Binding(get: { speed }, set: { value in model.update { $0.playbackSpeed = value == 1 ? nil : value } })) {
                Text(Strings.text("Normal")).tag(1.0)
                ForEach([1.25, 1.5, 2, 4], id: \.self) { Text(verbatim: "\(Figures.number($0, locale: Strings.locale))×").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        // The result's ⌘X opens the options here.
        .help(CardKeys.onTheResult(Strings.text("Playback speed"), key: "⌘X"))
        .frame(minHeight: 28)
    }
}

/// Bitrate and loudness, in Optimise and on the Sound tab.
struct AudioControls: View {
    let model: OptionsModel
    static let bitrates = [64, 96, 128, 160, 192, 256]

    var body: some View {
        let choice = model.card.choice
        let bitrate = choice.audioBitrate ?? 160
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: Strings.text("Bitrate")) {
                HStack(spacing: 0) {
                    Text(verbatim: "\(bitrate) kbps · ")
                    EstimateText(model: model, request: EstimateRequest(choice: choice))
                }
            }
            Segments(options: Self.bitrates, selection: Binding(get: { bitrate }, set: { value in model.update { $0.audioBitrate = value } }), title: { "\($0)" })
                .accessibilityLabel(Strings.text("Bitrate"))
            SwitchRow(title: Strings.format("Normalise loudness (%@)", Figures.lufs(-16)), isOn: Binding(
                get: { choice.loudness != nil },
                set: { value in model.update { $0.loudness = value ? -16 : nil } }
            ))
        }
    }
}

/// "Always apply to PNG screenshots", and what that will do next time.
struct RuleCheckbox: View {
    @Bindable var model: OptionsModel

    var body: some View {
        let rule = model.rule
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { rule != nil }, set: { model.ruleOn = $0 })) {
                Text(ClipboardRule.checkboxTitle(origin: model.origin, inputType: model.card.inputType ?? "")).font(OptionsType.label)
            }
            .switchLabel(title: ClipboardRule.checkboxTitle(origin: model.origin, inputType: model.card.inputType ?? ""), hint: nil)

            .toggleStyle(.checkbox)
            .disabled(model.card.isWorking)
            if let rule {
                Text(rule.promise())
                    .font(OptionsType.label)
                    .foregroundStyle(PopoverInk.secondary.color)
                    .padding(.leading, 20)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The box stays ticked for the stored rule; this result was made another way.
            if model.ruleDiffers {
                Button(Strings.text("Use this from now on")) { model.useChoiceAsRule() }
                    .buttonStyle(.plain)
                    .font(OptionsType.label.weight(.semibold))
                    .foregroundStyle(Ink.charcoalText)
                    .padding(.leading, 20)
                    .disabled(model.card.isWorking)
                    .help(Strings.text("Store this choice as the rule"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: OptionsType.rowHeight, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: OptionsType.radius, style: .continuous).fill(Surface.cream))
    }
}
