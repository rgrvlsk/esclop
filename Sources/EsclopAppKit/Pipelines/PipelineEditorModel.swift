// SPDX-License-Identifier: GPL-3.0-or-later
//
// The pipeline editor's state: the saved pipelines and the built-in templates, the one being
// edited as a `PipelineDraft`, its text when the text view is on, and "Try it" runs on a copy.
// Saving writes what `PipelineSerializer` writes, through the same `PipelineStore` as the CLI,
// the MCP server and the watched folders.

import AppKit
import EsclopCore
import EsclopIPC
import EsclopPipelines
import Foundation
import Observation

@MainActor @Observable
public final class PipelineEditorModel {
    public enum Selection: Hashable, Sendable {
        case saved(String)
        case template(String)
        /// A new pipeline not saved yet.
        case new
    }

    /// One step of a "Try it" run.
    public struct TryStep: Hashable, Sendable {
        public var step: String
        public var outcome: PipelineLogEntry.Outcome
        public var message: String?
    }

    public struct TryResult: Sendable {
        public var file: String
        public var status: PipelineFileReport.Status
        public var steps: [TryStep]
        public var bytesBefore: Int
        public var bytesAfter: Int?
        public var finalFile: URL?
        public var error: String?
    }

    public enum TryState: Sendable {
        case idle
        case running(String)
        case done(TryResult)
    }

    public private(set) var saved: [PipelineStoreEntry] = []
    public let templates: [Pipeline] = PipelineStore.presets
    public private(set) var selection: Selection?
    public var draft = PipelineDraft(name: "") {
        didSet { if draft != oldValue { recheck() } }
    }
    /// The draft checked by the parser; kept up to date as the draft changes, so views that
    /// read it for every step do not parse the pipeline again each time.
    public private(set) var check = PipelineDraft(name: "").check()
    /// The pipeline as last saved (nil for a new one), to tell whether there are changes.
    public private(set) var original: Pipeline?
    /// The section the step list shows.
    public var sectionID = "any"

    /// The text view is on.
    public private(set) var showsText = false
    /// The text view's contents; kept as typed while it has errors.
    public private(set) var text = ""
    public private(set) var textDiagnostics: [PipelineDiagnostic] = []

    public private(set) var tryState: TryState = .idle
    /// The file "Try it" and the filter check use.
    public private(set) var sampleFile: URL?
    /// Whether the filter lets the sample file through: nil before there is a sample.
    public private(set) var filterMatches: Bool?

    /// The text of a file that did not read, as it was opened.
    @ObservationIgnored private var originalText: String?
    /// The folder of the last "Try it" copy; removed by the next try, a new selection and the window closing.
    @ObservationIgnored private(set) var tryFolder: URL?
    /// Where "Try it" makes its folders.
    @ObservationIgnored var tryRoot: URL = Paths.temporary

    /// A selection waiting for the person to save or discard changes first.
    public var pendingSelection: Selection?
    /// Shown when saving, deleting or loading fails.
    public var failure: String?

    @ObservationIgnored let store: PipelineStore
    @ObservationIgnored let app: AppModel?
    /// Runs a pipeline on a copy; swapped in tests.
    @ObservationIgnored var tryRunner: @Sendable (Pipeline, URL) async -> PipelineRunReport?
    @ObservationIgnored var inspector: any MediaInspector = SystemMediaInspector()

    public init(store: PipelineStore, app: AppModel? = nil, engine: (any OptimisationEngine)? = nil, settings: (any AgentPermissionReading)? = nil) {
        self.store = store
        self.app = app
        let engine = engine ?? app?.service.context.engine
        let allowScripts = settings.map { AgentPolicy(origin: .app, permissions: $0).allowed(.allowRunScripts) } ?? true
        tryRunner = { pipeline, file in
            guard let engine else { return nil }
            // No clipboard, uploads or other apps: a try changes nothing outside its copy's folder.
            let runner = PipelineRunner(engine: engine, host: NoopPipelineHost())
            let options = PipelineRunOptions(origin: .app, allowRunScripts: allowScripts, allowDelete: false, temporaryDirectory: file.deletingLastPathComponent())
            return await runner.run(pipeline, on: [file], options: options)
        }
        reload()
    }

