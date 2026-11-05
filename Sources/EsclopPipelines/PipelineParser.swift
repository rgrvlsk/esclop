// SPDX-License-Identifier: GPL-3.0-or-later
//
// Parser for the pipeline text language. It reads everything Clop's pipeline language accepts
// (steps joined by `->` or new lines, `name(key: value)` arguments, single or double quotes with
// no escapes) plus esclop's file format: optional front matter between `---` lines, `[image]`
// style sections and `#` comments. Errors carry a line, a column and a sentence that says how
// to fix the problem.

import EsclopCore
import Foundation

// MARK: - Diagnostics

public struct PipelineDiagnostic: Error, Hashable, Codable, Sendable, CustomStringConvertible {
    public enum Severity: String, Codable, Sendable { case error, warning }

    public var severity: Severity
    /// 1-based line.
    public var line: Int
    /// 1-based column, counted in characters.
    public var column: Int
    /// Characters the problem spans, at least 1.
    public var length: Int
    public var message: String
    /// Text that would fix the problem when it replaces the span, if there is an obvious one.
    public var replacement: String?

    public init(_ severity: Severity = .error, line: Int, column: Int, length: Int = 1, _ message: String, replacement: String? = nil) {
        self.severity = severity
        self.line = line
        self.column = column
        self.length = max(1, length)
        self.message = message
        self.replacement = replacement
    }

    public var description: String { "line \(line), column \(column): \(message)" }
}

/// Thrown when pipeline text has errors. Warnings alone never throw.
public struct PipelineSyntaxError: Error, Hashable, Sendable, CustomStringConvertible, LocalizedError {
    public var diagnostics: [PipelineDiagnostic]

    public var errors: [PipelineDiagnostic] { diagnostics.filter { $0.severity == .error } }
    public var description: String { errors.map(\.description).joined(separator: "\n") }
    public var errorDescription: String? { description }

    /// The same problem as the contract's error type, for callers that speak `EsclopError`.
    public var esclopError: EsclopError { .invalidPipeline(description) }
}

public struct PipelineParseResult: Sendable {
    /// Nil only when the text has errors.
    public var pipeline: Pipeline?
    public var diagnostics: [PipelineDiagnostic]

    public var errors: [PipelineDiagnostic] { diagnostics.filter { $0.severity == .error } }
    public var warnings: [PipelineDiagnostic] { diagnostics.filter { $0.severity == .warning } }
}

// MARK: - Entry points

public enum PipelineParser {
    /// Parses a `.pipeline` file or an inline pipeline. Throws when there are errors.
    public static func parse(_ text: String, name: String = "inline") throws -> Pipeline {
        let result = check(text, name: name)
        guard let pipeline = result.pipeline else { throw PipelineSyntaxError(diagnostics: result.diagnostics) }
        return pipeline
    }

    /// Parses inline steps such as `crop(longEdge: 1600) -> convert(to: webp)`.
    /// Sections and front matter are rejected: this is for one list of steps.
    public static func parseSteps(_ text: String) throws -> [PipelineStep] {
        let p = try parse(text)
        let hasFrontMatter = p.description != nil || p.hotkey != nil || p.icon != nil || !p.triggers.isEmpty || p.optimiseFirst || p.hideResult
        if hasFrontMatter || p.sections.contains(where: { $0.kind != nil }) {
            throw PipelineSyntaxError(diagnostics: [PipelineDiagnostic(line: 1, column: 1, "Expected a list of steps without sections or front matter.")])
        }
        return p[nil]
    }

    /// Parses one step such as `downscale(factor: 0.5)`.
    public static func parseStep(_ text: String) throws -> PipelineStep {
        let steps = try parseSteps(text)
        guard steps.count == 1 else {
            throw PipelineSyntaxError(diagnostics: [PipelineDiagnostic(line: 1, column: 1, "Expected one step, found \(steps.count).")])
        }
        return steps[0]
    }

    /// Everything the parser has to say about the text, without throwing.
    public static func check(_ text: String, name: String = "inline") -> PipelineParseResult {
        var parser = Parser(text: text)
        let pipeline = parser.parseFile(name: name)
        let hasErrors = parser.diagnostics.contains { $0.severity == .error }
        return PipelineParseResult(pipeline: hasErrors ? nil : pipeline, diagnostics: parser.diagnostics)
    }
}

// MARK: - Scanner

/// A position in the source: index into `chars`, plus line and column for messages.
struct SourcePosition: Hashable {
    var index: Int
    var line: Int
    var column: Int
}

