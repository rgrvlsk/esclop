// SPDX-License-Identifier: GPL-3.0-or-later
//
// Settings as the CLI and the MCP server see them: `RegistrySettingsProvider` over EsclopCore's
// `SettingsRegistry`, or `InMemorySettingsProvider` in tests. The four agent permissions are
// registry keys (section `agents`) that agents can read and never write.

import EsclopCore
import Foundation

// MARK: - Descriptor

public struct SettingDescriptor: Codable, Hashable, Sendable {
    public enum ValueType: String, Codable, Sendable {
        case bool, int, double, string, choice
    }

    public var key: String
    public var title: String
    public var summary: String
    public var type: ValueType
    public var defaultValue: JSONValue
    /// The current value, filled in by the provider.
    public var value: JSONValue?
    /// Allowed values for `choice`.
    public var choices: [String]?
    public var minimum: Double?
    public var maximum: Double?
    /// Words the Settings search matches, besides the title and summary.
    public var keywords: [String]
    /// False for settings an agent may never change through MCP, whatever the permissions say.
    public var agentWritable: Bool
    /// The registry's own JSON Schema fragment, when it has one.
    public var jsonSchema: JSONValue?

    public init(
        key: String, title: String, summary: String, type: ValueType, defaultValue: JSONValue,
        value: JSONValue? = nil, choices: [String]? = nil, minimum: Double? = nil, maximum: Double? = nil,
        keywords: [String] = [], agentWritable: Bool = true, jsonSchema: JSONValue? = nil
    ) {
        self.key = key
        self.title = title
        self.summary = summary
        self.type = type
        self.defaultValue = defaultValue
        self.value = value
        self.choices = choices
        self.minimum = minimum
        self.maximum = maximum
        self.keywords = keywords
        self.agentWritable = agentWritable
        self.jsonSchema = jsonSchema
    }

    /// The JSON Schema fragment for this setting's value.
    public var schema: JSONValue {
        if let jsonSchema { return jsonSchema }
        var schema: [String: JSONValue] = ["title": .string(title), "description": .string(summary), "default": defaultValue]
        switch type {
        case .bool: schema["type"] = "boolean"
        case .int: schema["type"] = "integer"
        case .double: schema["type"] = "number"
        case .string: schema["type"] = "string"
        case .choice:
            schema["type"] = "string"
            schema["enum"] = .array((choices ?? []).map(JSONValue.string))
        }
        if let minimum { schema["minimum"] = .double(minimum) }
        if let maximum { schema["maximum"] = .double(maximum) }
        return .object(schema)
    }

    /// Parses the string form a person or agent types into a value of this setting's type.
    public func parse(_ text: String) throws -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .bool:
            switch trimmed.lowercased() {
            case "true", "yes", "on", "1": return .bool(true)
            case "false", "no", "off", "0": return .bool(false)
            default: throw EsclopError.invalidArgument("\(key) takes true or false, not \(text)")
            }
        case .int:
            guard let value = Int(trimmed) else { throw EsclopError.invalidArgument("\(key) takes a whole number, not \(text)") }
            try checkRange(Double(value))
            return .int(value)
        case .double:
            guard let value = Double(trimmed) else { throw EsclopError.invalidArgument("\(key) takes a number, not \(text)") }
            try checkRange(value)
            return .double(value)
        case .string:
            return .string(text)
        case .choice:
            let options = choices ?? []
            guard let match = options.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
                throw EsclopError.invalidArgument("\(key) takes one of \(options.joined(separator: ", ")), not \(text)")
            }
            return .string(match)
        }
    }

    private func checkRange(_ value: Double) throws {
        if let minimum, value < minimum { throw EsclopError.invalidArgument("\(key) must be at least \(JSONValue.double(minimum))") }
        if let maximum, value > maximum { throw EsclopError.invalidArgument("\(key) must be at most \(JSONValue.double(maximum))") }
    }

    /// True when every word of `query` appears in the key, title, summary or keywords.
    public func matches(_ query: String) -> Bool {
        let haystack = ([key, title, summary] + keywords).joined(separator: " ").lowercased()
        return query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .allSatisfy { haystack.contains($0) }
    }
}

// MARK: - Agent permissions

/// What the person allows agents to do through MCP. Every one is off until the person turns it on.
public enum AgentPermission: String, CaseIterable, Codable, Sendable {
    case allowOverwriteOriginals
    case allowDeleteBackups
    case allowRunScripts
    case allowSettingsChanges
    case allowUploads

    public var title: String {
        switch self {
        case .allowOverwriteOriginals: return "Let agents overwrite originals"
        case .allowDeleteBackups: return "Let agents delete backups"
        case .allowRunScripts: return "Let agents run script and Shortcut steps"
        case .allowSettingsChanges: return "Let agents change settings and automations"
        case .allowUploads: return "Let agents upload files"
        }
    }

    public var summary: String {
        switch self {
        case .allowOverwriteOriginals:
            return "MCP tools may replace a file in place (a backup is still kept). Off: results are written next to the original."
        case .allowDeleteBackups:
            return "MCP tools may delete the backup of an original, for example after restoring it."
        case .allowRunScripts:
            return "MCP tools may save or run pipelines with runScript or runShortcut steps."
        case .allowSettingsChanges:
            return "MCP tools may change settings, replace pipelines and attach pipelines to the clipboard, drop zone or folders."
        case .allowUploads:
            return "MCP tools may upload images, videos, PDFs and audio to the upload targets set in L'Esclop, and get their links; anyone with a link can open the file if the bucket is public."
        }
    }

