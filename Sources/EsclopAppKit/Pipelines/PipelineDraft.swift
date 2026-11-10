// SPDX-License-Identifier: GPL-3.0-or-later
//
// A pipeline as the editor's form holds it: steps as a name and the text of each argument, so
// a half-typed value stays as typed. Everything goes through the language's own parser and
// serializer: a step's arguments become step text, `PipelineParser` turns that into the step
// (or says what is wrong, on that step), and the pipeline the form builds is saved as
// `PipelineSerializer` writes it. Pipeline → draft → pipeline gives back the same pipeline.
//
// The form's "Only files that…" filter is an `if(...)` step at the start of every section. A
// pipeline whose sections all begin with the same `if` shows it as the filter; any other `if`
// stays a step where it is.

import EsclopCore
import EsclopPipelines
import Foundation

/// One step in the form.
public struct StepDraft: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// The step's name in the language (`optimise`, `if`).
    public var name: String
    /// Argument text by parameter name, without the quotes the file puts around text.
    public var values: [String: String]

    public init(id: UUID = UUID(), name: String, values: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.values = values
    }

    /// The form of a parsed step: the arguments it sets, without the ones at their default
    /// (the serializer leaves those out too).
    public init(_ step: PipelineStep, id: UUID = UUID()) {
        self.id = id
        name = step.name
        let spec = PipelineLanguage.spec(named: step.name)
        var values: [String: String] = [:]
        for (key, text) in PipelineSerializer.arguments(of: step) where spec?.param(key)?.defaultValue != text {
            values[key] = Self.unquote(text)
        }
        self.values = values
    }

    public var spec: StepSpec? { PipelineLanguage.spec(named: name) }

    /// Runs code the person wrote: a shell script or a Shortcut.
    public var isScript: Bool { name == "runScript" || name == "runShortcut" }

    /// The step as pipeline text, arguments in the catalog's order, empty ones left out.
    public var text: String {
        let params = spec?.params ?? []
        let known = params.compactMap { param -> String? in
            guard let value = values[param.name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
            return "\(param.name): \(Self.written(value, for: param, step: name))"
        }
        // Arguments the catalog does not know, kept so the parser can name them.
        let unknown = values.keys.filter { key in !params.contains { $0.name == key } }.sorted().compactMap { key -> String? in
            guard let value = values[key], !value.isEmpty else { return nil }
            return "\(key): \(value)"
        }
        let args = known + unknown
        return args.isEmpty ? name : "\(name)(\(args.joined(separator: ", ")))"
    }

    /// The parsed step, or what is wrong with it.
    public func parsed() -> Result<PipelineStep, PipelineSyntaxError> {
        let result = PipelineParser.check(text)
        if let step = result.pipeline?[nil].first, result.errors.isEmpty, result.pipeline?[nil].count == 1 {
            return .success(step)
        }
        let errors = result.errors.isEmpty ? [PipelineDiagnostic(line: 1, column: 1, "This step could not be read.")] : result.errors
        return .failure(PipelineSyntaxError(diagnostics: errors))
    }

    /// How a value is written in the file: text in quotes, words and numbers bare.
    static func written(_ value: String, for param: ParamSpec, step: String) -> String {
        switch param.type {
        case .text:
            if step == "delete", param.name == "path", ["sourceFile", "currentFile"].contains(value) { return value }
            return PipelineSerializer.quote(value)
        case .location:
            return ["inPlace", "sameFolder", "temporaryFolder"].contains(value) ? value : PipelineSerializer.quote(value)
        default:
            return value
        }
    }

    static func unquote(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == "\"" || first == "'", text.last == first else { return text }
        return String(text.dropFirst().dropLast())
    }
}

/// The steps for one kind of file, or for every kind when `kind` is nil.
public struct SectionDraft: Identifiable, Hashable, Sendable {
    public var kind: MediaKind?
    public var steps: [StepDraft]
    public var id: String { kind?.rawValue ?? "any" }

    public init(kind: MediaKind?, steps: [StepDraft] = []) {
        self.kind = kind
        self.steps = steps
    }
}

public struct PipelineDraft: Hashable, Sendable {
    public var name: String
    public var description: String
    public var icon: String
    public var hotkey: String
    /// In the order the file lists them.
    public var triggers: [PipelineTrigger]
    public var optimiseFirst: Bool
    public var hideResult: Bool
    /// "Only files that…": an `if` step put first in every section.
    public var filter: StepDraft?
    /// In file order.
    public var sections: [SectionDraft]

    public init(name: String, steps: [StepDraft] = []) {
        self.name = name
        description = ""
        icon = ""
        hotkey = ""
        triggers = []
        optimiseFirst = false
        hideResult = false
        filter = nil
        sections = [SectionDraft(kind: nil, steps: steps)]
    }

