// SPDX-License-Identifier: GPL-3.0-or-later
//
// One pipeline (`pr9-pipeline-editor`): its name as the heading, one sentence of chips for what
// it runs on and what runs it, its steps as a numbered flow, its options and "Try It…". The
// Form/Text switch shows the same pipeline as the file holds it.

import AppKit
import EsclopCore
import EsclopPipelines
import SwiftUI

struct PipelineDetailView: View {
    static let gutter = Spacing.xl + 8
    @Bindable var model: PipelineEditorModel
    /// Asks to delete the pipeline shown; nil for an example or a new one.
    var delete: (() -> Void)?
    @State private var tryingIt = false
    /// The list is taller than the window: a legacy scroller shows at the right.
    @State private var overflows = false

    var body: some View {
        Group {
            if model.showsText {
                // The text fills the window under the heading: no page that scrolls around an
                // editor that scrolls.
                VStack(alignment: .leading, spacing: 0) {
                    header.padding(.top, Spacing.s).padding(.bottom, Spacing.xs)
                    PipelineTextSection(model: model)
                    if model.draft.hasScripts { scriptNotice.padding(.top, Spacing.l) }
                }
                // The list's gutters: its rows' 24 and the 8 the list adds of its own, so the
                // heading stays put between Steps and Text.
                .padding(.horizontal, Self.gutter)
                .padding(.bottom, Self.gutter)
                // Asked for its smallest size, the column would wrap every line to a letter and
                // grow the window; it is never narrower than this.
                .frame(minWidth: 480)
            } else {
                list
            }
        }
        .modifier(DetailChrome(model: model, tryingIt: $tryingIt))
    }

    /// A plain list on the warm page: each row draws its own tile, and the steps keep the
    /// list's drag to reorder.
    private var list: some View {
        List {
            header.warmRow(top: Spacing.s)
            // An example can be read, not changed: its chips and steps still open, their
            // controls are disabled inside.
            // 15 pt under the description, so it does not read as a row of chips.
            PipelineSentence(model: model).warmRow(top: 10, bottom: 0)
            PipelineStepsSection(model: model)
            optionsSection
                .disabled(model.isTemplate)
                .warmRow(top: Spacing.l)
            if model.draft.hasScripts { scriptNotice.warmRow(top: Spacing.l) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .readsOverflow($overflows)
        // Even gutters, with or without a scroller showing.
        .environment(\.rowTrailing, Gutter.trailing(Spacing.xl, overflows: overflows))
        .environment(\.defaultMinListRowHeight, 0)
        .labeledContentStyle(PanelRowStyle())
    }
}

/// The editor's sheet and toolbar, the same over the steps and over the text.
private struct DetailChrome: ViewModifier {
    @Bindable var model: PipelineEditorModel
    @Binding var tryingIt: Bool

    /// Nothing marked wrong, in the steps or in the text.
    private var canSave: Bool {
        model.check.isValid && !model.textDiagnostics.contains { $0.severity == .error }
    }

    private var viewPicker: some View {
        Picker(Strings.text("View"), selection: $model.isTextView) {
            Text(Strings.text("Steps")).tag(false)
            Text(Strings.text("Text")).tag(true)
        }
        .pickerStyle(.segmented)
        .accessibilityLabel(Strings.text("Show the pipeline as steps or as text"))
        .help(Strings.text("Show the pipeline as steps or as text"))
    }

    func body(content: Content) -> some View {
        content
        .sheet(isPresented: $tryingIt) {
            VStack(spacing: 0) {
                Form { PipelineTryItSection(model: model) }
                    .formStyle(.grouped)
                HStack {
                    Spacer()
                    Button(Strings.text("Done")) { tryingIt = false }
                        .keyboardShortcut(.defaultAction)
                        .primaryButton()
                }
                // Esc closes it too.
                .background { Button("") { tryingIt = false }.keyboardShortcut(.cancelAction).hidden().accessibilityHidden(true) }
                .padding(Spacing.l)
            }
            .frame(width: 560, height: 460)
            .designTint()
        }
        .modifier(NoToolbarTitle())
        .toolbar {
            if #available(macOS 26, *) {
                // Over the pipeline's column, not the window's middle: half the sidebar along,
                // without the bar's shared platter, which would stay behind.
                ToolbarItem(placement: .principal) { viewPicker.offset(x: PipelineEditorView.sidebarWidth / 2) }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) { viewPicker.offset(x: PipelineEditorView.sidebarWidth / 2) }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(Strings.text("Duplicate"), systemImage: "plus.square.on.square") { model.duplicate() }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(model.selection == nil || model.selection == .new)
                    .help(Strings.text("Duplicate"))
                if !model.isTemplate {
                    Button(Strings.text("Revert"), systemImage: "arrow.uturn.backward") { model.revert() }
                        .disabled(!model.hasChanges || model.selection == .new)
                        .help(Strings.text("Revert"))
                    // With changes to save, Save says its name: it is the next thing to do.
                    if model.hasChanges {
                        Button(Strings.text("Save"), systemImage: "square.and.arrow.down") { model.save() }
                            .labelStyle(.titleAndIcon)
                            .keyboardShortcut("s", modifiers: .command)
                            .disabled(!canSave)
                            .help(Strings.text("Save"))
                    } else {
                        Button(Strings.text("Save"), systemImage: "square.and.arrow.down") { model.save() }
                            .keyboardShortcut("s", modifiers: .command)
                            .disabled(true)
                            .help(Strings.text("Save"))
                    }
                }
            }
        }
    }
}

