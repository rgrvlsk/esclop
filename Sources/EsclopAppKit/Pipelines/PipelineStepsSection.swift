// SPDX-License-Identifier: GPL-3.0-or-later
//
// The steps for each kind of file: a tab per section ("Any file", "Images"...), the steps as
// rows (drag to reorder, or Move Up and Move Down from the keyboard) and Add Step by category.

import EsclopCore
import EsclopPipelines
import SwiftUI

struct PipelineStepsSection: View {
    @Bindable var model: PipelineEditorModel

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Picker(Strings.text("Steps for"), selection: $model.sectionID) {
                    ForEach(model.draft.sections) { section in
                        Text(PipelineVocabulary.sectionTitle(section.kind)).tag(section.id)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                Menu(Strings.text("Steps for a Kind")) {
                    ForEach(missingKinds, id: \.self) { kind in
                        Button(PipelineVocabulary.sectionTitle(kind)) { model.addSection(kind) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(missingKinds.isEmpty)
                .help(Strings.text("Give one kind of file its own steps"))
                if model.draft.sections.count > 1 {
                    Button(Strings.text("Remove These Steps"), systemImage: "minus.circle") { model.removeSection(model.sectionID) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Strings.format("Remove the steps for %@", PipelineVocabulary.sectionTitle(model.currentSection?.kind)))
                        .help(Strings.format("Remove the steps for %@", PipelineVocabulary.sectionTitle(model.currentSection?.kind)))
                }
            }
            if let index = model.draft.sections.firstIndex(where: { $0.id == model.sectionID }) {
                let kind = model.draft.sections[index].kind
                let steps = model.draft.sections[index].steps
                if steps.isEmpty {
                    Text(Strings.text("No steps yet. Add one below.")).foregroundStyle(.secondary)
                }
                // Values, not `$model.draft.sections[index].steps`: the section at `index` can be
                // gone by the time a row is read (removed, or another pipeline opened).
                ForEach(steps) { step in
                    let position = steps.firstIndex { $0.id == step.id } ?? 0
                    StepRowView(
                        step: model.binding(for: step), kind: kind, number: position + 1, count: steps.count,
                        issues: model.check.issues[step.id] ?? [],
                        move: { model.moveStep(step.id, by: $0) }, remove: { model.removeStep(step.id) }
                    )
                }
                .onMove { model.moveSteps(from: $0, to: $1) }
                addStepMenu(kind: kind)
            }
        } header: {
            Text(Strings.text("Steps"))
        } footer: {
            Text(sectionFooter)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var missingKinds: [MediaKind?] {
        ([nil] + MediaKind.allCases.map(Optional.some)).filter { kind in
            !model.draft.sections.contains { $0.kind == kind }
        }
    }

    private var sectionFooter: String {
        guard model.draft.sections.contains(where: { $0.kind != nil }) else {
            return Strings.text("These steps run for every kind of file, in order.")
        }
        return Strings.text("A kind with its own steps runs those; any other kind runs the “Any file” steps.")
    }

    static func specs(in category: StepCategory, for kind: MediaKind?) -> [StepSpec] {
        PipelineLanguage.steps.filter { spec in
            guard spec.category == category else { return false }
            guard let kind else { return true }
            return spec.kinds.contains(kind)
        }
    }

    private func addStepMenu(kind: MediaKind?) -> some View {
        Menu {
            ForEach(StepCategory.allCases, id: \.self) { category in
                Section(PipelineVocabulary.categoryTitle(category)) {
                    ForEach(Self.specs(in: category, for: kind), id: \.name) { spec in
                        Button(PipelineVocabulary.stepTitle(spec.name)) { model.addStep(spec.name) }
                    }
                }
            }
        } label: {
            Label(Strings.text("Add Step"), systemImage: "plus")
        }
        .fixedSize()
        .accessibilityLabel(Strings.format("Add a step for %@", PipelineVocabulary.sectionTitle(kind)))
    }
}