    public var descriptor: SettingDescriptor {
        SettingDescriptor(
            key: rawValue, title: title, summary: summary, type: .bool, defaultValue: false,
            keywords: ["mcp", "agent", "ai", "permission", "allow"], agentWritable: false
        )
    }
}

/// Reads the agent permissions. Anything that cannot be read counts as not allowed.
public protocol AgentPermissionReading: Sendable {
    func isAllowed(_ permission: AgentPermission) -> Bool
}

// MARK: - Provider

public protocol SettingsProvider: AgentPermissionReading {
    /// Every setting with its current value filled in.
    func descriptors() -> [SettingDescriptor]
    func value(forKey key: String) throws -> JSONValue
    /// Parses `text` for the setting's type, stores it and returns the stored value.
    func setValue(_ text: String, forKey key: String) throws -> JSONValue
    /// Removes the stored value so the default applies again; returns the default.
    func resetValue(forKey key: String) throws -> JSONValue
}

extension SettingsProvider {
    public func descriptor(forKey key: String) throws -> SettingDescriptor {
        guard let found = descriptors().first(where: { $0.key == key }) else {
            let near = descriptors().filter { $0.key.lowercased().contains(key.lowercased()) || key.lowercased().contains($0.key.lowercased()) }
            let hint = near.isEmpty ? "esclop settings schema lists every key" : "did you mean \(near.map(\.key).joined(separator: ", "))?"
            throw EsclopError.invalidArgument("No setting named \(key): \(hint)")
        }
        return found
    }

    public func search(_ query: String?) -> [SettingDescriptor] {
        let all = descriptors()
        guard let query, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        return all.filter { $0.matches(query) }
    }

    public func isAllowed(_ permission: AgentPermission) -> Bool {
        (try? value(forKey: permission.rawValue))?.boolValue ?? false
    }
}

/// Settings from EsclopCore's `SettingsRegistry` (stored in the app's defaults suite), so the CLI,
/// the MCP server and the app read and write the same values. The `agents` section (the four
/// permissions) is never writable by an agent.
public struct RegistrySettingsProvider: SettingsProvider {
    public let registry: SettingsRegistry
    public let store: SettingsStore

    public init(registry: SettingsRegistry = .shared, store: SettingsStore = .shared) {
        self.registry = registry
        self.store = store
    }

    public func descriptors() -> [SettingDescriptor] {
        registry.all.map { setting in
            let schema = setting.schema
            let type: SettingDescriptor.ValueType
            switch schema["type"]?.stringValue {
            case "boolean": type = .bool
            case "integer": type = .int
            case "number": type = .double
            case "string" where schema["enum"] != nil: type = .choice
            case "string": type = .string
            default: type = .string // arrays and objects: set as text, the registry parses it
            }
            return SettingDescriptor(
                key: setting.key, title: setting.title, summary: setting.description, type: type,
                defaultValue: setting.defaultJSON, value: setting.get(in: store),
                choices: schema["enum"]?.arrayValue?.compactMap(\.stringValue),
                minimum: schema["minimum"]?.doubleValue, maximum: schema["maximum"]?.doubleValue,
                keywords: [setting.section.rawValue, setting.section.title],
                agentWritable: setting.section != .agents && AgentPermission(rawValue: setting.key) == nil,
                jsonSchema: schema
            )
        }
    }

    public func value(forKey key: String) throws -> JSONValue {
        _ = try descriptor(forKey: key)
        return try registry.get(key, in: store)
    }

    public func setValue(_ text: String, forKey key: String) throws -> JSONValue {
        _ = try descriptor(forKey: key)
        try registry.set(key, text: text, in: store)
        return try registry.get(key, in: store)
    }

    public func resetValue(forKey key: String) throws -> JSONValue {
        _ = try descriptor(forKey: key)
        try registry.reset(key, in: store)
        return try registry.get(key, in: store)
    }
}

/// In-memory settings, for tests and previews.
public final class InMemorySettingsProvider: SettingsProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: JSONValue]
    private let known: [SettingDescriptor]

    public init(descriptors: [SettingDescriptor] = AgentPermission.allCases.map(\.descriptor), values: [String: JSONValue] = [:]) {
        self.known = descriptors
        self.values = values
    }

    public func descriptors() -> [SettingDescriptor] {
        lock.lock(); defer { lock.unlock() }
        return known.map { var d = $0; d.value = values[$0.key] ?? $0.defaultValue; return d }
    }

    public func value(forKey key: String) throws -> JSONValue {
        let descriptor = try descriptor(forKey: key)
        lock.lock(); defer { lock.unlock() }
        return values[key] ?? descriptor.defaultValue
    }

    public func setValue(_ text: String, forKey key: String) throws -> JSONValue {
        let value = try descriptor(forKey: key).parse(text)
        lock.lock(); defer { lock.unlock() }
        values[key] = value
        return value
    }

    public func resetValue(forKey key: String) throws -> JSONValue {
        let descriptor = try descriptor(forKey: key)
        lock.lock(); defer { lock.unlock() }
        values[key] = nil
        return descriptor.defaultValue
    }
}
