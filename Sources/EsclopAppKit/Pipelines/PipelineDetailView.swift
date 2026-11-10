// SPDX-License-Identifier: GPL-3.0-or-later
//
// One pipeline: its name, what runs it, the filter, the steps for each kind of file, and
// "Try it". The Form/Text switch shows the same pipeline as the file holds it.

import AppKit
import EsclopCore
import EsclopPipelines
import SwiftUI

struct PipelineDetailView: View {
    @Bindable var model: PipelineEditorModel

    var body: some View {
        Form {
            header
            if model.showsText {
                PipelineTextSection(model: model)
            } else {
                Group {
                    PipelineStepsSection(model: model)
                    PipelineFilterSection(model: model)
                    PipelineTriggersSection(model: model)
                    optionsSection
                }
                .disabled(model.isTemplate)
            }
            if model.draft.hasScripts { scriptNotice }
            PipelineTryItSection(model: model)
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(Strings.text("View"), selection: $model.isTextView) {
                    Text(Strings.text("Form")).tag(false)
                    Text(Strings.text("Text")).tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(Strings.text("Show the pipeline as a form or as text"))
                .help(Strings.text("Show the pipeline as a form or as text"))
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if case .saved = model.selection {
                    Button(Strings.text("Run on Files…"), systemImage: "play") { chooseAndRun() }
                        .disabled(model.hasChanges)
                        .help(Strings.text("Run the saved pipeline on files you choose"))
                }
                if !model.isTemplate {
                    Button(Strings.text("Revert"), systemImage: "arrow.uturn.backward") { model.revert() }
                        .disabled(!model.hasChanges || model.selection == .new)
                    Button(Strings.text("Save"), systemImage: "square.and.arrow.down") { model.save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!model.hasChanges || !model.check.isValid)
                }
            }
        }
    }

    // MARK: Parts

    private var header: some View {
        Section {
            if model.isTemplate {
                HStack(spacing: 10) {
                    Image(systemName: "lock").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(Strings.text("A built-in template. Duplicate it to make your own version."))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(Strings.text("Duplicate")) { model.duplicate() }
                        .accessibilityLabel(Strings.format("Duplicate %@", model.draft.name))
                }
            }
            TextField(Strings.text("Name"), text: $model.draft.name)
                .disabled(model.isTemplate)
            TextField(Strings.text("Description"), text: $model.draft.description, prompt: Text(Strings.text("What it is for")))
                .disabled(model.isTemplate)
            ForEach(model.check.general, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.circle.fill").foregroundStyle(Palette.error)
            }
            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.error)
            }
        }
    }

    private var optionsSection: some View {
        Section(Strings.text("Options")) {
            TitledToggle(
                title: Strings.text("Optimise first"),
                subtitle: Strings.text("Compress the file before the steps run, unless the first step re-encodes it anyway."),
                isOn: $model.draft.optimiseFirst
            )
            TitledToggle(
                title: Strings.text("Run without a floating result"),
                subtitle: Strings.text("Nothing appears on screen when it runs on its own."),
                isOn: $model.draft.hideResult
            )

        }
    }

    private var scriptNotice: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "terminal").foregroundStyle(Palette.caution).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(Strings.text("This pipeline runs scripts"))
                        .font(.headline)
                    Text(Strings.text("Its script steps run code on your Mac with your permissions. AI agents may only run this pipeline when “Agents may run scripts” is on."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(Strings.text("Open Agents and MCP Settings")) {
                        if let url = URL(string: "esclop://settings/agents/allowRunScripts") { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.link)
                    .foregroundStyle(Palette.accent)
                }
            }
        }
    }

    private func chooseAndRun() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = Strings.text("Run")
        guard panel.runModal() == .OK else { return }
        model.run(on: panel.urls)
    }
}
