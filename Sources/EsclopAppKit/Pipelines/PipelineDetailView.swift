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
    @Bindable var model: PipelineEditorModel
    @State private var tryingIt = false

    var body: some View {
        Form {
            header
            if model.showsText {
                PipelineTextSection(model: model)
            } else {
                // An example can be read, not changed: its chips and steps still open, their
                // controls are disabled inside.
                Section { PipelineSentence(model: model) }
                PipelineStepsSection(model: model)
                optionsSection
                    .disabled(model.isTemplate)
            }
            if model.draft.hasScripts { scriptNotice }
        }
        .formStyle(.grouped)
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
                .padding(Spacing.l)
            }
            .frame(width: 560, height: 460)
            .designTint()
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(Strings.text("View"), selection: $model.isTextView) {
                    Text(Strings.text("Steps")).tag(false)
                    Text(Strings.text("Text")).tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(Strings.text("Show the pipeline as steps or as text"))
                .help(Strings.text("Show the pipeline as steps or as text"))
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(Strings.text("Try It…"), systemImage: "testtube.2") { tryingIt = true }
                    .labelStyle(.titleOnly)
                    .help(Strings.text("Run the pipeline as it is here on a copy of a file"))
                if case .saved = model.selection {
                    Button(Strings.text("Run on Files…"), systemImage: "play") { chooseAndRun() }
                        .labelStyle(.titleOnly)
                        .disabled(model.hasChanges)
                        .help(Strings.text("Run the saved pipeline on files you choose"))
                }
                Button(Strings.text("Duplicate"), systemImage: "plus.square.on.square") { model.duplicate() }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(model.selection == nil || model.selection == .new)
                    .help(Strings.text("Duplicate"))
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

    /// The name as the pane's one heading, in New York, and the description under it.
    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                TextField(Strings.text("Name"), text: $model.draft.name, prompt: Text(Strings.text("Name")))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.leading)
                    .font(Typeface.heading)
                    .accessibilityLabel(Strings.text("Name"))
                    .accessibilityAddTraits(.isHeader)
                TextField(Strings.text("Description"), text: $model.draft.description, prompt: Text(Strings.text("What it is for")))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Strings.text("Description"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(model.isTemplate)
            .padding(.vertical, Spacing.xs)
            if model.isTemplate {
                HStack(spacing: Spacing.m) {
                    Text(Strings.text("An example. Make it yours to change it."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(Strings.text("Make It Mine")) { model.duplicate() }
                        .primaryButton()
                        .accessibilityLabel(Strings.format("Make %@ yours", model.draft.name))
                }
            }
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

    /// Amber: running scripts is a decision to make.
    private var scriptNotice: some View {
        Section {
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
                    // Plain, not `.link`: a link button is system blue whatever the tint.
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .foregroundStyle(Ink.charcoalText)
                }
            }
            .listRowBackground(Surface.decision)
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

/// "Runs for [PNG files named “Screenshot”] when [copied] or [dropped on the drop zone] ⊕": what a
/// pipeline runs on and what runs it, in one sentence of chips. A chip opens its editor.
struct PipelineSentence: View {
    @Bindable var model: PipelineEditorModel
    @State private var editingFilter = false
    @State private var editingTriggers = false

    var body: some View {
        FlowLayout(spacing: Spacing.s) {
            Text(Strings.text("Runs for")).foregroundStyle(.secondary)
            chip(Self.filterPhrase(model.draft.filter)) { editingFilter = true }
                .popover(isPresented: $editingFilter, arrowEdge: .bottom) {
                    editor { PipelineFilterSection(model: model) }.frame(width: 460, height: 320)
                }
            Text(Strings.text("when")).foregroundStyle(.secondary)
            let triggers = Self.triggerPhrases(model.draft)
            if triggers.isEmpty {
                chip(Strings.text("you choose it")) { editingTriggers = true }
            } else {
                ForEach(Array(triggers.enumerated()), id: \.offset) { index, phrase in
                    if index > 0 { Text(index == triggers.count - 1 ? Strings.text("or") : ",").foregroundStyle(.secondary) }
                    chip(phrase) { editingTriggers = true }
                }
            }
            // One popover for what runs it, whichever chip asked for it.
            Button { editingTriggers = true } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 15))
                    .frame(width: Spacing.hit, height: Spacing.hit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ink.charcoalText)
            .accessibilityLabel(Strings.text("Choose what runs it"))
            .help(Strings.text("Choose what runs it"))
            .popover(isPresented: $editingTriggers, arrowEdge: .bottom) {
                editor { PipelineTriggersSection(model: model) }.frame(width: 460, height: 440)
            }
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.text("What it runs on and what runs it"))
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
                .lineLimit(1)
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, 5)
                .background(Capsule().fill(Surface.tile))
                .overlay(Capsule().strokeBorder(Ink.secondary.opacity(0.3), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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

/// Lays its children out in lines, wrapping like text.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * spacing
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = Self.size(of: subviews[index], width: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    /// Its natural size, never wider than the row: a long name is cut, not run past the edge.
    private static func size(of subview: LayoutSubview, width: CGFloat) -> CGSize {
        let natural = subview.sizeThatFits(.unspecified)
        guard width.isFinite, natural.width > width else { return natural }
        return subview.sizeThatFits(ProposedViewSize(width: max(width, 0), height: nil))
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = Self.size(of: subviews[index], width: width)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width { rows.append(Row()) }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
