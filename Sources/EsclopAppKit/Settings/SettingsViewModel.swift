// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Settings window's data: every registry setting by pane, the search, the deep-link target,
// and the writes. Values go through the same `SettingsProvider` (the registry) as `esclop settings`
// and the MCP server, and the window follows changes they make: it observes each key in the
// defaults suite, which reports writes from other processes too.

import EsclopCore
import EsclopIPC
import Foundation
import Observation

@MainActor @Observable
public final class SettingsViewModel {
    public struct Group: Identifiable {
        public var section: SettingsSection
        public var heading: String?
        public var settings: [SettingDescriptor]
        public var id: String { section.rawValue }
    }

    /// A row the search finds: a registry setting, or one of the window's own rows (hotkeys).
    public struct Hit: Identifiable, Hashable {
        public var id: String
        public var title: String
        public var summary: String
        public var pane: SettingsPane
    }

    /// Rows that are not registry settings but should still be found by the search.
    public struct ExtraRow: Sendable {
        public var id: String
        public var title: String
        public var summary: String
        public var pane: SettingsPane
        public var keywords: [String]

        public init(id: String, title: String, summary: String, pane: SettingsPane, keywords: [String] = []) {
            self.id = id
            self.title = title
            self.summary = summary
            self.pane = pane
            self.keywords = keywords
        }
    }

    public var query = ""
    /// The language the settings are shown in; tests set Catalan, the app follows `Strings`.
    @ObservationIgnored var locale = Strings.locale

    public var pane: SettingsPane = .general
    /// The row a deep link or a search result points at; the pane scrolls to it and marks it.
    public var highlighted: String?
    public private(set) var descriptors: [SettingDescriptor] = []
    /// The last refusal per key, shown under the control until the next good value.
    public private(set) var errors: [String: String] = [:]

    @ObservationIgnored let provider: any SettingsProvider
    /// The Keychain and the test upload, for Settings › Uploads.
    @ObservationIgnored public var uploads: UploadSettingsSupport?

    /// The upload targets in the setting.
    public var uploadTargets: [UploadTarget] {
        UploadTarget.decode((value(EsclopSettings.uploadTargets.key)?.arrayValue ?? []).compactMap(\.stringValue))
    }
    @ObservationIgnored let extraRows: [ExtraRow]
    @ObservationIgnored let onChange: (String, JSONValue) -> Void
    @ObservationIgnored private var observer: DefaultsObserver?

    /// `defaults`: the suite to watch for changes made elsewhere (the CLI, the MCP server).
    public init(
        provider: any SettingsProvider, defaults: UserDefaults? = nil, extraRows: [ExtraRow] = [],
        onChange: @escaping (String, JSONValue) -> Void = { _, _ in }
    ) {
        self.provider = provider
        self.extraRows = extraRows
        self.onChange = onChange
        reload()
        if let defaults {
            observer = DefaultsObserver(defaults: defaults, keys: descriptors.map(\.key)) { [weak self] key in
                Task { @MainActor in self?.reload(key) }
            }
        }
    }

    // MARK: Reading

    public func reload() {
        // In the app's language; the registry and the CLI stay English.
        descriptors = provider.descriptors().map { SettingWords.localised($0, locale: locale) }
    }

    /// Picks up one key's new value, written here or by another process.
    func reload(_ key: String) {
        guard let index = descriptors.firstIndex(where: { $0.key == key }),
              let value = try? provider.value(forKey: key), descriptors[index].value != value else { return }
        descriptors[index].value = value
        errors[key] = nil
    }

    public func descriptor(_ key: String) -> SettingDescriptor? {
        descriptors.first { $0.key == key }
    }

    public func value(_ key: String) -> JSONValue? {
        descriptor(key)?.value
    }

    public var values: [String: JSONValue] {
        Dictionary(descriptors.map { ($0.key, $0.value ?? $0.defaultValue) }, uniquingKeysWith: { first, _ in first })
    }

    /// The registry records each setting's section in its schema (`x-section`).
    static func section(of descriptor: SettingDescriptor) -> SettingsSection {
        descriptor.jsonSchema?["x-section"]?.stringValue.flatMap(SettingsSection.init(rawValue:)) ?? .general
    }

    public func groups(in pane: SettingsPane) -> [Group] {
        pane.sections.compactMap { section in
            let settings = descriptors.filter { Self.section(of: $0) == section }
            return settings.isEmpty ? nil : Group(section: section, heading: pane.heading(for: section), settings: settings)
        }
    }

    /// The pane that shows a row: a registry key or an extra row's id. Nil for an unknown row.
    public func pane(of row: String) -> SettingsPane? {
        if let descriptor = descriptor(row) { return SettingsPane.pane(for: Self.section(of: descriptor)) }
        return extraRows.first { $0.id == row }?.pane
    }

    public func isEnabled(_ key: String) -> Bool {
        SettingPresentation.isEnabled(key, values: values)
    }

    /// True when the value is not the default, so the row offers a reset.
    public func isModified(_ key: String) -> Bool {
        guard let descriptor = descriptor(key) else { return false }
        return !Self.same(descriptor.value ?? descriptor.defaultValue, descriptor.defaultValue)
    }

    /// 30 and 30.0 are the same value.
    static func same(_ a: JSONValue, _ b: JSONValue) -> Bool {
        if let x = a.doubleValue, let y = b.doubleValue { return x == y }
        return a == b
    }