/// An argument as written: `key: value`, or a bare value when `key` is nil.
struct RawArgument {
    var key: String?
    var keyPosition: SourcePosition
    var value: String
    var quoted: Bool
    var valuePosition: SourcePosition
    var valueLength: Int
}

struct RawStep {
    var name: String
    var position: SourcePosition
    var arguments: [RawArgument]
    var hasParentheses: Bool
}

struct Parser {
    let chars: [Character]
    var pos: SourcePosition
    var diagnostics: [PipelineDiagnostic] = []

    init(text: String) {
        chars = Array(text)
        pos = SourcePosition(index: 0, line: 1, column: 1)
    }

    var atEnd: Bool { pos.index >= chars.count }
    var current: Character? { atEnd ? nil : chars[pos.index] }

    func peek(_ offset: Int = 0) -> Character? {
        let i = pos.index + offset
        return i < chars.count ? chars[i] : nil
    }

    mutating func advance() {
        guard let c = current else { return }
        pos.index += 1
        if c == "\n" {
            pos.line += 1
            pos.column = 1
        } else {
            pos.column += 1
        }
    }

    mutating func error(_ at: SourcePosition, length: Int = 1, _ message: String, replacement: String? = nil) {
        diagnostics.append(PipelineDiagnostic(.error, line: at.line, column: at.column, length: length, message, replacement: replacement))
    }

    mutating func warning(_ at: SourcePosition, length: Int = 1, _ message: String, replacement: String? = nil) {
        diagnostics.append(PipelineDiagnostic(.warning, line: at.line, column: at.column, length: length, message, replacement: replacement))
    }

