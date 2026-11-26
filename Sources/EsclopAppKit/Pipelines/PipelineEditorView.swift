// SPDX-License-Identifier: GPL-3.0-or-later
//
// The pipeline editor window (`pr9-pipeline-editor`): your pipelines and the built-in examples on
// the left, the selected one on the right. Examples are read-only; Make It Mine makes an editable
// copy. Duplicate and Delete are in a row's context menu and the toolbar.

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
            Button(Strings.text("Move to Trash"), role: .destructive) { model.delete() }
        } message: {
            Text(Strings.text("The pipeline file goes to the Trash, so you can put it back from there."))
        }
    }

    private var sidebar: some View {
        List(selection: $model.listSelection) {
            Section(Strings.text("Yours")) {
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
                    .contextMenu { rowMenu(.saved(entry.name)) }
                }
            }
            Section(Strings.text("Examples")) {
                ForEach(model.templates, id: \.name) { template in
                    PipelineListRow(name: template.name, icon: template.icon ?? "", problem: nil, isTemplate: true)
                        .tag(PipelineEditorModel.Selection.template(template.name))
                        .contextMenu { rowMenu(.template(template.name)) }
                }
            }
        }
        .accessibilityLabel(Strings.text("Pipelines"))
        .safeAreaInset(edge: .bottom) {
            Button { model.newPipeline() } label: {
                Label(Strings.text("New Pipeline"), systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.s)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ink.charcoalText)
            .background(RoundedRectangle(cornerRadius: Radius.panel / 2, style: .continuous).strokeBorder(Ink.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .keyboardShortcut("n", modifiers: .command)
            .padding(Spacing.m)
        }
    }

    /// Duplicate for any pipeline; Delete only for one of yours.
    @ViewBuilder private func rowMenu(_ selection: PipelineEditorModel.Selection) -> some View {
        Button(Strings.text("Duplicate")) {
            model.request(selection)
            if model.selection == selection { model.duplicate() }
        }
        if case .saved = selection {
            Button(Strings.text("Delete…")) {
                model.request(selection)
                if model.selection == selection { confirmingDelete = true }
            }
        }
    }

}
