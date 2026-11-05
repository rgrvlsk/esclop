// SPDX-License-Identifier: GPL-3.0-or-later
//
// The pieces every tool uses: lenient argument reading, value conversion, the elicitation helper
// and the error a tool raises when the agent has to act.

import EsclopCore
import EsclopIPC
import Foundation
import MCP

// MARK: - Errors

/// A message for the agent to read and act on. Comes back as a tool result with `isError`.
public struct ToolFailure: Error, CustomStringConvertible, Sendable {
    public let message: String
    public let code: String

    public init(_ message: String, code: String = "toolFailure") {
        self.message = message
        self.code = code
    }

    public var description: String { message }
}

// MARK: - Value conversion

extension Value {
    public init(_ json: JSONValue) {
        switch json {
        case .null: self = .null
        case let .bool(v): self = .bool(v)
        case let .int(v): self = .int(v)
        case let .double(v): self = .double(v)
        case let .string(v): self = .string(v)
        case let .array(v): self = .array(v.map(Value.init))
        case let .object(v): self = .object(v.mapValues(Value.init))
        }
    }
}

extension JSONValue {
    public init(_ value: MCP.Value) {
        switch value {
        case .null: self = .null
        case let .bool(v): self = .bool(v)
        case let .int(v): self = .int(v)
        case let .double(v): self = .double(v)
        case let .string(v): self = .string(v)
        case let .data(mimeType, data): self = .string("data:\(mimeType ?? "application/octet-stream");base64,\(data.base64EncodedString())")
        case let .array(v): self = .array(v.map(JSONValue.init))
        case let .object(v): self = .object(v.mapValues(JSONValue.init))
        }
    }
}

// MARK: - Arguments

/// Reads tool arguments the way agents send them: numbers as strings, a single path where a list
/// is expected, `"true"` for true.
public struct ToolArguments: Sendable {
    public let values: [String: Value]

    public init(_ values: [String: Value]?) {
        self.values = values ?? [:]
    }

    public func has(_ key: String) -> Bool {
        guard let value = values[key] else { return false }
        switch value {
        case .null: return false
        case let .string(s): return !s.trimmingCharacters(in: .whitespaces).isEmpty
        case let .array(a): return !a.isEmpty
        default: return true
        }
    }

    public func string(_ key: String) -> String? {
        switch values[key] {
        case let .string(s)?:
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : s
        case let .int(n)?: return String(n)
        case let .double(d)?: return JSONValue.double(d).plain
        case let .bool(b)?: return b ? "true" : "false"
        default: return nil
        }
    }

    public func requiredString(_ key: String) throws -> String {
        guard let value = string(key) else { throw ToolFailure("\(key) is required", code: "invalidArgument") }
        return value
    }

    public func bool(_ key: String) -> Bool? {
        switch values[key] {
        case let .bool(b)?: return b
        case let .int(n)?: return n != 0
        case let .string(s)?:
            switch s.lowercased() {
            case "true", "yes", "1", "on": return true
            case "false", "no", "0", "off": return false
            default: return nil
            }
        default: return nil
        }
    }

    public func int(_ key: String) throws -> Int? {
        switch values[key] {
        case nil, .null?: return nil
        case let .int(n)?: return n
        case let .double(d)? where d.rounded() == d: return Int(d)
        case let .string(s)?:
            if s.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
            if let n = Int(s.trimmingCharacters(in: .whitespaces)) { return n }
        default: break
        }
        throw ToolFailure("\(key) takes a whole number", code: "invalidArgument")
    }

    public func double(_ key: String) throws -> Double? {
        switch values[key] {
        case nil, .null?: return nil
        case let .int(n)?: return Double(n)
        case let .double(d)?: return d
        case let .string(s)?:
            if s.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
            if let d = Double(s.trimmingCharacters(in: .whitespaces)) { return d }
        default: break
        }
        throw ToolFailure("\(key) takes a number", code: "invalidArgument")
    }

    /// A list of strings: an array, or one string (comma-separated lists are split for `split`).
    public func strings(_ key: String, splitCommas: Bool = false) -> [String] {
        switch values[key] {
        case let .array(items)?:
            return items.compactMap { item -> String? in
                if case let .string(s) = item { return s }
                return nil
            }
        case let .string(s)?:
            guard splitCommas else { return [s] }
            return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        default:
            return []
        }
    }

    /// Files from `paths` (or `path`), with `~`, file URLs and relative paths resolved, and folders
    /// expanded when asked.
    public func files(recursiveKey: String = "recursive", typesKey: String = "types") throws -> [URL] {
        var raw = strings("paths")
        if raw.isEmpty { raw = strings("path") }
        guard !raw.isEmpty else {
            throw ToolFailure("paths is required: a list of files or folders (absolute, ~/..., or file:// URLs)", code: "invalidArgument")
        }
        let urls = try raw.map { try PathInput.url($0) }
        let extensions = Set(strings(typesKey, splitCommas: true).map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        let files = PathInput.expand(urls, recursive: bool(recursiveKey) ?? false, extensions: extensions)
        guard !files.isEmpty else { throw ToolFailure("No media files found in \(raw.joined(separator: ", "))", code: "fileNotFound") }
        return files
    }
}

// MARK: - Output

public struct ToolOutput: Sendable {
    public var text: String
    public var structured: JSONValue?
    public var isError: Bool