    static func isSpace(_ c: Character) -> Bool { c == " " || c == "\t" || c == "\r" }
    static func isIdentifierStart(_ c: Character) -> Bool { c.isLetter || c == "_" }
    static func isIdentifier(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    mutating func skipSpaces() {
        while let c = current, Self.isSpace(c) { advance() }
    }

    mutating func skipSpacesAndNewlines() {
        while let c = current, Self.isSpace(c) || c == "\n" { advance() }
    }

    mutating func skipComment() {
        while let c = current, c != "\n" { advance() }
    }

    mutating func readIdentifier() -> String {
        var s = ""
        while let c = current, Self.isIdentifier(c) {
            s.append(c)
            advance()
        }
        return s
    }

    /// Characters until the end of the line, without the newline.
    mutating func readRestOfLine() -> String {
        var s = ""
        while let c = current, c != "\n" {
            s.append(c)
            advance()
        }
        return s
    }

    // MARK: File

    mutating func parseFile(name: String) -> Pipeline {
        var pipeline = Pipeline(name: name)
        parseFrontMatter(into: &pipeline)

        var kind: MediaKind?? = .none // .none: no section header seen yet
        var sections: [PipelineSection] = []
        var seenKinds: [MediaKind?: SourcePosition] = [:]
        var steps: [PipelineStep] = []
        var expectingStep = false // just read `->`
        var lastStepEnd: SourcePosition?

        func flush() {
            let k: MediaKind? = kind ?? nil
            if let i = sections.firstIndex(where: { $0.kind == k }) {
                sections[i].steps += steps
            } else if !steps.isEmpty || kind != nil {
                sections.append(PipelineSection(kind: k, steps: steps))
            }
            steps = []
        }

        while true {
            skipSpaces()
            guard let c = current else { break }
            if c == "\n" {
                advance()
                lastStepEnd = nil
                continue
            }
            if c == "#" {
                skipComment()
                continue
            }
            if c == "-", peek(1) == ">" {
                if lastStepEnd == nil, !expectingStep, steps.isEmpty {
                    error(pos, length: 2, "A pipeline cannot start with `->`. Remove it.", replacement: "")
                }
                if expectingStep {
                    error(pos, length: 2, "Two `->` in a row. Remove one.", replacement: "")
                }
                advance(); advance()
                expectingStep = true
                lastStepEnd = nil
                continue
            }
            if c == "[" {
                if expectingStep {
                    error(pos, "Expected a step after `->`, found a section header.")
                    expectingStep = false
                }
                let start = pos
                advance()
                skipSpaces()
                let word = readIdentifier()
                skipSpaces()
                if current == "]" {
                    advance()
                } else {
                    error(start, length: word.count + 2, "Section headers look like `[image]`. Add the closing `]`.")
                    skipComment()
                }
                skipSpaces()
                if let c = current, c != "\n", c != "#" {
                    error(pos, "Put steps on the line after the section header `[\(word)]`.")
                    skipComment()
                }
                let newKind: MediaKind?
                if word == "any" || word == "all" {
                    newKind = nil
                } else if let k = MediaKind(rawValue: word) {
                    newKind = k
                } else {
                    let suggestion = Self.closest(word, in: ["any"] + MediaKind.allCases.map(\.rawValue))
                    error(start, length: word.count + 2, "Unknown section `[\(word)]`. Sections are `[any]`, `[image]`, `[video]`, `[pdf]` and `[audio]`." + (suggestion.map { " Did you mean `[\($0)]`?" } ?? ""), replacement: suggestion.map { "[\($0)]" })
                    continue
                }
                if seenKinds[newKind] != nil {
                    warning(start, length: word.count + 2, "Section `[\(newKind?.rawValue ?? "any")]` appears twice; its steps are joined in order.")
                }
                flush()
                kind = .some(newKind)
                seenKinds[newKind] = start
                continue
            }
            if Self.isIdentifierStart(c) {
                if let end = lastStepEnd, !expectingStep {
                    error(end, "Missing `->` between steps. Write `step1 -> step2`, or put each step on its own line.", replacement: " ->")
                }
                if let raw = parseRawStep(), let step = buildStep(raw) {
                    steps.append(step)
                }
                expectingStep = false
                lastStepEnd = pos
                continue
            }
            let start = pos
            let rest = readRestOfLine()
            if c == ")" {
                error(start, "Unexpected `)`: there is no `(` to close.", replacement: "")
            } else {
                error(start, length: rest.count, "Unexpected `\(c)`. A step starts with its name, e.g. `optimise` or `convert(to: webp)`.")
            }
        }
        if expectingStep {
            error(pos, "The pipeline ends with `->`. Add a step after it or remove the arrow.")
        }
        flush()
        pipeline.sections = sections.filter { !$0.steps.isEmpty }
        return pipeline
    }

    // MARK: Front matter

    mutating func parseFrontMatter(into pipeline: inout Pipeline) {
        // Front matter is only recognised when `---` is the first non-blank line.
        let save = pos
        skipSpacesAndNewlines()
        guard current == "-", peek(1) == "-", peek(2) == "-" else {
            pos = save
            return
        }
        let open = pos
        _ = readRestOfLine()
        var closed = false
        var seen: Set<String> = []
        while !atEnd {
            advance() // newline
            skipSpaces()
            let lineStart = pos
            if current == "-", peek(1) == "-", peek(2) == "-" {
                _ = readRestOfLine()
                closed = true
                break
            }
            if current == "#" || current == "\n" || atEnd {
                skipComment()
                continue
            }
            let key = readIdentifier()
            skipSpaces()
            guard !key.isEmpty, current == ":" else {
                let rest = readRestOfLine()
                error(lineStart, length: max(1, key.count + rest.count), "Front matter lines look like `key: value`, e.g. `description: Convert to WebP`.")
                continue
            }
            advance()
            skipSpaces()
            let valuePos = pos
            let value = readRestOfLine().trimmingCharacters(in: .whitespaces)
            if seen.contains(key) {
                warning(lineStart, length: key.count, "`\(key)` is set twice; the last one counts.")
            }
            seen.insert(key)
            switch key {
            case "description": pipeline.description = value.isEmpty ? nil : unquote(value)
            case "hotkey": pipeline.hotkey = value.isEmpty ? nil : unquote(value)
            case "icon": pipeline.icon = value.isEmpty ? nil : unquote(value)
            case "optimiseFirst", "hideResult":
                guard let b = Self.bool(value) else {
                    error(valuePos, length: value.count, "`\(key)` must be `true` or `false`.")
                    continue
                }
                if key == "optimiseFirst" { pipeline.optimiseFirst = b } else { pipeline.hideResult = b }
            case "triggers":
                pipeline.triggers = parseTriggers(value, at: valuePos)
            default:
                let suggestion = Self.closest(key, in: PipelineLanguage.frontMatterKeys)
                error(lineStart, length: key.count, "Unknown front matter key `\(key)`." + (suggestion.map { " Did you mean `\($0)`?" } ?? " Known keys: " + PipelineLanguage.frontMatterKeys.joined(separator: ", ") + "."), replacement: suggestion)
            }
        }
        if !closed {
            error(open, length: 3, "The front matter opened here is never closed. Add a line with `---` after it.")
        }
    }

    func unquote(_ s: String) -> String {
        guard s.count >= 2, let f = s.first, f == "\"" || f == "'", s.last == f else { return s }
        return String(s.dropFirst().dropLast())
    }

    mutating func parseTriggers(_ text: String, at start: SourcePosition) -> [PipelineTrigger] {
        var triggers: [PipelineTrigger] = []
        var offset = 0
        for part in splitOutsideQuotes(text, on: ",") {
            defer { offset += part.count + 1 }
            let item = part.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { continue }
            let leading = part.prefix { $0 == " " || $0 == "\t" }.count
            let at = SourcePosition(index: start.index + offset + leading, line: start.line, column: start.column + offset + leading)
            var name = item
            var argument: String?
            if let open = item.firstIndex(of: "(") {
                name = String(item[..<open]).trimmingCharacters(in: .whitespaces)
                guard item.hasSuffix(")") else {
                    error(at, length: item.count, "Add the closing `)` to `\(item)`.")
                    continue
                }
                argument = unquote(String(item[item.index(after: open)...].dropLast()).trimmingCharacters(in: .whitespaces))
            }
            if name == "folder", argument?.isEmpty ?? true {
                error(at, length: item.count, "A folder trigger needs the folder: `folder(\"~/Downloads\")`.")
                continue
            }
            guard let trigger = PipelineTrigger(name: name, argument: argument) else {
                let suggestion = Self.closest(name, in: PipelineTrigger.allNames)
                error(at, length: item.count, "Unknown trigger `\(name)`." + (suggestion.map { " Did you mean `\($0)`?" } ?? " Triggers: " + PipelineTrigger.allNames.joined(separator: ", ") + "."), replacement: suggestion)
                continue
            }
            if argument != nil, name != "folder" {
                error(at, length: item.count, "`\(name)` takes no argument. Write `\(name)`.", replacement: name)
                continue
            }
            if !triggers.contains(trigger) { triggers.append(trigger) }
        }
        return triggers
    }

    // MARK: Steps

    mutating func parseRawStep() -> RawStep? {
        let start = pos
        let name = readIdentifier()
        var step = RawStep(name: name, position: start, arguments: [], hasParentheses: false)
        let afterName = pos
        skipSpaces()
        guard current == "(" else {
            pos = afterName
            return step
        }
        step.hasParentheses = true
        let open = pos
        advance()
        while true {
            skipSpacesAndNewlines()
            guard let c = current else {
                error(open, "`\(name)(` is never closed. Add `)` after its arguments.", replacement: nil)
                return nil
            }
            if c == ")" {
                advance()
                return step
            }
            guard let arg = parseArgument(stepName: name) else {
                // Recover: skip to the closing parenthesis or the end of the line.
                while let c = current, c != ")", c != "\n" { advance() }
                if current == ")" { advance() }
                return nil
            }
            step.arguments.append(arg)
            skipSpacesAndNewlines()
            if current == "," {
                advance()
                continue
            }
            if current == ")" { continue }
            if atEnd {
                error(open, "`\(name)(` is never closed. Add `)` after its arguments.")
                return nil
            }
            error(pos, "Expected `,` or `)` after the value of `\(arg.key ?? "the argument")`. Separate arguments with commas.", replacement: ", ")
            while let c = current, c != ")", c != "\n" { advance() }
            if current == ")" { advance() }
            return nil
        }
    }

    mutating func parseArgument(stepName: String) -> RawArgument? {
        let keyPos = pos
        var key: String?
        // `key:` or a bare (positional) value.
        if let c = current, Self.isIdentifierStart(c) {
            let save = pos
            let word = readIdentifier()
            skipSpaces()
            if current == ":" {
                advance()
                key = word
                skipSpaces()
            } else {
                pos = save
            }
        }
        let valuePos = pos
        guard let c = current else { return nil }
        if c == "\"" || c == "'" {
            advance()
            var value = ""
            while let d = current, d != c {
                if d == "\n" { break }
                value.append(d)
                advance()
            }
            guard current == c else {
                error(valuePos, length: value.count + 1, "This text is never closed. Add a matching \(c) at the end.")
                return nil
            }
            advance()
            return RawArgument(key: key, keyPosition: keyPos, value: value, quoted: true, valuePosition: valuePos, valueLength: value.count + 2)
        }
        // Bare value: up to `,` or `)` outside nested parentheses, never past the line.
        var value = ""
        var depth = 0
        while let d = current, d != "\n" {
            if d == "(" { depth += 1 }
            if d == ")" {
                if depth == 0 { break }
                depth -= 1
            }
            if d == ",", depth == 0 { break }
            value.append(d)
            advance()
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if let key {
                error(valuePos, "`\(key)` has no value. Write `\(key): <value>`.")
            } else if current == "," {
                error(valuePos, "Empty argument. Remove the extra comma.", replacement: "")
            } else {
                error(keyPos, "Expected an argument like `key: value`.")
            }
            return nil
        }
        return RawArgument(key: key, keyPosition: keyPos, value: trimmed, quoted: false, valuePosition: valuePos, valueLength: trimmed.count)
    }

    // MARK: Building typed steps

    mutating func buildStep(_ raw: RawStep) -> PipelineStep? {
        let name = raw.name
        guard let spec = PipelineLanguage.spec(named: name) else {
            let suggestion = PipelineLanguage.alias(for: name) ?? Self.closest(name, in: PipelineLanguage.steps.map(\.name))
            error(raw.position, length: name.count,
                  "Unknown step `\(name)`." + (suggestion.map { " Did you mean `\($0)`?" } ?? " See the list of steps in docs/pipelines.md."),
                  replacement: suggestion)
            return nil
        }

        var values: [String: RawArgument] = [:]
        var ok = true
        for (i, arg) in raw.arguments.enumerated() {
            var key = arg.key
            if key == nil {
                guard i == 0, let positional = spec.positional else {
                    let hint = spec.params.first.map { " Write `\($0.name): \(arg.value)`." } ?? ""
                    error(arg.valuePosition, length: arg.valueLength, "`\(name)` needs argument names." + hint)
                    ok = false
                    continue
                }
                key = positional
            }
            guard let key else { continue }
            guard let param = spec.param(key) else {
                if spec.params.isEmpty {
                    error(arg.keyPosition, length: key.count, "`\(name)` takes no arguments. Write `\(name)`.")
                } else {
                    let suggestion = Self.closest(key, in: spec.params.map(\.name))
                    error(arg.keyPosition, length: key.count,
                          "`\(name)` has no argument `\(key)`." + (suggestion.map { " Did you mean `\($0)`?" } ?? " It takes " + spec.params.map { "`\($0.name)`" }.joined(separator: ", ") + "."),
                          replacement: suggestion)
                }
                ok = false
                continue
            }
            if values[key] != nil {
                error(arg.keyPosition, length: key.count, "`\(key)` is given twice. Keep one.")
                ok = false
                continue
            }
            if !validate(arg, as: param, step: name) { ok = false }
            values[key] = arg
        }
        for param in spec.requiredParams where values[param.name] == nil {
            error(raw.position, length: name.count, "`\(name)` needs `\(param.name)` (\(param.type.summary)). For example: `\(spec.example)`.")
            ok = false
        }
        guard ok else { return nil }
        switch name {
        case "crop" where ["width", "height", "longEdge", "aspectRatio"].allSatisfy({ values[$0] == nil }):
            error(raw.position, length: name.count, "`crop` needs a size: `width`, `height`, `longEdge` or `aspectRatio`. For example: `crop(longEdge: 1600)` or `crop(aspectRatio: 16:9)`.")
            return nil
        case "runScript" where values["path"] == nil && values["code"] == nil:
            error(raw.position, length: name.count, "`runScript` needs `path` or `code`. For example: `runScript(code: \"sips -Z 800 $1\")`.")
            return nil
        case "runScript" where values["path"] != nil && values["code"] != nil:
            warning(raw.position, length: name.count, "`runScript` has both `path` and `code`; only `code` runs. Remove one.")
        case "if" where values.isEmpty, "ifNot" where values.isEmpty:
            error(raw.position, length: name.count, "`\(name)` needs a condition. For example: `\(name)(types: png)` or `\(name)(regex: \"^IMG_\")`.")
            return nil
        default: break
        }
        if name == "runScript", let code = values["code"] ?? values["path"], code.value.contains("CLOP_") {
            warning(code.valuePosition, length: code.valueLength, "This script uses Clop's variables. In esclop they are `$ESCLOP_BIN` and `$ESCLOP_INPUT_FILE`.",
                    replacement: PipelineSerializer.quote(code.value.replacingOccurrences(of: "CLOP_", with: "ESCLOP_")))
        }
        return makeStep(spec: spec, raw: raw, values: values)
    }

    /// Checks the value against its type and reports a precise error.
    mutating func validate(_ arg: RawArgument, as param: ParamSpec, step: String) -> Bool {
        let v = arg.value
        func fail(_ message: String, replacement: String? = nil) -> Bool {
            error(arg.valuePosition, length: arg.valueLength, message, replacement: replacement)
            return false
        }
        switch param.type {
        case let .integer(min, max):
            guard let n = Int(v) else { return fail("`\(param.name)` must be \(param.type.summary), not `\(v)`.") }
            if let min, n < min { return fail("`\(param.name)` must be \(param.type.summary); `\(v)` is too small.") }
            if let max, n > max { return fail("`\(param.name)` must be \(param.type.summary); `\(v)` is too large.") }
        case let .number(min, max, exclusive):
            guard let n = Double(v) else {
                if v.hasSuffix("%"), let pct = Double(v.dropLast()) {
                    return fail("`\(param.name)` takes a fraction, not a percentage. Write `\(PipelineSerializer.number(pct / 100))`.", replacement: PipelineSerializer.number(pct / 100))
                }
                return fail("`\(param.name)` must be \(param.type.summary), not `\(v)`.")
            }
            if let min, exclusive ? n <= min : n < min { return fail("`\(param.name)` must be \(param.type.summary); got `\(v)`.") }
            if let max, n > max {
                if param.name == "factor", step == "downscale" {
                    return fail("`factor` must be above 0 and at most 1: esclop only scales down. `0.5` is half size.")
                }
                return fail("`\(param.name)` must be \(param.type.summary); got `\(v)`.")
            }
        case .boolean:
            guard Self.bool(v) != nil else { return fail("`\(param.name)` must be `true` or `false`, not `\(v)`.") }
        case let .choice(values):
            if param.name == "frames", FrameBehaviour(text: v) != nil { break }
            if !values.contains(where: { $0.caseInsensitiveCompare(v) == .orderedSame }) {
                let suggestion = Self.closest(v, in: values)
                return fail("`\(v)` is not a valid `\(param.name)`." + (suggestion.map { " Did you mean `\($0)`?" } ?? "") + " Use \(param.type.summary).", replacement: suggestion)
            }
        case .byteSize:
            guard ByteSize.parse(v) != nil else { return fail("`\(param.name)` must be \(param.type.summary), not `\(v)`.") }
        case .duration:
            guard Durations.parse(v) != nil else { return fail("`\(param.name)` must be \(param.type.summary), not `\(v)`.") }
        case .aspectRatio:
            guard AspectRatio(v) != nil else { return fail("`\(param.name)` must be \(param.type.summary), not `\(v)`.") }
        case .resolution:
            guard Resolution.parse(v) != nil else { return fail("`\(param.name)` must be \(param.type.summary), not `\(v)`.") }
        case .compression:
            guard CompressionSetting(text: v) != nil else { return fail("`compression` must be \(param.type.summary), not `\(v)`.") }
        case .text, .typeList:
            if v.isEmpty { return fail("`\(param.name)` is empty.") }
        case .location:
            if v.isEmpty { return fail("`location` is empty. Use \(param.type.summary).") }
            if !arg.quoted, !["inPlace", "sameFolder", "temporaryFolder", "temporary"].contains(v),
               !v.contains("/"), !v.contains("%"), !v.contains("~")
            {
                let suggestion = Self.closest(v, in: ["inPlace", "sameFolder", "temporaryFolder"])
                if let suggestion {
                    return fail("Unknown location `\(v)`. Did you mean `\(suggestion)`? Quote it if it is a file name.", replacement: suggestion)
                }
            }
        }
        if case .text = param.type, !arg.quoted, v.contains(where: { $0 == "%" || $0 == "/" || $0 == "$" }) {
            // Clop accepts bare templates; nudge towards quotes, which survive commas and `->`.
            warning(arg.valuePosition, length: arg.valueLength, "Quote paths and templates: `\(param.name): \(PipelineSerializer.quote(v))`.", replacement: PipelineSerializer.quote(v))
        }
        return true
    }

    func makeStep(spec: StepSpec, raw: RawStep, values: [String: RawArgument]) -> PipelineStep? {
        func s(_ k: String) -> String? { values[k]?.value }
        func i(_ k: String) -> Int? { s(k).flatMap { Int($0) } }
        func d(_ k: String) -> Double? { s(k).flatMap { Double($0) } }
        func b(_ k: String) -> Bool? { s(k).flatMap(Self.bool) }
        func bytes(_ k: String) -> Int? { s(k).flatMap(ByteSize.parse) }
        func choice<T: RawRepresentable & CaseIterable>(_ k: String, _: T.Type) -> T? where T.RawValue == String {
            guard let v = s(k) else { return nil }
            return T.allCases.first { $0.rawValue.caseInsensitiveCompare(v) == .orderedSame }
        }
        func loc(_ k: String) -> OutputLocation? { s(k).map { OutputLocation(pipelineText: $0) } }
        func canonical(_ k: String) -> String? {
            guard let v = s(k), case let .choice(options)? = spec.param(k)?.type else { return s(k) }
            return options.first { $0.caseInsensitiveCompare(v) == .orderedSame } ?? v
        }

        switch spec.name {
        case "optimise":
            return .optimise(
                encoder: choice("encoder", EncoderPreset.self) ?? .medium, adaptive: b("adaptive") ?? false,
                dpi: i("dpi"), location: loc("location") ?? .inPlace, compression: s("compression").flatMap(CompressionSetting.init(text:))
            )
        case "downscale": return .downscale(factor: d("factor")!, location: loc("location") ?? .inPlace)
        case "lowerBitrate": return .lowerBitrate(kbps: i("kbps")!, location: loc("location") ?? .inPlace)
        case "convert": return .convert(to: canonical("to")!.lowercased(), location: loc("location") ?? .sameFolder)
        case "crop":
            let step = PipelineStep.crop(
                width: i("width"), height: i("height"), longEdge: i("longEdge"), aspectRatio: s("aspectRatio"),
                smartCrop: b("smartCrop") ?? false, location: loc("location") ?? .inPlace
            )
            return step
        case "extractPagesAsImages":
            return .extractPagesAsImages(format: choice("format", PageImageFormat.self) ?? .jpeg, quality: choice("quality", PageImageQuality.self) ?? .medium, location: loc("location") ?? .sameFolder)
        case "targetSize": return .targetSize(bytes: bytes("size")!, location: loc("location") ?? .inPlace)
        case "stripExif": return .stripExif
        case "watermark":
            return .watermark(image: s("image")!, position: choice("position", WatermarkPosition.self) ?? .bottomRight, opacity: d("opacity") ?? 1.0, scale: d("scale") ?? 0.15, location: loc("location") ?? .inPlace)
        case "copy": return .copy(to: s("to")!)
        case "move": return .move(to: s("to")!)
        case "rename": return .rename(to: s("to")!)
        case "delete": return .delete(path: s("path")!)
        case "if", "ifNot":
            let condition = FilterCondition(
                types: s("types").map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) },
                regex: s("regex"), nameContains: s("nameContains"), nameIs: s("nameIs"),
                fileSizeGreaterThan: bytes("fileSizeGreaterThan"), fileSizeLowerThan: bytes("fileSizeLowerThan"),
                widthGreaterThan: i("widthGreaterThan"), widthLowerThan: i("widthLowerThan"),
                heightGreaterThan: i("heightGreaterThan"), heightLowerThan: i("heightLowerThan"),
                dpiGreaterThan: i("dpiGreaterThan"), dpiLowerThan: i("dpiLowerThan"),
                minFileSize: bytes("minFileSize"), minResolution: s("minResolution").flatMap(Resolution.parse),
                copiedBy: s("copiedBy"), durationGreaterThan: d("durationGreaterThan"), durationLowerThan: d("durationLowerThan")
            )
            return spec.name == "if" ? .filterIf(condition) : .filterIfNot(condition)
        case "removeAudio": return .removeAudio
        case "changeSpeed": return .changeSpeed(factor: d("factor")!, frames: s("frames").flatMap(FrameBehaviour.init(text:)))
        case "capFps": return .capFps(fps: i("fps")!)
        case "normalize": return .normalize(lufs: d("lufs") ?? -16)
        case "runScript": return .runScript(path: s("path"), code: s("code"))
        case "runShortcut": return .runShortcut(name: s("name")!)
        case "copyToClipboard": return .copyToClipboard(format: choice("format", ClipboardFormat.self) ?? .path, relativeTo: s("relativeTo"))
        case "copyLinkForSending": return .copyLinkForSending(expiration: s("expiration").flatMap(Durations.parse))
        case "fork": return .fork(location: loc("location"))
        case "shelveWith": return .shelveWith(app: canonical("app")!.lowercased())
        case "uploadWith": return .uploadWith(app: canonical("app")!.lowercased())
        case "openWith": return .openWith(app: s("app")!)
        default: return nil
        }
    }
}