    // MARK: Search

    /// Every row matching all the words of the query, in pane order.
    public var hits: [Hit] {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard !words.isEmpty else { return [] }
        func matches(_ fields: [String]) -> Bool {
            let haystack = fields.joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        var found: [Hit] = []
        for pane in SettingsPane.allCases {
            for group in groups(in: pane) {
                for setting in group.settings where matches([setting.key, setting.title, setting.summary, pane.title, pane.englishTitle, group.heading ?? ""] + setting.keywords) {
                    found.append(Hit(id: setting.key, title: setting.title, summary: setting.summary, pane: pane))
                }
            }
            for row in extraRows where row.pane == pane && matches([row.id, row.title, row.summary, pane.title, pane.englishTitle] + row.keywords) {

                found.append(Hit(id: row.id, title: row.title, summary: row.summary, pane: pane))
            }
        }
        return found
    }

    // MARK: Navigation

    public func open(_ route: SettingsRoute) {
        if let pane = route.pane { self.pane = pane }
        highlighted = route.row
    }

    public func open(_ hit: Hit) {
        open(SettingsRoute(pane: hit.pane, row: hit.id))
    }

    public func link(to row: String) -> URL? {
        pane(of: row).map { SettingsRoute.link(pane: $0, row: row) }
    }

    // MARK: Writing

    /// Why `text` is not a valid value for the setting, or nil when it is. Writes nothing.
    public func problem(_ key: String, text: String) -> String? {
        guard let descriptor = descriptor(key) else { return Strings.text("Unknown setting") }
        do {
            let value = try descriptor.parse(text)
            if let allowed = descriptor.jsonSchema?["enum"]?.arrayValue, !allowed.contains(where: { Self.same($0, value) }) {
                return Strings.format("Pick one of %@", allowed.map { SettingPresentation.text(for: $0) }.joined(separator: ", "))
            }
            return nil
        } catch {
            return Self.plain(error, key: key)
        }
    }

    /// Stores a value typed by the person. Returns false when it was refused; the reason is in `errors`.
    @discardableResult
    public func set(_ key: String, text: String) -> Bool {
        do {
            let stored = try provider.setValue(text, forKey: key)
            accept(key, stored)
            return true
        } catch {
            errors[key] = Self.plain(error, key: key)
            return false
        }
    }

    /// Stores a value picked with a control.
    @discardableResult
    public func set(_ key: String, to value: JSONValue) -> Bool {
        set(key, text: Self.text(for: value))
    }

    public func reset(_ key: String) {
        do {
            accept(key, try provider.resetValue(forKey: key))
        } catch {
            errors[key] = Self.plain(error, key: key)
        }
    }

    /// Every setting back to its default; the agent permissions are switched off again too.
    public func resetAll() {
        for descriptor in descriptors where isModified(descriptor.key) {
            reset(descriptor.key)
        }
    }

    private func accept(_ key: String, _ stored: JSONValue) {
        errors[key] = nil
        if let index = descriptors.firstIndex(where: { $0.key == key }) { descriptors[index].value = stored }
        onChange(key, stored)
    }

    /// The text the provider parses for a value: lists as a JSON array, so commas inside items survive.
    static func text(for value: JSONValue) -> String {
        switch value {
        case let .array(items):
            let strings = items.compactMap(\.stringValue)
            let data = (try? JSONEncoder().encode(strings)) ?? Data("[]".utf8)
            return String(decoding: data, as: UTF8.self)
        case let .string(text): return text
        case let .bool(flag): return flag ? "true" : "false"
        case let .int(number): return String(number)
        case let .double(number): return SettingPresentation.number(number)
        default: return SettingPresentation.text(for: value)
        }
    }

    /// The registry's reason in the window's words: "imageCompression must be at most 100, got
    /// 101" reads "Must be at most 100, got 101" under the row that already names the setting.
    static func plain(_ error: any Error, key: String) -> String {
        var text: String
        if let error = error as? EsclopError, case let .invalidArgument(why) = error {
            text = why
        } else {
            text = (error as? EsclopError)?.description ?? String(describing: error)
        }
        if text.hasPrefix(key + " ") {
            text = String(text.dropFirst(key.count + 1))
            text = text.prefix(1).uppercased() + text.dropFirst()
        }
        return SettingWords.problem(text)

    }
}

/// Key-value observation of a defaults suite. Unlike `UserDefaults.didChangeNotification`, it
/// reports writes made by other processes (cfprefsd forwards them), such as `esclop settings set`.
final class DefaultsObserver: NSObject, @unchecked Sendable {
    // Immutable after init; KVO calls back on the thread that wrote, so the callback is Sendable.
    private let defaults: UserDefaults
    private let keys: [String]
    private let changed: @Sendable (String) -> Void

    init(defaults: UserDefaults, keys: [String], changed: @escaping @Sendable (String) -> Void) {
        self.defaults = defaults
        self.keys = keys
        self.changed = changed
        super.init()
        for key in keys { defaults.addObserver(self, forKeyPath: key, options: [.new], context: nil) }
    }

    deinit {
        for key in keys { defaults.removeObserver(self, forKeyPath: key) }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if let keyPath { changed(keyPath) }
    }
}