extension PipelineDetailView {
    // MARK: Parts

    /// The name as the pane's one heading, in New York, and the description under it; Try It…
    /// and Run on Files… as pills beside it.
    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            // One layout at every width and in every state: the pills at the top right, the
            // name taking the rest and giving way when it is long.
            HStack(alignment: .top, spacing: Spacing.l) {
                names
                actions.padding(.top, 6)
            }
            if model.isTemplate {
                HStack(spacing: Spacing.m) {
                    Text(Strings.text("An example. Make it yours to change it."))
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(Strings.text("Make It Mine")) { model.duplicate() }
                        .buttonStyle(PillButtonStyle(prominent: true, compact: true))
                        .accessibilityLabel(Strings.format("Make %@ yours", model.draft.name))
                }
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, 10)
                .warmTile(14)
            }
            ForEach(model.check.general, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.circle.fill").foregroundStyle(Palette.error)
            }
            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.error)
            }
        }
    }

    /// The name as the heading, the description under it.
    private var names: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.isTemplate {
                // An example by its name in the person's language; it is not edited here.
                Text(PipelineVocabulary.exampleTitle(model.draft.name))
                    .font(.warmHeading(30))
                    .truncationMode(.tail)
                    .foregroundStyle(Ink.text)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            } else {
                TextField(Strings.text("Name"), text: $model.draft.name, prompt: Text(Strings.text("Name")))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.leading)
                    .font(.warmHeading(30))
                    .foregroundStyle(Ink.text)
                    .accessibilityLabel(Strings.text("Name"))
                    .accessibilityAddTraits(.isHeader)
            }
            TextField(Strings.text("Description"), text: $model.draft.description, prompt: Text(Strings.text("What it is for")).foregroundStyle(Ink.secondary))
                .labelsHidden()
                .textFieldStyle(.plain)
                .multilineTextAlignment(.leading)
                .font(.system(size: 14))
                .foregroundStyle(Ink.secondary)
                .accessibilityLabel(Strings.text("Description"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(-1)
        .disabled(model.isTemplate)
    }

    /// Try It…, Run on Files…, and a menu with Duplicate and Delete….
    private var actions: some View {
        HStack(spacing: Spacing.s) {
            Button(Strings.text("Try It…")) { tryingIt = true }
                .help(Strings.text("Run the pipeline as it is here on a copy of a file"))
            if case .saved = model.selection {
                // It runs the saved pipeline: it waits while there are changes to save.
                Button(Strings.text("Run on Files…")) { chooseAndRun() }
                    .disabled(model.hasChanges)
                    .help(model.hasChanges ? Strings.text("Save the changes first: Run on Files… runs the saved pipeline") : Strings.text("Run the saved pipeline on files you choose"))
            }
            if model.selection != nil, model.selection != .new {
                MoreMenu {
                    Button(Strings.text("Duplicate")) { model.duplicate() }
                    if let delete {
                        Divider()
                        Button(Strings.text("Delete…"), role: .destructive, action: delete)
                    }
                }
            }
        }
        .buttonStyle(PillButtonStyle())
        .fixedSize()
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Strings.text("Options")).warmLabel().accessibilityAddTraits(.isHeader)
            option(
                Strings.text("Optimise first"),
                Strings.text("Compress the file before the steps run, unless the first step re-encodes it anyway."),
                isOn: $model.draft.optimiseFirst
            )
            option(
                Strings.text("Run without a floating result"),
                Strings.text("Nothing appears on screen when it runs on its own."),
                isOn: $model.draft.hideResult
            )
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .warmTile()
    }

    private func option(_ title: String, _ subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { OptionLabel(title: title, subtitle: subtitle) }
            .switchLabel(title: title, hint: subtitle)
            .toggleStyle(WarmCheckboxStyle())
    }

    /// Amber: running scripts is a decision to make.
    private var scriptNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "terminal").foregroundStyle(Ink.warm).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(Strings.text("This pipeline runs scripts"))
                    .font(.headline)
                Text(Strings.text("Its script steps run code on your Mac with your permissions. AI agents may only run this pipeline when “Agents may run scripts” is on."))
                    .fixedSize(horizontal: false, vertical: true)
                Button(Strings.text("Open Agents Settings")) {
                    if let url = URL(string: "esclop://settings/agents/allowRunScripts") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(PillButtonStyle(compact: true))
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, 14)
        .warmTile(fill: Surface.decision)
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