extension Parser {
    static func bool(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "true", "yes", "on": true
        case "false", "no", "off": false
        default: nil
        }
    }

    /// The candidate closest to `word` by edit distance, when it is close enough to be a typo.
    static func closest(_ word: String, in candidates: [String]) -> String? {
        let lower = word.lowercased()
        if let exact = candidates.first(where: { $0.lowercased() == lower }) { return exact }
        let scored = candidates.map { ($0, editDistance(lower, $0.lowercased())) }.min { $0.1 < $1.1 }
        guard let (best, distance) = scored else { return nil }
        let limit = max(1, min(3, best.count / 3))
        if distance <= limit { return best }
        if best.lowercased().hasPrefix(lower), lower.count >= 3 { return best }
        return nil
    }

    /// Damerau-Levenshtein distance (with adjacent transpositions).
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0 ... a.count { d[i][0] = i }
        for j in 0 ... b.count { d[0][j] = j }
        for i in 1 ... a.count {
            for j in 1 ... b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }
}

/// Splits on `separator` outside single or double quotes (quotes have no escapes, as in Clop).
func splitOutsideQuotes(_ text: String, on separator: Character) -> [String] {
    var parts: [String] = []
    var current = ""
    var quote: Character?
    for c in text {
        if c == "\"" || c == "'" {
            if quote == c { quote = nil } else if quote == nil { quote = c }
            current.append(c)
        } else if c == separator, quote == nil {
            parts.append(current)
            current = ""
        } else {
            current.append(c)
        }
    }
    parts.append(current)
    return parts
}