    // MARK: List

    public func reload() {
        saved = (try? store.entries()) ?? []
        recheck()
        if case let .saved(name) = selection, !saved.contains(where: { $0.name == name }), !hasChanges {
            select(saved.first.map { .saved($0.name) })
        }
    }

    public var savedNames: [String] { saved.map(\.name) }

    /// The Form/Text switch.
    public var isTextView: Bool {
        get { showsText }
        set { setShowsText(newValue) }
    }

    /// The "save the changes?" question is showing.
    public var isAskingToSave: Bool {
        get { pendingSelection != nil }
        set { if !newValue { pendingSelection = nil } }
    }

    /// The list's selection: choosing a row goes through `request`, so changes are not lost.
    public var listSelection: Selection? {
        get { selection }
        set { request(newValue) }
    }

    public var isTemplate: Bool { if case .template = selection { return true } else { return false } }

    /// Whether the form differs from what is saved.
    public var hasChanges: Bool {
        switch selection {
        case .new: return true
        case .saved:
            // A file that did not read opens as its text: it changed only if that text did.
            if original == nil { return showsText && text != originalText }
            let textHasErrors = showsText && textDiagnostics.contains { $0.severity == .error }
            return check.pipeline.map { $0 != original } ?? true || textHasErrors
        default: return false
        }
    }

    private func recheck() {
        check = draft.check(existingNames: savedNames.filter { name in
            if case let .saved(current) = selection { return name.caseInsensitiveCompare(current) != .orderedSame }
            return true
        })
    }

    /// Opens a pipeline; with unsaved changes, asks first (`pendingSelection`).
    public func request(_ next: Selection?) {
        guard next != selection else { return }
        if hasChanges, selection != nil, !isTemplate {
            pendingSelection = next
        } else {
            select(next)
        }
    }

