// SPDX-License-Identifier: GPL-3.0-or-later
//
// Optimise: the suggestion from the file's origin (or the rule that was applied) first, then the
// folded "Format and options" group, then the rule checkbox (DESIGN.md › Options popover).

import AppKit
import EsclopCore
import SwiftUI

struct OptimiseTab: View {
    @Bindable var model: OptionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SuggestionCard(model: model)
            Button {
                model.showsFormatOptions.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(OptionsType.label.weight(.semibold))
                        .rotationEffect(.degrees(model.showsFormatOptions ? 90 : 0))
                    Text(Strings.text("Format and options")).font(OptionsType.bodyStrong)
                    Spacer()
                }
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(model.showsFormatOptions ? Strings.text("Expanded") : Strings.text("Collapsed"))

            if model.showsFormatOptions {
                FormatOptions(model: model).transition(.opacity)
            }
            if model.canMakeRule {
                RuleCheckbox(model: model)
            }
        }
    }
}

/// The origin, the suggestion and whether it is the one applied; with a rule, the rule's choice
/// and the default suggestion as a secondary line.
struct SuggestionCard: View {
    let model: OptionsModel

    var body: some View {
        let rule = model.card.appliedRule
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(model.originLabel)
            } icon: {
                Image(systemName: rule == nil ? model.origin.symbol : "wand.and.stars")
            }
            .font(OptionsType.label)
            .foregroundStyle(PopoverInk.secondary.color)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule == nil ? Strings.text("Suggestion") : Strings.text("Rule")).font(OptionsType.bodyStrong)
                    Text(rule.map { $0.choice.summary(input: model.inputFormat) } ?? model.suggestionText).font(OptionsType.body)
                    if rule != nil {
                        Text(Strings.format("Suggested: %@", model.suggestionText)).font(OptionsType.label).foregroundStyle(PopoverInk.secondary.color)
                    }
                }
                Spacer(minLength: 8)
                if rule == nil {
                    if model.isSuggestionApplied {
                        Label(Strings.text("Applied"), systemImage: "checkmark").font(OptionsType.label).foregroundStyle(PopoverInk.accent.color)
                    } else {
                        Button(Strings.text("Apply")) { model.apply(model.suggestion) }
                            .controlSize(.small)
                            .disabled(model.card.isWorking)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: OptionsType.radius, style: .continuous).fill(Ink.warm.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: OptionsType.radius, style: .continuous).strokeBorder(Ink.warm.opacity(0.18), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

struct FormatOptions: View {
    @Bindable var model: OptionsModel

    var body: some View {
        let choice = model.card.choice
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: Strings.text("Compression")) { Text(choice.compression.title) }
            Segments(
                options: OptimiseChoice.Compression.allCases,
                selection: Binding(get: { choice.compression }, set: { model.choose(compression: $0) }),
                title: { $0.title }, tint: { $0 == .aggressive ? PopoverInk.warm.color : nil }
            )
            .disabled(model.card.isWorking)
            .accessibilityLabel(Strings.text("Compression"))

            if !model.formats.isEmpty {
                SectionLabel(title: Strings.text("Format")) { Text(Strings.text("⌥ keeps both")) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(model.formats, id: \.self) { format in
                        FormatTile(
                            title: format.displayName, model: model, request: model.request(format: format),
                            selected: model.currentFormat == format
                        ) {
                            model.choose(format: format, keepBoth: NSEvent.modifierFlags.contains(.option))
                        }
                        .disabled(model.card.isWorking)
                    }
                }
            }

            if model.kind == .image || model.kind == .video {
                SectionLabel(title: Strings.text("Quality")) {
                    HStack(spacing: 0) {
                        Text(verbatim: "\(Int(model.quality.rounded()))\u{00A0}% · ")
                        EstimateText(model: model, request: model.qualityRequest)
                    }
                }
                Slider(value: $model.quality, in: 5 ... 100) { editing in
                    if !editing { model.commitQuality() }
                }
                .disabled(model.card.isWorking)
                .accessibilityLabel(Strings.text("Quality"))
            }

            SwitchRow(title: Strings.text("Strip metadata"), isOn: Binding(
                get: { choice.stripMetadata ?? EsclopSettings.stripMetadata.value(in: model.app.settings) },
                set: { value in model.update { $0.stripMetadata = value } }
            ))
            if model.facts.hdr {
                SwitchRow(title: Strings.text("Convert HDR to SDR"), isOn: Binding(
                    get: { choice.keepHDR == false },
                    set: { value in model.update { $0.keepHDR = !value } }
                ))
            }
            kindControls(choice)
            DrillRow(symbol: "arrow.uturn.backward", title: Strings.text("Restore original"), detail: "⌘Z", chevron: false) {
                model.app.perform(.undo, on: model.card)
            }
            .disabled(model.card.result?.backup == nil)
        }
    }

    @ViewBuilder private func kindControls(_ choice: OptimiseChoice) -> some View {
        switch model.kind {
        case .video?:
            DrillRow(symbol: "cpu", title: Strings.text("Re-optimise with"), detail: choice.videoEncoder?.displayName ?? Strings.text("Default")) {
                model.drill = .encoder
            }
            SpeedMenu(model: model)
            SwitchRow(title: Strings.text("Remove audio"), isOn: Binding(get: { choice.removeAudio }, set: { value in model.update { $0.removeAudio = value } }))
            DrillRow(symbol: "photo", title: Strings.text("Convert to GIF"), chevron: false) { model.choose(format: .gifVideo, keepBoth: true) }
        case .pdf?:
            SectionLabel(title: Strings.text("Resolution")) { Text(verbatim: "\(choice.pdfDPI ?? 150) DPI") }
            Segments(options: [72, 150, 300], selection: Binding(get: { choice.pdfDPI ?? 150 }, set: { value in model.update { $0.pdfDPI = value } }), title: { "\($0) DPI" })
                .accessibilityLabel(Strings.text("Resolution"))
        case .audio?:
            AudioControls(model: model)
        default:
            EmptyView()
        }
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
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.vertical, 4)
            Toggle(isOn: $model.ruleOn) {
                Text(ClipboardRule.checkboxTitle(origin: model.origin, inputType: model.card.inputType ?? "")).font(OptionsType.label)
            }
            .switchLabel(title: ClipboardRule.checkboxTitle(origin: model.origin, inputType: model.card.inputType ?? ""), hint: nil)

            .toggleStyle(.checkbox)
            .disabled(model.card.isWorking)
            if model.ruleOn, let origin = model.card.fileOrigin, let input = model.card.inputType {
                Text(ClipboardRule(origin: origin, inputType: input, choice: model.card.appliedRule?.choice ?? model.card.choice).promise())
                    .font(OptionsType.label)
                    .foregroundStyle(PopoverInk.secondary.color)
                    .padding(.leading, 20)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