// MARK: - Value grammars

/// Byte sizes as Clop writes them: `kb`/`mb`/`gb` are powers of 1000, `kib`/`mib`/`gib` of 1024.
public enum ByteSize {
    static let units: [(String, Double)] = [
        ("gib", 1_073_741_824), ("gb", 1_000_000_000), ("mib", 1_048_576), ("mb", 1_000_000),
        ("kib", 1024), ("kb", 1000), ("b", 1),
    ]

    public static func parse(_ text: String) -> Int? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let n = Int(s) { return n >= 0 ? n : nil }
        for (suffix, multiplier) in units where s.hasSuffix(suffix) {
            if let n = Double(s.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)), n >= 0 {
                return Int((n * multiplier).rounded())
            }
        }
        return nil
    }

    /// The shortest exact spelling: `10MB`, `1.5MB`, `2MiB`, or the byte count.
    public static func format(_ bytes: Int) -> String {
        guard bytes > 0 else { return "0" }
        let units: [(String, Double, Bool)] = [("GB", 1e9, true), ("GiB", 1_073_741_824, false), ("MB", 1e6, true), ("MiB", 1_048_576, false), ("KB", 1e3, true), ("KiB", 1024, false)]
        for (suffix, unit, decimals) in units {
            let n = Double(bytes) / unit
            guard n >= 1 else { continue }
            let rounded = decimals ? (n * 100).rounded() / 100 : n.rounded()
            if Int((rounded * unit).rounded()) == bytes {
                return PipelineSerializer.number(rounded, keepPoint: false) + suffix
            }
        }
        return String(bytes)
    }
}

