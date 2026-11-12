// SPDX-License-Identifier: GPL-3.0-or-later
//
// Declarative settings. Each `Setting` carries its key, default, title, description, section and
// JSON schema, and the `SettingsRegistry` lists them all so the Settings window, `esclop settings`
// and the MCP `esclop_settings_*` tools share one definition. Values live in the UserDefaults
// suite `Paths.defaultsSuite`, stored as plist primitives (enums as their raw string) so the app,
// the CLI and the MCP server read the same thing.

import Foundation

// MARK: - Sections

public enum SettingsSection: String, CaseIterable, Codable, Sendable {
    case general, interface, images, video, pdf, audio, clipboard, automation, output, backups, agents, updates, uploads

    public var title: String {
        switch self {
        case .general: return "General"
        case .interface: return "Interface"
        case .images: return "Images"
        case .video: return "Video"
        case .pdf: return "PDF"
        case .audio: return "Audio"
        case .clipboard: return "Clipboard"
        case .automation: return "Automation"
        case .output: return "Output"
        case .backups: return "Backups"
        case .agents: return "Agents"
        case .updates: return "Updates"
        case .uploads: return "Uploads"
        }
    }
}

// MARK: - Value types

/// A type a setting can hold. Conversions go both ways between the value, what UserDefaults
/// stores, JSON, and the text people type on the command line.
public protocol SettingValue: Sendable, Equatable {
    init?(storedValue: Any)
    var storedValue: Any { get }
    init?(json: JSONValue)
    var json: JSONValue { get }
    init?(text: String)
    static var schemaType: [String: JSONValue] { get }
}

extension Bool: SettingValue {
    public init?(storedValue: Any) {
        guard let number = storedValue as? NSNumber else { return nil }
        self = number.boolValue
    }
    public var storedValue: Any { self }
    public init?(json: JSONValue) {
        guard let value = json.boolValue else { return nil }
        self = value
    }
    public var json: JSONValue { .bool(self) }
    public init?(text: String) {
        switch text.lowercased() {
        case "true", "yes", "on", "1": self = true
        case "false", "no", "off", "0": self = false
        default: return nil
        }
    }
    public static var schemaType: [String: JSONValue] { ["type": "boolean"] }
}

extension Int: SettingValue {
    public init?(storedValue: Any) {
        guard let number = storedValue as? NSNumber else { return nil }
        self = number.intValue
    }
    public var storedValue: Any { self }
    public init?(json: JSONValue) {
        guard let value = json.intValue else { return nil }
        self = value
    }
    public var json: JSONValue { .int(self) }
    public init?(text: String) {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)) else { return nil }
        self = value
    }
    public static var schemaType: [String: JSONValue] { ["type": "integer"] }
}

extension Double: SettingValue {
    public init?(storedValue: Any) {
        guard let number = storedValue as? NSNumber else { return nil }
        self = number.doubleValue
    }
    public var storedValue: Any { self }
    public init?(json: JSONValue) {
        guard let value = json.doubleValue else { return nil }
        self = value
    }
    public var json: JSONValue { .double(self) }
    public init?(text: String) {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)) else { return nil }
        self = value
    }
    public static var schemaType: [String: JSONValue] { ["type": "number"] }
}

extension String: SettingValue {
    public init?(storedValue: Any) {
        guard let value = storedValue as? String else { return nil }
        self = value
    }
    public var storedValue: Any { self }
    public init?(json: JSONValue) {
        guard let value = json.stringValue else { return nil }
        self = value
    }
    public var json: JSONValue { .string(self) }
    public init?(text: String) { self = text }
    public static var schemaType: [String: JSONValue] { ["type": "string"] }
}

