// SPDX-License-Identifier: GPL-3.0-or-later
//
// The minimal Settings window's data: every registry setting by section, filtered by the search
// field, written through the same provider the CLI and the MCP server use.

import EsclopCore
import EsclopIPC
import Foundation
import Observation

@MainActor @Observable
public final class SettingsViewModel {
    public struct Group: Identifiable {
        public var section: SettingsSection
        public var settings: [SettingDescriptor]
        public var id: String { section.rawValue }
    }

    public var query = ""
    public private(set) var descriptors: [SettingDescriptor] = []
    /// The last refusal per key, shown under the control.
    public private(set) var errors: [String: String] = [:]
    @ObservationIgnored let provider: any SettingsProvider
    @ObservationIgnored let onChange: (String, JSONValue) -> Void

    public init(provider: any SettingsProvider, onChange: @escaping (String, JSONValue) -> Void = { _, _ in }) {
        self.provider = provider
        self.onChange = onChange
        reload()
    }

    public func reload() {
        descriptors = provider.descriptors()
    }

    public var groups: [Group] {
        let matching = provider.search(query).map(\.key)
        let visible = descriptors.filter { matching.contains($0.key) }
        return SettingsSection.allCases.compactMap { section in
            let settings = visible.filter { Self.section(of: $0) == section }
            return settings.isEmpty ? nil : Group(section: section, settings: settings)
        }
    }

    /// The registry records the section in the schema (`x-section`).
    static func section(of descriptor: SettingDescriptor) -> SettingsSection {
        descriptor.jsonSchema?["x-section"]?.stringValue.flatMap(SettingsSection.init(rawValue:)) ?? .general
    }

    /// Stores a value typed or picked by the person. Returns false when it was refused.
    @discardableResult
    public func set(_ key: String, to text: String) -> Bool {
        do {
            let stored = try provider.setValue(text, forKey: key)
            errors[key] = nil
            if let index = descriptors.firstIndex(where: { $0.key == key }) { descriptors[index].value = stored }
            onChange(key, stored)
            return true
        } catch {
            errors[key] = (error as? EsclopError).map(Self.plain) ?? String(describing: error)
            return false
        }
    }

    public func value(_ key: String) -> JSONValue? {
        descriptors.first { $0.key == key }?.value
    }

    /// The text a field shows for a value: lists comma separated, numbers without a trailing .0.
    public static func text(for value: JSONValue?) -> String {
        switch value {
        case let .string(text): return text
        case let .array(items): return items.compactMap(\.stringValue).joined(separator: ", ")
        case let .some(other): return "\(other)"
        case nil: return ""
        }
    }

    static func plain(_ error: EsclopError) -> String {
        if case let .invalidArgument(why) = error { return why }
        return error.description
    }
}