/// Durations as `copyLinkForSending(expiration:)` takes them. `never` is 0.
public enum Durations {
    public static func parse(_ text: String) -> TimeInterval? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        if s == "never" || s == "0" { return 0 }
        for (suffix, seconds) in [("d", 86400.0), ("h", 3600.0), ("m", 60.0), ("s", 1.0)] where s.hasSuffix(suffix) {
            if let n = Double(s.dropLast(suffix.count)), n >= 0 { return n * seconds }
        }
        if let n = Double(s), n >= 0 { return n }
        return nil
    }

    public static func format(_ seconds: TimeInterval) -> String {
        if seconds <= 0 { return "never" }
        for (suffix, unit) in [("d", 86400.0), ("h", 3600.0), ("m", 60.0)] where seconds.truncatingRemainder(dividingBy: unit) == 0 {
            return "\(Int(seconds / unit))\(suffix)"
        }
        return PipelineSerializer.number(seconds, keepPoint: false) + "s"
    }
}

/// `W:H` ratios. Decimals are allowed (`1.91:1`).
public struct AspectRatio: Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init?(_ text: String) {
        let sides = text.split(separator: ":")
        guard sides.count == 2,
              let w = Double(sides[0].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
              let h = Double(sides[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
              w > 0, h > 0
        else { return nil }
        width = w
        height = h
    }

    public var ratio: Double { width / height }
}

/// `640x480` (or a single number): the first number is the minimum edge, as in Clop.
public enum Resolution {
    public static func parse(_ text: String) -> Int? {
        let parts = text.lowercased().split(whereSeparator: { $0 == "x" || $0 == "×" })
        guard let first = parts.first, let n = Int(first.trimmingCharacters(in: .whitespaces)), n >= 0 else { return nil }
        return n
    }
}
