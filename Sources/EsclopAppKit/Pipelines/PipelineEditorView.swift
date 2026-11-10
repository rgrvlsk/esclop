// SPDX-License-Identifier: GPL-3.0-or-later
//
// The pipeline editor window: saved pipelines and built-in templates on the left, the selected
// one on the right. Templates are read-only; Duplicate makes an editable copy.

import EsclopCore
import EsclopPipelines
import SwiftUI

public struct PipelineEditorView: View {
    @Bindable var model: PipelineEditorModel
    @State private var confirmingDelete = false

    public init(model: PipelineEditorModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            if model.selection == nil {
                ContentUnavailableView(Strings.text("No pipeline selected"), systemImage: "wand.and.rays", description: Text(Strings.text("Choose one on the left or make a new one.")))
            } else {
                PipelineDetailView(model: model)
            }
        }
        .tint(Palette.accent)
        .navigationTitle(Strings.text("Pipelines"))
        .confirmationDialog(
            Strings.format("Save the changes to “%@”?", model.draft.name), isPresented: $model.isAskingToSave, titleVisibility: .visible
        ) {
            Button(Strings.text("Save")) {
                let next = model.pendingSelection
                model.save()
                if model.failure == nil { model.select(next) }
            }
            Button(Strings.text("Discard Changes"), role: .destructive) { model.select(model.pendingSelection) }
            Button(Strings.text("Cancel"), role: .cancel) { model.pendingSelection = nil }
        }
        .confirmationDialog(Strings.format("Delete “%@”?", model.draft.name), isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(Strings.text("Move to the Trash"), role: .destructive) { model.delete() }
        } message: {
            Text(Strings.text("The pipeline file goes to the Trash, so you can put it back from there."))
        }
    }

    private var sidebar: some View {
        List(selection: $model.listSelection) {
            Section(Strings.text("Your pipelines")) {
                if model.saved.isEmpty, model.selection != .new {
                    Text(Strings.text("None yet")).foregroundStyle(.secondary)
                }
                if model.selection == .new {
                    PipelineListRow(name: model.draft.name, icon: model.draft.icon, problem: nil, isTemplate: false)
                        .tag(PipelineEditorModel.Selection.new)
                }
                ForEach(model.saved, id: \.name) { entry in
                    PipelineListRow(
                        name: entry.name, icon: entry.pipeline?.icon ?? "",
                        problem: entry.pipeline == nil ? Strings.text("Has errors") : nil, isTemplate: false
                    )
                    .tag(PipelineEditorModel.Selection.saved(entry.name))
                }
            }
            Section(Strings.text("Templates")) {
                ForEach(model.templates, id: \.name) { template in
                    PipelineListRow(name: template.name, icon: template.icon ?? "", problem: nil, isTemplate: true)
                        .tag(PipelineEditorModel.Selection.template(template.name))
                }
            }
        }
        .accessibilityLabel(Strings.text("Pipelines"))
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 4) {
                Button(Strings.text("New Pipeline"), systemImage: "plus") { model.newPipeline() }
                    .keyboardShortcut("n", modifiers: .command)
                Button(Strings.text("Duplicate"), systemImage: "plus.square.on.square") { model.duplicate() }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(model.selection == nil || model.selection == .new)
                Button(Strings.text("Delete"), systemImage: "trash") { confirmingDelete = true }
                    .disabled(!isSaved)
                Spacer()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private var isSaved: Bool { if case .saved = model.selection { return true } else { return false } }
}