extension View {
    /// A row of the editor's list that draws itself: no list background, no separator.
    func warmRow(top: CGFloat = Spacing.xs, bottom: CGFloat = Spacing.xs) -> some View {
        modifier(WarmRow(top: top, bottom: bottom))
    }
}

extension EnvironmentValues {
    /// The editor's trailing gutter, less a legacy scroller's width while one shows.
    @Entry var rowTrailing: CGFloat = Spacing.xl
}

private struct WarmRow: ViewModifier {
    let top: CGFloat
    let bottom: CGFloat
    @Environment(\.rowTrailing) private var trailing

    func body(content: Content) -> some View {
        // The space above and below is the row's own padding: the list adds room under a row
        // with top and bottom insets, so its gaps would not be the ones asked for.
        content
            .padding(.top, top)
            .padding(.bottom, bottom)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: Spacing.xl, bottom: 0, trailing: trailing))
    }
}

/// "Runs for [PNG files named “Screenshot”] when [copied] or [dropped on the drop zone] ⊕": what a
/// pipeline runs on and what runs it, in one sentence of chips. A chip opens its editor.
struct PipelineSentence: View {
    @Bindable var model: PipelineEditorModel
    @State private var editingFilter = false
    /// Which trigger chip (or ⊕, -1) opened the editor of what runs it; nil while it is closed.
    @State private var editingTriggers: Int?

    var body: some View {
        // A connective travels with the chip after it, and ⊕ with the last chip, so a line
        // never ends on "or" nor starts with ⊕.
        let triggers = Self.triggerPhrases(model.draft)
        FlowLayout(spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Text(Strings.text("Runs for")).foregroundStyle(Ink.secondary)
                chip(Self.filterPhrase(model.draft.filter)) { editingFilter = true }
                    .popover(isPresented: $editingFilter, arrowEdge: .bottom) {
                        editor { PipelineFilterSection(model: model) }.frame(width: 460, height: 320)
                    }
            }
            if triggers.isEmpty {
                HStack(spacing: Spacing.s) {
                    Text(Strings.text("when")).foregroundStyle(Ink.secondary)
                    chip(Strings.text("you choose it")) { editingTriggers = 0 }
                    addTrigger
                }
            } else {
                ForEach(Array(triggers.enumerated()), id: \.offset) { index, phrase in
                    HStack(spacing: Spacing.s) {
                        Text(index == 0 ? Strings.text("when") : index == triggers.count - 1 ? Strings.text("or") : ",").foregroundStyle(Ink.secondary)
                        chip(phrase) { editingTriggers = index }
                        if index == triggers.count - 1 { addTrigger }
                    }
                }
            }
        }
        // What runs it, from any of its chips or ⊕: one anchor that stays while the editor adds
        // or removes triggers, which redraws the chips under it.
        .popover(isPresented: Binding(get: { editingTriggers != nil }, set: { if !$0 { editingTriggers = nil } }), arrowEdge: .bottom) {
            triggerEditor
        }
        .font(.system(size: 14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.text("What it runs on and what runs it"))
    }

