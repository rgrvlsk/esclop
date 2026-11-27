// SPDX-License-Identifier: GPL-3.0-or-later
//
// The steps for each kind of file: a tab per section ("Any file", "Images"...), the steps as
// rows (drag to reorder, or Move Up and Move Down from the keyboard) and Add Step by category.

import EsclopCore
import EsclopPipelines
import SwiftUI

struct PipelineStepsSection: View {
    @Bindable var model: PipelineEditorModel
    /// The step the keyboard is on: ⌥⌘↑ and ⌥⌘↓ move it (`StepRowView`).
    @FocusState private var focusedStep: UUID?

    var body: some View {
        Group {
            // 21 pt above the label, as between the page's sections; 12 pt to the first step's
            // tile (7 here, 5 in the step's own padding).
            kinds.warmRow(top: 21, bottom: 7)
            if let index = model.draft.sections.firstIndex(where: { $0.id == model.sectionID }) {
                let kind = model.draft.sections[index].kind
                let steps = model.draft.sections[index].steps
                if steps.isEmpty {
                    Text(Strings.text("No steps yet. Add one below."))
                        .foregroundStyle(Ink.secondary)
                        .padding(.leading, 44)
                        .warmRow()
                }
                // Values, not `$model.draft.sections[index].steps`: the section at `index` can be
                // gone by the time a row is read (removed, or another pipeline opened).
                ForEach(steps) { step in
                    let position = steps.firstIndex { $0.id == step.id } ?? 0
                    let issues = model.check.issues[step.id] ?? []
                    StepRowView(
                        step: model.binding(for: step), kind: kind, number: position + 1, count: steps.count,
                        issues: issues, isReadOnly: model.isTemplate,
                        isOpen: Binding(
                            // A step with an error opens by itself, and closes when asked; its red
                            // mark stays on the heading. Fixing a value never folds it away.
                            get: { model.openedSteps.contains(step.id) || (issues.contains { $0.severity == .error } && !model.closedSteps.contains(step.id)) },
                            set: { open in
                                if open {
                                    model.openedSteps.insert(step.id)
                                    model.closedSteps.remove(step.id)
                                } else {
                                    model.openedSteps.remove(step.id)
                                    model.closedSteps.insert(step.id)
                                }
                            }
                        ),
                        move: { model.moveStep(step.id, by: $0) },
                        remove: {
                            // The ring goes on to the next step, or the one before at the end.
                            let next = steps.indices.contains(position + 1) ? steps[position + 1].id : position > 0 ? steps[position - 1].id : nil
                            let ringed = focusedStep == step.id
                            model.removeStep(step.id)
                            if ringed { focusedStep = next }
                        },
                        focus: $focusedStep,
                        // ↑ and ↓ take the keyboard to the step above or below.
                        neighbour: { delta in
                            if steps.indices.contains(position + delta) { focusedStep = steps[position + delta].id }
                        }
                    )
                    .warmRow(top: 0, bottom: 0)
                }
                // An example's steps stay where they are.
                .onMove(perform: model.isTemplate ? nil : { model.moveSteps(from: $0, to: $1) })
                // Its own 5 pt under the box, then Options' 16: 21, as between the page's sections.
                addStepRow(kind: kind, afterSteps: !steps.isEmpty)
                    .disabled(model.isTemplate)
                    .warmRow(top: 0, bottom: 0)
                if model.draft.sections.contains(where: { $0.kind != nil }) {
                    Text(Strings.text("A kind with its own steps runs those; any other kind runs the “Any file” steps."))
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.secondary)
                        .padding(.leading, 44)
                        .warmRow()
                }
            }
        }
    }

    /// Which kind's steps are shown, when the pipeline has steps for a kind; and the menu that
    /// gives a kind its own.
    private var kinds: some View {
        HStack(spacing: 8) {
            if model.draft.sections.count > 1 {
                Picker(Strings.text("Steps for"), selection: $model.sectionID) {
                    ForEach(model.draft.sections) { section in
                        Text(PipelineVocabulary.sectionTitle(section.kind)).tag(section.id)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Button(Strings.text("Remove These Steps"), systemImage: "minus.circle") { model.removeSection(model.sectionID) }
                    .disabled(model.isTemplate)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Ink.secondary)
                    .accessibilityLabel(Strings.format("Remove the steps for %@", PipelineVocabulary.sectionTitle(model.currentSection?.kind)))
                    .help(Strings.format("Remove the steps for %@", PipelineVocabulary.sectionTitle(model.currentSection?.kind)))
            } else {
                Text(Strings.text("Steps")).warmLabel().accessibilityAddTraits(.isHeader)
            }
            Spacer()
            if model.draft.sections.count > 1 { addKindMenu }
        }
        // With one list of steps the row is as tall as its label, so the menu hangs at its
        // trailing edge without adding to it; beside the kinds' picker it takes its own place.
        .overlay(alignment: .trailing) {
            if model.draft.sections.count <= 1 { addKindMenu }
        }
    }

    /// Gives one kind its own steps; gone once every kind has them.
    @ViewBuilder private var addKindMenu: some View {
        if !missingKinds.isEmpty {
            Menu(Strings.text("Add Steps for One Kind")) {
                ForEach(missingKinds, id: \.self) { kind in
                    Button(PipelineVocabulary.sectionTitle(kind)) { model.addSection(kind) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            // The borderless menu keeps 6 pt after its chevron: the chevron ends on the tiles' edge.
            .padding(.trailing, -6)
            .font(.system(size: 12))
            .disabled(model.isTemplate)
            .help(Strings.text("Give one kind of file its own steps"))
        }
    }

    private var missingKinds: [MediaKind?] {
        ([nil] + MediaKind.allCases.map(Optional.some)).filter { kind in
            !model.draft.sections.contains { $0.kind == kind }
        }
    }

    static func specs(in category: StepCategory, for kind: MediaKind?) -> [StepSpec] {
        PipelineLanguage.steps.filter { spec in
            guard spec.category == category else { return false }
            guard let kind else { return true }
            return spec.kinds.contains(kind)
        }
    }

    /// Adds a step and opens it on its settings.
    private func add(_ name: String) {
        model.addStep(name)
        if let added = model.currentSection?.steps.last { model.openedSteps.insert(added.id) }
    }

    /// "Add a step", dashed like a place still empty, at the end of the flow's line.
    private func addStepRow(kind: MediaKind?, afterSteps: Bool) -> some View {
        // The whole row opens the menu: the dashed + on the line and the dashed box.
        Menu {
            ForEach(StepCategory.allCases, id: \.self) { category in
                Section(PipelineVocabulary.categoryTitle(category)) {
                    ForEach(Self.specs(in: category, for: kind), id: \.name) { spec in
                        Button(PipelineVocabulary.stepTitle(spec.name)) { add(spec.name) }
                    }
                }
            }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                FlowRail(mark: .add, lineAbove: afterSteps, lineBelow: false, centre: 26)
                Text(Strings.text("Add a Step"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Ink.charcoalText)
                    .padding(.horizontal, Spacing.l)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                    .background(DashedOutline())
                    .padding(.vertical, 5)
            }
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(Strings.format("Add a step for %@", PipelineVocabulary.sectionTitle(kind)))
    }
}