    public init(_ text: String, structured: JSONValue? = nil, isError: Bool = false) {
        self.text = text
        self.structured = structured
        self.isError = isError
    }

    public init<T: Encodable>(_ text: String, encoding value: T, isError: Bool = false) {
        self.text = text
        self.structured = try? JSONValue.encode(value)
        self.isError = isError
    }

    /// Text first for a person reading the transcript, then the JSON for clients that ignore
    /// `structuredContent`.
    var result: CallTool.Result {
        var content: [MCP.Tool.Content] = [.text(text: text, annotations: nil, _meta: nil)]
        var structuredValue: Value?
        if var structured {
            if structured.objectValue == nil { structured = ["value": structured] }
            content.append(.text(text: structured.jsonString(pretty: true), annotations: nil, _meta: nil))
            structuredValue = Value(structured)
        }
        return CallTool.Result(content: content, structuredContent: structuredValue, isError: isError ? true : nil)
    }
}

// MARK: - Elicitation

/// Asks the person for a missing choice through the client, with a timeout. Every way it can fail
/// becomes a `ToolFailure` telling the agent what to ask in its own chat instead.
public struct Elicitor: Sendable {
    public let supported: @Sendable () async -> Bool
    public let request: @Sendable (String, Elicitation.RequestSchema) async throws -> CreateElicitation.Result
    public let timeout: TimeInterval

    public init(
        supported: @escaping @Sendable () async -> Bool,
        request: @escaping @Sendable (String, Elicitation.RequestSchema) async throws -> CreateElicitation.Result,
        timeout: TimeInterval
    ) {
        self.supported = supported
        self.request = request
        self.timeout = timeout
    }

    /// Never asks; for contexts without a client.
    public static let unavailable = Elicitor(supported: { false }, request: { _, _ in throw ToolFailure("no client") }, timeout: 0)

    /// - Parameters:
    ///   - missing: the argument name the agent can pass instead, e.g. `format`.
    ///   - options: the choices, listed in the fallback message.
    public func ask(_ message: String, schema: Elicitation.RequestSchema, missing: String, options: String) async throws -> [String: Value] {
        let fallback = "Pass \(missing) (\(options)) and call again."
        guard await supported() else {
            throw ToolFailure("\(message) This client cannot show L'Esclop's question (it does not support elicitation), so ask the person in the chat. \(fallback)", code: "needsInput")
        }
        let request = request
        let outcome: CreateElicitation.Result?
        do {
            outcome = try await withTimeout(timeout) { try await request(message, schema) }
        } catch let failure as ToolFailure {
            throw failure
        } catch {
            throw ToolFailure("\(message) The question could not be shown (\(error)). Ask the person in the chat. \(fallback)", code: "needsInput")
        }
        guard let outcome else {
            throw ToolFailure("\(message) Nobody answered within \(Int(timeout)) s. Ask the person in the chat. \(fallback)", code: "needsInput")
        }
        switch outcome.action {
        case .accept:
            return outcome.content ?? [:]
        case .decline:
            throw ToolFailure("The person declined to choose \(missing). Nothing was changed.", code: "declined")
        case .cancel:
            throw ToolFailure("The person dismissed the question about \(missing). Nothing was changed.", code: "cancelled")
        }
    }
}

/// Runs `operation`, returning nil when `seconds` pass first. The operation keeps running in the
/// background after a timeout (an unanswered elicitation is just left pending).
func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T? {
    try await withCheckedThrowingContinuation { continuation in
        let once = ResumeOnce(continuation)
        Task {
            do { once.resume(.success(try await operation())) } catch { once.resume(.failure(error)) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            once.resume(.success(nil))
        }
    }
}

/// Resumes a continuation at most once, whichever side gets there first.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Error>?

    init(_ continuation: CheckedContinuation<T?, Error>) { self.continuation = continuation }

    func resume(_ result: Result<T?, Error>) {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        current?.resume(with: result)
    }
}

// MARK: - Schema helpers

enum Schema {
    static func object(_ properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map(Value.string)) }
        return .object(schema)
    }

    static func string(_ description: String, enum values: [String]? = nil) -> Value {
        var schema: [String: Value] = ["type": "string", "description": .string(description)]
        if let values { schema["enum"] = .array(values.map(Value.string)) }
        return .object(schema)
    }

    static func number(_ description: String, minimum: Double? = nil, maximum: Double? = nil) -> Value {
        var schema: [String: Value] = ["type": "number", "description": .string(description)]
        if let minimum { schema["minimum"] = .double(minimum) }
        if let maximum { schema["maximum"] = .double(maximum) }
        return .object(schema)
    }

    static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> Value {
        var schema: [String: Value] = ["type": "integer", "description": .string(description)]
        if let minimum { schema["minimum"] = .int(minimum) }
        if let maximum { schema["maximum"] = .int(maximum) }
        return .object(schema)
    }

    static func bool(_ description: String) -> Value {
        ["type": "boolean", "description": .string(description)]
    }

    static func strings(_ description: String) -> Value {
        ["type": "array", "items": ["type": "string"], "description": .string(description)]
    }
}