    private var triggerEditor: some View {
        editor { PipelineTriggersSection(model: model) }.frame(width: 460, height: 440)
    }

    /// ⊕: what runs it.
    private var addTrigger: some View {
        Button { editingTriggers = -1 } label: {
            // Something to add: a dashed circle, as every place still empty.
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(DashedOutline(circle: true))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .contentShape(.focusEffect, Circle())
        .foregroundStyle(Ink.charcoalText)
        .accessibilityLabel(Strings.text("Choose what runs it"))
        .help(Strings.text("Choose what runs it"))
    }

    /// A popover's editor: its own view tree, so it pins the tint and follows an example's
    /// read-only state itself.
    private func editor(@ViewBuilder _ content: () -> some View) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .disabled(model.isTemplate)
            .designTint()
    }

    /// A chip: a capsule on the resting tile that opens its editor.
    private func chip(_ text: String, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            Text(text)
                .font(.system(size: 14.5, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 13)
                .frame(minHeight: 30)
                .raised(Capsule(), fill: Surface.warmTile)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contentShape(.focusEffect, Capsule())
        .foregroundStyle(Ink.text)
    }

    /// The filter in a few words: "every file", "png files", "png files named “Screenshot”".
    static func filterPhrase(_ filter: StepDraft?) -> String {
        guard let filter else { return Strings.text("every file") }
        // The language separates types with spaces ("png jpeg"); a comma is read too.
        let types = filter.values["types"].map { $0.split { $0 == " " || $0 == "," }.map(String.init) } ?? []
        let kind = types.isEmpty ? Strings.text("files") : Strings.format("%@ files", PanelList.join(types.map { $0.uppercased() }))
        if let name = filter.values["nameContains"], !name.isEmpty {
            return Strings.format("%@ named “%@”", kind, name)
        }
        return types.isEmpty ? Strings.text("some files") : kind
    }

    /// What runs it, in words that follow "when": "copied", "dropped on the drop zone", "a file
    /// lands in ~/Downloads".
    static func triggerPhrases(_ draft: PipelineDraft) -> [String] {
        let simple: [(PipelineTrigger, String)] = [
            (.clipboard, Strings.text("copied")),
            (.dropZone, Strings.text("dropped on the drop zone")),
            (.presetZone, Strings.text("dropped on its tile")),
            (.rightClick, Strings.text("chosen in Finder")),
            (.cli, Strings.text("run from the command line")),
            (.mcp, Strings.text("an AI agent asks")),
        ]
        return simple.filter { draft[trigger: $0.0] }.map(\.1)
            + draft.folders.map { Strings.format("new in %@", ($0 as NSString).lastPathComponent) }
    }
}

/// Lists in words in the app's language: "PNG, JPEG and GIF".
enum PanelList {
    static func join(_ items: [String]) -> String {
        let formatter = ListFormatter()
        formatter.locale = Strings.locale
        return formatter.string(from: items) ?? items.joined(separator: ", ")
    }
}

/// An option's title and the line under it.
struct OptionLabel: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The page's sizes: 14 as the steps' summaries, 12.5 under it.
            Text(title).font(.system(size: 14)).foregroundStyle(Ink.text)
            Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The toolbar shows no title (macOS 15 and later can remove it); the window keeps it.
private struct NoToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.toolbar(removing: .title) } else { content }
    }
}
