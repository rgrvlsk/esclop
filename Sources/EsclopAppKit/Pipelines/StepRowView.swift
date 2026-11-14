// SPDX-License-Identifier: GPL-3.0-or-later
//
// One step: its title and language name, its arguments with a control for each type, what the
// parser says about it, and buttons to move or remove it. A script step shows its code plainly.

import EsclopCore
import EsclopPipelines
import SwiftUI

struct StepRowView: View {
    @Binding var step: StepDraft
    let kind: MediaKind?
    let number: Int
    let count: Int
    let issues: [PipelineDiagnostic]
    let move: (Int) -> Void
    let remove: () -> Void

    private var title: String { PipelineVocabulary.stepTitle(step.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 16, alignment: .trailing)
                    .accessibilityHidden(true)
                Image(systemName: symbol).foregroundStyle(step.isScript ? Palette.caution : Ink.charcoalText).frame(width: 18).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(step.name).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .help(step.spec.map(PipelineVocabulary.stepHelp) ?? "")
                Spacer()
                Button(Strings.text("Move Up"), systemImage: "chevron.up") { move(-1) }
                    .disabled(number == 1)
                    .accessibilityLabel(Strings.format("Move %@ up", title))
                Button(Strings.text("Move Down"), systemImage: "chevron.down") { move(1) }
                    .disabled(number == count)
                    .accessibilityLabel(Strings.format("Move %@ down", title))
                Button(Strings.text("Remove Step"), systemImage: "minus.circle", action: remove)
                    .accessibilityLabel(Strings.format("Remove %@", title))
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            if step.isScript {
                Text(Strings.text("Runs code on your Mac. Read it before you run the pipeline."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 50)
            }
            StepParamsEditor(step: $step, kind: kind)
                .padding(.leading, 50)
            StepIssues(issues: issues)
                .padding(.leading, 50)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.format("Step %d of %d: %@", number, count, title))
        .accessibilityAction(named: Strings.text("Move Up")) { move(-1) }
        .accessibilityAction(named: Strings.text("Move Down")) { move(1) }
        .accessibilityAction(named: Strings.text("Remove Step"), remove)
    }

    private var symbol: String {
        switch step.spec?.category {
        case .processing: "wand.and.rays"
        case .fileOperation: "folder"
        case .filter: "line.3.horizontal.decrease"
        case .mediaSpecific: "waveform"
        case .action: step.isScript ? "terminal" : "square.and.arrow.up"
        case nil: "questionmark"
        }
    }
}
