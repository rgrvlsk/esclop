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
    @Binding var value: String?

    private var title: String { PipelineVocabulary.paramTitle(param.name) }
    private var effective: String { value ?? param.defaultValue ?? "" }
    private var isCode: Bool { step == "runScript" && (param.name == "code" || param.name == "path") }

    var body: some View {
        Group {
            switch param.type {
            case .boolean:
                Toggle(title, isOn: Binding(get: { effective == "true" }, set: { value = String($0) }))
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
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .lineLimit(1 ... 8)
                }
            default:
                LabeledContent(title) {
                    HStack(spacing: 4) {
                        TextField(title, text: Binding(get: { value ?? "" }, set: { value = $0 }), prompt: Text(param.defaultValue ?? ""))
                            .labelsHidden()
                            .font(isCode ? .body.monospaced() : .body)
                            .frame(minWidth: 120)
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
}
