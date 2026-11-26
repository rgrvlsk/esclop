// SPDX-License-Identifier: GPL-3.0-or-later
//
// The pipeline editor window (`pr9-pipeline-editor`): your pipelines and the built-in examples on
// the left, the selected one on the right. Examples are read-only; Make It Mine makes an editable
// copy. Duplicate is in a row's context menu and the toolbar (⌘D); Delete in the context menu and
// on ⌫ in the list.

import EsclopCore
import EsclopPipelines
import SwiftUI

public struct PipelineEditorView: View {
    @Bindable var model: PipelineEditorModel
    @State private var confirmingDelete = false
    /// A row menu's action that waits for the save question to open its row first.
    @State private var afterOpening: (selection: PipelineEditorModel.Selection, action: RowAction)?

    enum RowAction { case duplicate, delete }

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
        .onDeleteCommand { if isSaved { confirmingDelete = true } }
        .onChange(of: model.selection) { _, now in
            guard let pending = afterOpening, now == pending.selection else { return }
            afterOpening = nil
            run(pending.action)
        }
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

    /// Duplicate for any pipeline; Delete only for one of yours. With unsaved changes the row
    /// opens after the save question, and the action follows then.
    @ViewBuilder private func rowMenu(_ selection: PipelineEditorModel.Selection) -> some View {
        Button(Strings.text("Duplicate")) { open(selection, then: .duplicate) }
        if case .saved = selection {
            Button(Strings.text("Delete…")) { open(selection, then: .delete) }
        }
    }

    private func open(_ selection: PipelineEditorModel.Selection, then action: RowAction) {
        model.request(selection)
        if model.selection == selection { run(action) } else { afterOpening = (selection, action) }
    }

    private func run(_ action: RowAction) {
        switch action {
        case .duplicate: model.duplicate()
        case .delete: confirmingDelete = true
        }
    }

    private var isSaved: Bool { if case .saved = model.selection { return true } else { return false } }

}