extension Array: SettingValue where Element == String {
    public init?(storedValue: Any) {
        guard let value = storedValue as? [String] else { return nil }
        self = value
    }
    public var storedValue: Any { self }
    public init?(json: JSONValue) {
        guard let items = json.arrayValue else { return nil }
        let strings = items.compactMap(\.stringValue)
        guard strings.count == items.count else { return nil }
        self = strings
    }
    public var json: JSONValue { .array(map { .string($0) }) }
    /// Comma separated on the command line: `webp,avif,heic`. A JSON array works too.
    public init?(text: String) {
        if text.hasPrefix("["), let value = [String](json: JSONValue(parsing: text)) {
            self = value
            return
        }
        self = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    public static var schemaType: [String: JSONValue] { ["type": "array", "items": ["type": "string"]] }
}

/// String-backed enums get every conversion for free: declare `extension MyEnum: SettingValue {}`.
public extension SettingValue where Self: CaseIterable & RawRepresentable, RawValue == String {
    init?(storedValue: Any) {
        guard let raw = storedValue as? String, let value = Self(rawValue: raw) else { return nil }
        self = value
    }
    var storedValue: Any { rawValue }
    init?(json: JSONValue) {
        guard let raw = json.stringValue, let value = Self(rawValue: raw) else { return nil }
        self = value
    }
    var json: JSONValue { .string(rawValue) }
    init?(text: String) {
        guard let value = Self(rawValue: text) else { return nil }
        self = value
    }
    static var schemaType: [String: JSONValue] {
        ["type": "string", "enum": .array(allCases.map { .string($0.rawValue) })]
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Storage

/// Where setting values live. `shared` is the app's suite; tests make their own.
public final class SettingsStore: @unchecked Sendable {
    // UserDefaults is documented as thread safe.
    public let defaults: UserDefaults
    public let suiteName: String?

    public static let shared = SettingsStore(suiteName: Paths.defaultsSuite)

    public init(suiteName: String) {
        self.suiteName = suiteName
        // Inside the app, the suite is the app's own domain, which UserDefaults refuses as a
        // suite name; the standard defaults are the same file there.
        if Bundle.main.bundleIdentifier == suiteName {
            defaults = .standard
        } else {
            defaults = UserDefaults(suiteName: suiteName) ?? .standard
        }
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        suiteName = nil
    }

    /// Removes every stored value from the suite. Meant for tests and "reset all".
    public func removeAll() {
        if let suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        for key in SettingsRegistry.shared.keys {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - Settings

public struct Setting<Value: SettingValue>: Sendable {
    public let key: String
    public let defaultValue: Value
    public let title: String
    public let description: String
    public let section: SettingsSection
    public let minimum: Double?
    public let maximum: Double?
    /// Extra schema keywords: `enum` for allowed numbers, `examples`, `format`...
    public let schemaExtras: [String: JSONValue]

    public init(
        _ key: String, default defaultValue: Value, title: String, description: String,
        section: SettingsSection, minimum: Double? = nil, maximum: Double? = nil,
        schema schemaExtras: [String: JSONValue] = [:]
    ) {
        self.key = key
        self.defaultValue = defaultValue
        self.title = title
        self.description = description
        self.section = section
        self.minimum = minimum
        self.maximum = maximum
        self.schemaExtras = schemaExtras
    }

    /// JSON schema fragment for this setting.
    public var schema: JSONValue {
        var fragment = Value.schemaType
        fragment["title"] = .string(title)
        fragment["description"] = .string(description)
        fragment["default"] = defaultValue.json
        fragment["x-section"] = .string(section.rawValue)
        if let minimum { fragment["minimum"] = Self.number(minimum) }
        if let maximum { fragment["maximum"] = Self.number(maximum) }
        for (key, value) in schemaExtras { fragment[key] = value }
        return .object(fragment)
    }

    private static func number(_ value: Double) -> JSONValue {
        value.rounded() == value ? .int(Int(value)) : .double(value)
    }

    /// The current value, or the default when nothing valid is stored.
    public func value(in store: SettingsStore = .shared) -> Value {
        guard let stored = store.defaults.object(forKey: key), let value = Value(storedValue: stored) else {
            return defaultValue
        }
        return value
    }

    public var value: Value { value(in: .shared) }

    public func isSet(in store: SettingsStore = .shared) -> Bool {
        store.defaults.object(forKey: key) != nil
    }

    public func set(_ value: Value, in store: SettingsStore = .shared) throws {
        try validate(value)
        store.defaults.set(value.storedValue, forKey: key)
    }

    public func reset(in store: SettingsStore = .shared) {
        store.defaults.removeObject(forKey: key)
    }

    public func validate(_ value: Value) throws {
        let number: Double? = (value as? Int).map(Double.init) ?? (value as? Double)
        if let number {
            if let minimum, number < minimum {
                throw EsclopError.invalidArgument("\(key) must be at least \(Self.number(minimum)), got \(value.json)")
            }
            if let maximum, number > maximum {
                throw EsclopError.invalidArgument("\(key) must be at most \(Self.number(maximum)), got \(value.json)")
            }
        }
        if case let .array(allowed)? = schemaExtras["enum"], !allowed.contains(value.json) {
            throw EsclopError.invalidArgument("\(key) must be one of \(JSONValue.array(allowed)), got \(value.json)")
        }
    }

    public var erased: AnySetting { AnySetting(self) }
}

/// A setting with its value type erased, for listing, the CLI and MCP.
public struct AnySetting: Sendable, Identifiable {
    public let key: String
    public let title: String
    public let description: String
    public let section: SettingsSection
    public let schema: JSONValue
    public let defaultJSON: JSONValue

    private let getter: @Sendable (SettingsStore) -> JSONValue
    private let setter: @Sendable (SettingsStore, JSONValue) throws -> Void
    private let parser: @Sendable (String) -> JSONValue?
    private let resetter: @Sendable (SettingsStore) -> Void
    private let isSetter: @Sendable (SettingsStore) -> Bool
    private let validator: @Sendable (JSONValue) throws -> Void

    public var id: String { key }

    public init<Value>(_ setting: Setting<Value>) {
        key = setting.key
        title = setting.title
        description = setting.description
        section = setting.section
        schema = setting.schema
        defaultJSON = setting.defaultValue.json
        getter = { setting.value(in: $0).json }
        let decode: @Sendable (JSONValue) throws -> Value = { json in
            guard let value = Value(json: json) else {
                throw EsclopError.invalidArgument("\(setting.key) expects \(Value.schemaType["type"]?.stringValue ?? "a value"), got \(json)")
            }
            try setting.validate(value)
            return value
        }
        setter = { store, json in try setting.set(decode(json), in: store) }
        validator = { json in _ = try decode(json) }
        parser = { text in Value(text: text)?.json }
        resetter = { setting.reset(in: $0) }
        isSetter = { setting.isSet(in: $0) }
    }

    public func get(in store: SettingsStore = .shared) -> JSONValue { getter(store) }
    public func set(_ json: JSONValue, in store: SettingsStore = .shared) throws { try setter(store, json) }

    /// Sets from command-line text: tries the type's own parser first, then JSON.
    public func set(text: String, in store: SettingsStore = .shared) throws {
        if let json = parser(text) {
            try setter(store, json)
        } else {
            try setter(store, JSONValue(parsing: text))
        }
    }

    public func reset(in store: SettingsStore = .shared) { resetter(store) }
    public func isSet(in store: SettingsStore = .shared) -> Bool { isSetter(store) }
    /// Throws when `json` is not a valid value for this setting; writes nothing.
    public func validate(_ json: JSONValue) throws { try validator(json) }
}

// MARK: - Registry

/// Every setting esclop knows. Pre-filled with `EsclopSettings.all`; other modules (the app's
/// appearance settings, for example) add theirs with `register`.
public final class SettingsRegistry: @unchecked Sendable {
    public static let shared = SettingsRegistry(EsclopSettings.all)

    private let lock = NSLock()
    private var ordered: [AnySetting]

    public init(_ settings: [AnySetting]) {
        ordered = []
        for setting in settings { register(setting) }
    }

    public var all: [AnySetting] {
        lock.lock(); defer { lock.unlock() }
        return ordered
    }

    public var keys: [String] { all.map(\.key) }

    /// Adds a setting, replacing one with the same key.
    public func register(_ setting: AnySetting) {
        lock.lock(); defer { lock.unlock() }
        if let index = ordered.firstIndex(where: { $0.key == setting.key }) {
            ordered[index] = setting
        } else {
            ordered.append(setting)
        }
    }

    public func register<Value>(_ setting: Setting<Value>) { register(setting.erased) }

    public func setting(_ key: String) -> AnySetting? {
        all.first { $0.key == key }
    }

    public func settings(in section: SettingsSection) -> [AnySetting] {
        all.filter { $0.section == section }
    }

    /// Case-insensitive search over keys, titles and descriptions (the Settings window search).
    public func search(_ query: String) -> [AnySetting] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return all }
        return all.filter { setting in
            let haystack = "\(setting.key) \(setting.title) \(setting.description) \(setting.section.title)".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private func require(_ key: String) throws -> AnySetting {
        guard let setting = setting(key) else {
            throw EsclopError.invalidArgument("Unknown setting \(key)")
        }
        return setting
    }

    public func get(_ key: String, in store: SettingsStore = .shared) throws -> JSONValue {
        try require(key).get(in: store)
    }

    public func set(_ key: String, to json: JSONValue, in store: SettingsStore = .shared) throws {
        try require(key).set(json, in: store)
    }

    public func set(_ key: String, text: String, in store: SettingsStore = .shared) throws {
        try require(key).set(text: text, in: store)
    }

    public func reset(_ key: String, in store: SettingsStore = .shared) throws {
        try require(key).reset(in: store)
    }

    /// Every key with its current value.
    public func snapshot(in store: SettingsStore = .shared) -> [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0.get(in: store)) })
    }

    /// Applies several values at once; nothing is written when one of them is invalid.
    public func apply(_ values: [String: JSONValue], in store: SettingsStore = .shared) throws {
        for (key, value) in values { try require(key).validate(value) }
        for (key, value) in values { try set(key, to: value, in: store) }
    }

    /// A JSON Schema (draft 2020-12) object describing every setting.
    public func schema() -> JSONValue {
        var properties: [String: JSONValue] = [:]
        for setting in all { properties[setting.key] = setting.schema }
        return [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "title": "esclop settings",
            "type": "object",
            "additionalProperties": false,
            "properties": .object(properties),
        ]
    }
}