    /// Opens `esclop://pipelines/<name>`: a saved pipeline, else a template, else the list.
    public func open(name: String?) {
        guard let name, !name.isEmpty else {
            if selection == nil { select(saved.first.map { .saved($0.name) } ?? templates.first.map { .template($0.name) }) }
            return
        }
        if let entry = saved.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            request(.saved(entry.name))
        } else if let template = templates.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            request(.template(template.name))
        } else {
            failure = Strings.format("There is no pipeline named “%@”.", name)
        }
    }

    func select(_ next: Selection?) {
        defer { recheck() }
        discardTry()
        originalText = nil
        pendingSelection = nil
        selection = next
        failure = nil
        tryState = .idle
        filterMatches = nil
        switch next {
        case let .saved(name):
            let entry = saved.first { $0.name == name }
            if let pipeline = entry?.pipeline {
                load(pipeline, original: pipeline)
            } else {
                // A file with errors opens in the text view, marked.
                load(PipelineDraft(name: name), original: nil)
                text = (try? store.text(of: name)) ?? ""
                showsText = true
                textDiagnostics = entry?.diagnostics ?? []
                originalText = text
            }
        case let .template(name):
            if let template = templates.first(where: { $0.name == name }) { load(template, original: template) }
        case .new:
            load(PipelineDraft(name: uniqueName(Strings.text("New Pipeline")), steps: [StepDraft(name: "optimise")]), original: nil)
        case nil:
            load(PipelineDraft(name: ""), original: nil)
        }
    }

    private func load(_ pipeline: Pipeline, original: Pipeline?) {
        load(PipelineDraft(pipeline), original: original)
    }

    private func load(_ draft: PipelineDraft, original: Pipeline?) {
        self.draft = draft
        self.original = original
        sectionID = draft.sections.first?.id ?? "any"
        textDiagnostics = []
        if showsText { text = currentText }
    }

    // MARK: Actions

    public func newPipeline() { request(.new) }

    /// A copy of the selected pipeline or template, unsaved, named "… copy".
    public func duplicate() {
        var copy = draft
        copy.name = uniqueName(Strings.format("%@ copy", draft.name))
        let keep = copy
        request(.new)
        guard selection == .new else { return }
        draft = PipelineDraft(keep.check(existingNames: []).pipeline ?? Pipeline(name: keep.name))
        draft.name = keep.name
        if showsText { text = currentText }
    }

    public func save() {
        guard !isTemplate else { return }
        if showsText {
            applyText()
            guard !textDiagnostics.contains(where: { $0.severity == .error }) else {
                failure = Strings.text("Fix the marked lines first.")
                return
            }
        }
        guard let pipeline = check.pipeline else {
            failure = check.general.first ?? Strings.text("Fix the marked steps first.")
            return
        }
        do {
            if case let .saved(old) = selection, old != pipeline.name { try store.rename(old, to: pipeline.name) }
            try store.save(pipeline)
            original = pipeline
            selection = .saved(pipeline.name)
            reload()
            failure = nil
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    /// Back to the saved version.
    public func revert() {
        let current = selection
        selection = nil
        select(current)
    }

    public func delete() {
        guard case let .saved(name) = selection else {
            if selection == .new { select(saved.first.map { .saved($0.name) }) }
            return
        }
        do {
            try store.delete(name)
            original = nil
            reload()
            select(saved.first.map { .saved($0.name) } ?? templates.first.map { .template($0.name) })
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    /// Runs the saved pipeline on files, as the app runs any job (floating results).
    public func run(on files: [URL]) {
        guard case let .saved(name) = selection, !files.isEmpty else { return }
        app?.runPipeline(name, on: files)
    }

    func uniqueName(_ base: String) -> String {
        var name = base
        var n = 2
        let taken = Set(savedNames.map { $0.lowercased() })
        while taken.contains(name.lowercased()) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    // MARK: Steps

    public var currentSection: SectionDraft? { draft.sections.first { $0.id == sectionID } }

    private var sectionIndex: Int? { draft.sections.firstIndex { $0.id == sectionID } }

    public func addStep(_ name: String) {
        guard let index = sectionIndex else { return }
        var step = StepDraft(name: name)
        for param in step.spec?.requiredParams ?? [] {
            if let first = param.type.suggestions.first { step.values[param.name] = first }
        }
        draft.sections[index].steps.append(step)
    }

    public func removeStep(_ id: UUID) {
        guard let index = sectionIndex else { return }
        draft.sections[index].steps.removeAll { $0.id == id }
    }

    public func moveSteps(from offsets: IndexSet, to destination: Int) {
        guard let index = sectionIndex else { return }
        draft.sections[index].steps.move(fromOffsets: offsets, toOffset: destination)
    }

    /// Moves a step one place up (-1) or down (+1), for the keyboard.
    public func moveStep(_ id: UUID, by offset: Int) {
        guard let index = sectionIndex, let from = draft.sections[index].steps.firstIndex(where: { $0.id == id }) else { return }
        let to = from + offset
        guard draft.sections[index].steps.indices.contains(to) else { return }
        draft.sections[index].steps.swapAt(from, to)
    }

    public func addSection(_ kind: MediaKind?) {
        let id = kind?.rawValue ?? "any"
        if !draft.sections.contains(where: { $0.id == id }) { draft.sections.append(SectionDraft(kind: kind)) }
        sectionID = id
    }

    public func removeSection(_ id: String) {
        draft.sections.removeAll { $0.id == id }
        if draft.sections.isEmpty { draft.sections = [SectionDraft(kind: nil)] }
        sectionID = draft.sections[0].id
    }

    /// The filter switch.
    public var hasFilter: Bool {
        get { draft.filter != nil }
        set { setFilter(newValue) }
    }

    public func setFilter(_ on: Bool) {
        draft.filter = on ? (draft.filter ?? StepDraft(name: "if", values: ["types": "image"])) : nil
        Task { await checkFilter() }
    }

    // MARK: Text view

    /// The draft as the file would hold it. A form with errors still gives text: each step as
    /// typed, so the parser can point at the line.
    public var currentText: String {
        if let pipeline = check.pipeline { return PipelineSerializer.serialize(pipeline) }
        var shell = Pipeline(
            name: draft.name, description: draft.description.isEmpty ? nil : draft.description, hotkey: draft.hotkey.isEmpty ? nil : draft.hotkey,
            icon: draft.icon.isEmpty ? nil : draft.icon, triggers: draft.triggers, optimiseFirst: draft.optimiseFirst, hideResult: draft.hideResult
        )
        shell.sections = []
        var out = PipelineSerializer.serialize(shell)
        if out == "\n" { out = "" }
        let blocks = draft.sections.filter { !$0.steps.isEmpty }.map { section -> String in
            let line = ((draft.filter.map { [$0] } ?? []) + section.steps).map(\.text).joined(separator: " -> ")
            return section.kind.map { "[\($0.rawValue)]\n" + line } ?? line
        }
        return out + blocks.joined(separator: "\n\n") + "\n"
    }

    public func setShowsText(_ on: Bool) {
        guard on != showsText else { return }
        if on {
            text = currentText
            textDiagnostics = []
            showsText = true
        } else {
            // Back to the form only from text that reads.
            guard textDiagnostics.allSatisfy({ $0.severity != .error }) else { return }
            showsText = false
        }
    }

    /// The person typed in the text view: the form follows when the text reads, otherwise the
    /// text stays as typed and the errors are marked.
    public func editText(_ newText: String) {
        text = newText
        applyText()
    }

    private func applyText() {
        let result = PipelineParser.check(text, name: draft.name)
        textDiagnostics = result.diagnostics
        guard let pipeline = result.pipeline else { return }
        let name = draft.name
        draft = PipelineDraft(pipeline)
        draft.name = name
        if !draft.sections.contains(where: { $0.id == sectionID }) { sectionID = draft.sections[0].id }
    }

    // MARK: Try it and the filter check

    public func setSample(_ file: URL?) {
        sampleFile = file
        tryState = .idle
        Task { await checkFilter() }
    }

    /// Runs the form's pipeline on a copy of `file` in a folder of its own. The original is only read.
    public func tryIt(on file: URL) async {
        guard let pipeline = check.pipeline else {
            failure = Strings.text("Fix the marked steps first.")
            return
        }
        sampleFile = file
        await checkFilter()
        tryState = .running(file.lastPathComponent)
        discardTry()
        let folder = tryRoot.appendingPathComponent("\(Self.tryPrefix)\(UUID().uuidString)", isDirectory: true)
        tryFolder = folder
        let copy = folder.appendingPathComponent(file.lastPathComponent)
        let before = AppModel.size(of: file)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file, to: copy)
        } catch {
            tryState = .done(TryResult(file: file.lastPathComponent, status: .failed, steps: [], bytesBefore: before, error: error.localizedDescription))
            return
        }
        let report = await tryRunner(pipeline, copy)
        guard let fileReport = report?.files.first else {
            tryState = .done(TryResult(file: file.lastPathComponent, status: .unsupported, steps: [], bytesBefore: before))
            return
        }
        let after = fileReport.finalFile.map(AppModel.size(of:))
        tryState = .done(TryResult(
            file: file.lastPathComponent, status: fileReport.status,
            steps: fileReport.log.map { TryStep(step: $0.step, outcome: $0.outcome, message: $0.message) },
            bytesBefore: before, bytesAfter: after, finalFile: fileReport.finalFile, error: fileReport.error
        ))
    }

    nonisolated static let tryPrefix = "try-"

    /// Removes the last try's copy and what the pipeline made of it.
    public func discardTry() {
        guard let folder = tryFolder else { return }
        try? FileManager.default.removeItem(at: folder)
        tryFolder = nil
        if case .done = tryState { tryState = .idle }
    }

    /// Removes "Try it" folders an earlier run left behind (it quit or crashed with one open).
    public nonisolated static func removeLeftovers(in root: URL = Paths.temporary) {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent.hasPrefix(tryPrefix) {
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// Checks the sample file against the filter with the runner's own evaluation.
    public func checkFilter() async {
        guard let file = sampleFile, let filter = draft.filter, case let .success(step) = filter.parsed(), case let .filterIf(condition) = step else {
            filterMatches = nil
            return
        }
        filterMatches = await condition.evaluate(file, inspector: inspector).matches
    }
}
