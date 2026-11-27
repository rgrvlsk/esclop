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
    static let sidebarWidth: CGFloat = 244
    @Bindable var model: PipelineEditorModel
    @State private var confirmingDelete = false
    @FocusState private var listFocused: Bool
    /// The keyboard came to the list (Tab, an arrow): its ring shows until a click.
    @State private var keyboardMoved = false
    /// When the window opened, and whether a click just gave the list the keyboard: neither
    /// draws the ring.
    @State private var entry = KeyboardEntry()
    @State private var clicked = false
    /// A row menu's action that waits for the save question to open its row first.
    @State private var afterOpening: (selection: PipelineEditorModel.Selection, action: RowAction)?

    enum RowAction { case duplicate, delete }

    public init(model: PipelineEditorModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Self.sidebarWidth)
                .background(Surface.sidebar.ignoresSafeArea())
            Group {
                if model.selection == nil {
                    ContentUnavailableView(Strings.text("No pipeline selected"), systemImage: "wand.and.rays", description: Text(Strings.text("Choose one on the left or make a new one.")))
                } else {
                    PipelineDetailView(model: model, delete: isSaved ? { confirmingDelete = true } : nil)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .warmPage()
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

    /// Yours and the examples, as warm rows; the one open is cream and raised. ↑ and ↓ move
    /// through them, ⌫ deletes one of yours.
    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    heading(Strings.text("Yours"))
                    if model.saved.isEmpty, model.selection != .new {
                        Text(Strings.text("None yet"))
                            .foregroundStyle(Ink.text.opacity(0.75))
                            .padding(.horizontal, Spacing.m)
                            .padding(.vertical, Spacing.xs)
                    }
                    if model.selection == .new {
                        row(.new, name: model.draft.name, icon: model.draft.icon, problem: nil, isTemplate: false)
                    }
                    ForEach(model.saved, id: \.name) { entry in
                        row(.saved(entry.name), name: entry.name, icon: entry.pipeline?.icon ?? "", problem: entry.pipeline == nil ? Strings.text("Has errors") : nil, isTemplate: false)
                            .contextMenu { rowMenu(.saved(entry.name)) }
                    }
                    heading(Strings.text("Examples"))
                        .padding(.top, Spacing.l)
                    ForEach(model.templates, id: \.name) { template in
                        row(.template(template.name), name: PipelineVocabulary.exampleTitle(template.name), icon: template.icon ?? "", problem: nil, isTemplate: true)
                            .contextMenu { rowMenu(.template(template.name)) }
                    }
                }
                .padding(.horizontal, Spacing.m)
                .padding(.top, Spacing.s)
            }
            .scrollIndicators(.never)
            // The row the arrows reach scrolls into view.
            .onChange(of: model.selection) { _, now in
                if let now { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(now) } }
            }
            }
            Button { model.newPipeline() } label: {
                Label(Strings.text("New Pipeline"), systemImage: "plus")
            }
            .buttonStyle(DashedAddButtonStyle(radius: 14))
            .keyboardShortcut("n", modifiers: .command)
            .padding(Spacing.m)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.text("Pipelines"))
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            let all = order
            guard let current = model.selection, let index = all.firstIndex(of: current) else { return }
            switch direction {
            case .up where index > 0: model.listSelection = all[index - 1]
            case .down where index < all.count - 1: model.listSelection = all[index + 1]
            default: break
            }
            keyboardMoved = true
        }
        .onDeleteCommand { if isSaved { confirmingDelete = true } }
        .onChange(of: listFocused) {
            defer { clicked = false }
            if listFocused, entry.settled, !clicked { keyboardMoved = true }
        }
        .onAppear { entry.appeared() }
        .onChange(of: model.selection) { _, now in
            guard let pending = afterOpening, now == pending.selection else { return }
            afterOpening = nil
            run(pending.action)
        }
    }

    /// The rows in the order the sidebar lists them.
    private var order: [PipelineEditorModel.Selection] {
        (model.selection == .new ? [.new] : []) + model.saved.map { .saved($0.name) } + model.templates.map { .template($0.name) }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .warmLabel()
            .padding(.horizontal, Spacing.m)
            .padding(.bottom, Spacing.xs)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ selection: PipelineEditorModel.Selection, name: String, icon: String, problem: String?, isTemplate: Bool) -> some View {
        let selected = model.selection == selection
        let all = order
        let position = (all.firstIndex(of: selection) ?? 0) + 1
        return Button {
            keyboardMoved = false
            // A click gives the list the keyboard, so ↑ and ↓ go on from there.
            clicked = true
            listFocused = true
            model.listSelection = selection
        } label: {
            PipelineListRow(name: name, icon: icon, problem: problem, isTemplate: isTemplate)
        }
        .buttonStyle(SidebarRowStyle(selected: selected, focused: listFocused && keyboardMoved))
        .id(selection)
        .accessibilityValue(Strings.format("%d of %d", position, all.count))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
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
