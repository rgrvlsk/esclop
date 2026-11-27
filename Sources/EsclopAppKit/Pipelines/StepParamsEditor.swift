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
    /// The step's problems: one that names a setting shows under it.
    var issues: [PipelineDiagnostic] = []
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

    /// Whether a problem is about this setting: the parser names it in backticks.
    static func names(_ issue: PipelineDiagnostic, _ param: ParamSpec) -> Bool {
        issue.message.contains("`\(param.name)`")
    }

    var body: some View {
        if !params.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(shown, id: \.name) { param in
                    let own = issues.filter { Self.names($0, param) }
                    HStack(spacing: 6) {
                        ParamField(param: param, step: step.name, kind: kind, value: $step.values[param.name], wrong: !own.isEmpty)
                        if !param.required {
                            Button(Strings.text("Remove Option"), systemImage: "minus.circle") {
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
                    // Under its own field the problem need not name the field again.
                    if !own.isEmpty { StepIssues(issues: own, dropping: PipelineVocabulary.paramTitle(param.name)) }
                }
                if !hidden.isEmpty {
                    Menu {
                        ForEach(hidden, id: \.name) { param in
                            Button(PipelineVocabulary.paramTitle(param.name)) {
                                added.insert(param.name)
                                step.values[param.name] = param.defaultValue ?? param.type.suggestions.first ?? ""
                            }
                        }
                    } label: {
                        // The whole dashed capsule opens the menu. Something to add: dashed,
                        // like every place still empty.
                        Label(Strings.text("Add an Option"), systemImage: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Ink.text)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(DashedOutline(radius: 13))
                            .contentShape(Capsule())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .contentShape(.focusEffect, Capsule())
                    .padding(.top, 2)
                    .accessibilityLabel(Strings.format("Add an option to %@", PipelineVocabulary.stepTitle(step.name)))
                }
            }
        }
    }
}
