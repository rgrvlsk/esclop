// SPDX-License-Identifier: GPL-3.0-or-later
//
// A step's arguments: the required ones and the ones it sets, each with the control its type
// calls for, and "Add an Option" for the rest. Values go in as typed; the parser checks them.

import EsclopCore
import EsclopPipelines
import SwiftUI

struct StepParamsEditor: View {
    @Binding var step: StepDraft
    let kind: MediaKind?
    /// Options added in this session, shown even while still empty.
    @State private var added: Set<String> = []

    private var params: [ParamSpec] {
        (step.spec?.params ?? []).filter { param in
            guard let kinds = param.kinds, let kind else { return true }
            return kinds.contains(kind)
        }
    }

    private var shown: [ParamSpec] {
        params.filter { $0.required || step.values[$0.name] != nil || added.contains($0.name) }
    }

    private var hidden: [ParamSpec] {
        params.filter { param in !shown.contains { $0.name == param.name } }
    }

    var body: some View {
        if !params.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(shown, id: \.name) { param in
                    HStack(spacing: 6) {
                        ParamField(param: param, step: step.name, value: $step.values[param.name])
                        if !param.required {
                            Button(Strings.text("Remove Option"), systemImage: "xmark.circle") {
                                step.values[param.name] = nil
                                added.remove(param.name)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Strings.format("Remove %@", PipelineVocabulary.paramTitle(param.name)))
                            .help(Strings.text("Leave it out: the step uses its default"))
                        }
                    }
                }
                if !hidden.isEmpty {
                    Menu(Strings.text("Add an Option")) {
                        ForEach(hidden, id: \.name) { param in
                            Button(PipelineVocabulary.paramTitle(param.name)) {
                                added.insert(param.name)
                                step.values[param.name] = param.defaultValue ?? param.type.suggestions.first ?? ""
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel(Strings.format("Add an option to %@", PipelineVocabulary.stepTitle(step.name)))
                }
            }
        }
    }
}
