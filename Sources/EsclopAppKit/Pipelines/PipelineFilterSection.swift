// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Only files that…": the `if(...)` every section starts with, checked live against a sample
// file with the same evaluation the runner uses.

import AppKit
import EsclopCore
import EsclopPipelines
import SwiftUI

struct PipelineFilterSection: View {
    @Bindable var model: PipelineEditorModel

    var body: some View {
        Section {
            Toggle(isOn: $model.hasFilter) {
                Text(Strings.text("Only some files"))
                Text(Strings.text("Files that do not match are left alone."))
            }
            if let filter = Binding($model.draft.filter) {
                StepParamsEditor(step: filter, kind: nil)
                StepIssues(issues: model.check.issues[filter.wrappedValue.id] ?? [])
                HStack(spacing: 8) {
                    if let sample = model.sampleFile, let matches = model.filterMatches {
                        Image(systemName: matches ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(matches ? Palette.accent : .secondary)
                            .accessibilityHidden(true)
                        Text(matches
                            ? Strings.format("“%@” matches: the pipeline runs on it.", sample.lastPathComponent)
                            : Strings.format("“%@” does not match: it is left alone.", sample.lastPathComponent))
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(Strings.text("Choose a file to see whether the filter lets it through."))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(Strings.text("Choose a File…")) { chooseSample() }
                        .accessibilityLabel(Strings.text("Choose a file to check the filter with"))
                }
                .task(id: filter.wrappedValue) { await model.checkFilter() }
            }
        } header: {
            Text(Strings.text("Filter"))
        }
    }

    private func chooseSample() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.prompt = Strings.text("Check")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setSample(url)
    }
}