    public init(_ pipeline: Pipeline) {
        name = pipeline.name
        description = pipeline.description ?? ""
        icon = pipeline.icon ?? ""
        hotkey = pipeline.hotkey ?? ""
        triggers = pipeline.triggers
        optimiseFirst = pipeline.optimiseFirst
        hideResult = pipeline.hideResult
        let sections = pipeline.sections.filter { !$0.steps.isEmpty }
        // A shared leading `if` is the filter, unless it is all a section has.
        if let first = sections.first?.steps.first, case .filterIf = first,
           sections.allSatisfy({ $0.steps.count > 1 && $0.steps.first == first })
        {
            filter = StepDraft(first)
            self.sections = sections.map { SectionDraft(kind: $0.kind, steps: $0.steps.dropFirst().map { StepDraft($0) }) }
        } else {
            filter = nil
            self.sections = sections.map { SectionDraft(kind: $0.kind, steps: $0.steps.map { StepDraft($0) }) }
        }
        if self.sections.isEmpty { self.sections = [SectionDraft(kind: nil)] }
    }

    /// Every step in the form, the filter first.
    public var allSteps: [StepDraft] { (filter.map { [$0] } ?? []) + sections.flatMap(\.steps) }

    public var hasScripts: Bool { allSteps.contains(where: \.isScript) }

    public var folders: [String] {
        triggers.compactMap { if case let .folder(path) = $0 { return path } else { return nil } }
    }

    public func has(_ trigger: PipelineTrigger) -> Bool { triggers.contains(trigger) }

    /// A trigger as a switch.
    public subscript(trigger trigger: PipelineTrigger) -> Bool {
        get { has(trigger) }
        set { set(trigger, on: newValue) }
    }

    /// Switches a trigger on or off, keeping the others in their order.
    public mutating func set(_ trigger: PipelineTrigger, on: Bool) {
        if on {
            if !triggers.contains(trigger) { triggers.append(trigger) }
        } else {
            triggers.removeAll { $0 == trigger }
        }
    }

    // MARK: Building

    /// What the form says, checked.
    public struct Check: Sendable {
        /// Nil while anything is wrong.
        public var pipeline: Pipeline?
        /// Errors and warnings by step, from the parser.
        public var issues: [UUID: [PipelineDiagnostic]]
        /// Problems with the name or the pipeline as a whole.
        public var general: [String]

        public var isValid: Bool { pipeline != nil }
    }

    public func check(existingNames: [String] = []) -> Check {
        var issues: [UUID: [PipelineDiagnostic]] = [:]
        var general: [String] = []
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            general.append(Strings.text("Give the pipeline a name."))
        } else if (try? PipelineStore.validate(name: trimmed)) == nil {
            general.append(Strings.text("A name cannot contain “/”, “:” or new lines, or start with “.”."))
        } else if existingNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            general.append(Strings.format("There is already a pipeline named “%@”.", trimmed))
        }
        func build(_ draft: StepDraft) -> PipelineStep? {
            switch draft.parsed() {
            case let .success(step): return step
            case let .failure(error):
                issues[draft.id] = error.diagnostics
                return nil
            }
        }
        var filterStep: PipelineStep?
        if let filter, let step = build(filter) {
            if case .filterIf = step {
                filterStep = step
            } else {
                issues[filter.id] = [PipelineDiagnostic(line: 1, column: 1, Strings.text("The filter must be an “if” step."))]
            }
        }
        var built: [PipelineSection] = []
        for section in sections {
            let steps = section.steps.compactMap(build)
            guard !section.steps.isEmpty else { continue }
            built.append(PipelineSection(kind: section.kind, steps: (filterStep.map { [$0] } ?? []) + steps))
        }
        if built.isEmpty { general.append(Strings.text("Add at least one step.")) }
        guard issues.isEmpty, general.isEmpty else { return Check(pipeline: nil, issues: issues, general: general) }
        let pipeline = Pipeline(
            name: trimmed, description: description.isEmpty ? nil : description, hotkey: hotkey.isEmpty ? nil : hotkey,
            icon: icon.isEmpty ? nil : icon, triggers: triggers, optimiseFirst: optimiseFirst, hideResult: hideResult, sections: built
        )
        // Warnings about the whole pipeline (order, repeated work), placed on their step.
        for diagnostic in PipelineParser.check(PipelineSerializer.serialize(pipeline)).diagnostics {
            if let id = step(at: diagnostic, in: pipeline) { issues[id, default: []].append(diagnostic) }
        }
        return Check(pipeline: pipeline, issues: issues, general: general)
    }

    /// The form step a diagnostic about the serialized pipeline points at: the step whose text
    /// spans its column on its section's line.
    func step(at diagnostic: PipelineDiagnostic, in pipeline: Pipeline) -> UUID? {
        let lines = PipelineSerializer.serialize(pipeline).components(separatedBy: "\n")
        guard diagnostic.line >= 1, diagnostic.line <= lines.count else { return nil }
        let line = lines[diagnostic.line - 1]
        for section in pipeline.sections where PipelineSerializer.serialize(section.steps) == line {
            let drafts = sections.first { $0.kind == section.kind }?.steps ?? []
            var column = 1
            for (position, step) in section.steps.enumerated() {
                let length = PipelineSerializer.serialize(step).count
                if diagnostic.column < column + length + 4 {
                    // With a filter, position 0 is the filter.
                    guard filter != nil else { return drafts[safe: position]?.id }
                    return position == 0 ? filter?.id : drafts[safe: position - 1]?.id
                }
                column += length + 4
            }
        }
        return nil
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
