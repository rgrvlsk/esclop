// SPDX-License-Identifier: GPL-3.0-or-later
//
// One argument with the control its type calls for: a switch for true/false, a menu for a fixed
// set of words, a field for the rest with the catalog's suggestions beside it. Script code is
// monospaced so it reads as code.

import EsclopCore
import EsclopPipelines
import SwiftUI

struct ParamField: View {
    let param: ParamSpec
    let step: String
    /// The kind of file the step's section is for; nil for any file.
    var kind: MediaKind?
    @Binding var value: String?
    /// A problem names this setting: its field is outlined in the error red.
    var wrong = false

    @FocusState private var focused: Bool

    private var title: String { PipelineVocabulary.paramTitle(param.name) }
    private var effective: String { value ?? param.defaultValue ?? "" }
    private var isCode: Bool { step == "runScript" && (param.name == "code" || param.name == "path") }

    var body: some View {
        Group {
            switch param.type {
            case .boolean:
                Toggle(title, isOn: Binding(get: { effective == "true" }, set: { value = String($0) }))
                    .tint(Ink.charcoal)
            case let .choice(options) where step == "convert" && param.name == "to":
                // The formats people pick most for the kind as chips, the rest in a menu; the
                // step's name already says what they are.
                HStack(spacing: 8) {
                    let common = Self.commonFormats(kind).filter(options.contains)
                    ForEach(common, id: \.self) { option in
                        Button(Self.chipTitle(option)) { value = option }
                            .buttonStyle(ChoiceChipStyle(selected: effective == option))
                            .accessibilityLabel(Self.chipTitle(option))
                            .accessibilityAddTraits(effective == option ? .isSelected : [])
                    }
                    if !common.contains(effective), !effective.isEmpty {
                        Button(Self.chipTitle(effective)) {}
                            .buttonStyle(ChoiceChipStyle(selected: true))
                            .accessibilityAddTraits(.isSelected)
                    }
                    Menu(Strings.text("More formats")) {
                        ForEach(options.filter { !common.contains($0) }, id: \.self) { option in
                            Button(Self.chipTitle(option)) { value = option }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(.system(size: 13, weight: .medium))
                    .padding(.leading, 4)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(title)
            case let .choice(options) where options.count <= 5 && (param.required || param.defaultValue != nil):
                // A few words: chips, the chosen one charcoal.
                LabeledContent(title) {
                    HStack(spacing: 6) {
                        ForEach(options, id: \.self) { option in
                            Button(Self.chipTitle(option)) { value = option }
                                .buttonStyle(ChoiceChipStyle(selected: effective == option))
                                .accessibilityLabel(Self.chipTitle(option))
                                .accessibilityAddTraits(effective == option ? .isSelected : [])
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(title)
                }
            case let .integer(low?, high?) where high - low <= 100:
                // A bounded number, such as a quality: the slider fills the row, its figure after.
                HStack(spacing: 12) {
                    Text(title).foregroundStyle(Ink.text).fixedSize()
                    Slider(
                        value: Binding(get: { Double(Int(effective) ?? low) }, set: { value = String(Int($0.rounded())) }),
                        in: Double(low) ... Double(high), step: 1
                    )
                    .labelsHidden()
                    .tint(Ink.charcoal)
                    .accessibilityLabel(title)
                    .accessibilityValue(effective)
                    Text(effective)
                        .monospacedDigit()
                        .foregroundStyle(Ink.secondary)
                        .frame(minWidth: 28, alignment: .trailing)
                }
            case let .choice(options):
                Picker(title, selection: Binding(get: { effective }, set: { value = $0 })) {
                    if param.defaultValue == nil, !param.required {
                        Text(Strings.text("Not set")).tag("")
                    }
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
            case _ where isCode:
                // Code reads as code: full width, monospaced, as many lines as it has.
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                    TextField(title, text: Binding(get: { value ?? "" }, set: { value = $0 }), axis: .vertical)
                        .labelsHidden()
                        .focused($focused)
                        .textFieldStyle(WarmFieldStyle(focused: focused))
                        .font(.body.monospaced())
                        .lineLimit(1 ... 8)
                }
            default:
                LabeledContent(title) {
                    HStack(spacing: 4) {
                        // The default as the prompt, in the secondary ink.
                        WarmPlaceholder(text: value ?? "", prompt: param.defaultValue ?? "") {
                            TextField(title, text: Binding(get: { value ?? "" }, set: { value = $0 }), prompt: Text(""))
                                .labelsHidden()
                                .textFieldStyle(.plain)
                                .focused($focused)
                                // The drawn prompt is hidden from VoiceOver: the default, said as a hint.
                                .accessibilityHint((value ?? "").isEmpty && param.defaultValue != nil ? Strings.format("Default: %@", param.defaultValue ?? "") : "")
                        }
                        .font(isCode ? .body.monospaced() : .body)
                        .padding(.horizontal, 8)
                        .frame(minWidth: 120, minHeight: 26)
                        .background { WarmFieldGround() }
                        .overlay { if wrong { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Palette.error, lineWidth: 1) } }
                        .overlay { if focused { WarmFieldRing() } }
                        if !param.type.suggestions.isEmpty {
                            Menu {
                                ForEach(param.type.suggestions, id: \.self) { suggestion in
                                    Button(suggestion) { value = suggestion }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .accessibilityLabel(Strings.format("Suggestions for %@", title))
                        }
                    }
                }
            }
        }
        .help(PipelineVocabulary.paramHelp(step: step, param: param))
    }

    /// A format's own name on its chip ("WebP", "JPEG"); any other word as the file writes it.
    static func chipTitle(_ option: String) -> String {
        let names = ["webp": "WebP", "avif": "AVIF", "jpeg": "JPEG", "jpg": "JPEG", "png": "PNG", "gif": "GIF", "heic": "HEIC", "mp4": "MP4", "mov": "MOV", "mp3": "MP3", "pdf": "PDF"]
        return names[option.lowercased()] ?? option
    }

    /// The formats a convert step shows as chips, for its section's kind.
    static func commonFormats(_ kind: MediaKind?) -> [String] {
        switch kind {
        case .video: return ["mp4", "hevc", "webm", "gif"]
        case .audio: return ["m4a", "mp3", "ogg", "flac"]
        default: return ["webp", "avif", "jpeg", "png"]
        }
    }
}
