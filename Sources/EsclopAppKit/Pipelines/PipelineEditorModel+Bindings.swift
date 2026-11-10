// SPDX-License-Identifier: GPL-3.0-or-later
//
// Bindings for the editor's rows that survive their step going away. A row can still be read
// in the update where its step was removed, its section dropped, the filter turned off or
// another pipeline opened; a binding forced onto the old place (`Binding($optional)`, a
// `ForEach` over `$sections[index].steps`) traps there. These look the step up by its id on
// every read, fall back to the value the row was made with, and drop writes to a step that is
// no longer in the draft.

import SwiftUI

extension PipelineEditorModel {
    /// A step of the draft, the filter included, by id.
    func step(_ id: UUID) -> StepDraft? {
        if draft.filter?.id == id { return draft.filter }
        for section in draft.sections {
            if let step = section.steps.first(where: { $0.id == id }) { return step }
        }
        return nil
    }

    /// Writes a step back where it is; does nothing when it is gone.
    func update(_ step: StepDraft) {
        if draft.filter?.id == step.id {
            draft.filter = step
            return
        }
        for index in draft.sections.indices {
            if let position = draft.sections[index].steps.firstIndex(where: { $0.id == step.id }) {
                draft.sections[index].steps[position] = step
                return
            }
        }
    }

    /// A binding to `step` that never assumes it still exists.
    func binding(for step: StepDraft) -> Binding<StepDraft> {
        Binding(
            get: { [weak self] in self?.step(step.id) ?? step },
            set: { [weak self] in self?.update($0) }
        )
    }
}
