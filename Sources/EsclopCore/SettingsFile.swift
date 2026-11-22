// SPDX-License-Identifier: GPL-3.0-or-later
//
// The settings file: `esclop settings export|import` and Settings › General › Export… and
// Import…, to carry the settings the person changed to another Mac (iCloud sync waits for 0.3).
// It holds only the keys stored in the suite, so the other Mac keeps its own defaults for the
// rest. Import checks every value against its setting before it writes any, and skips the keys
// this version does not know (a newer L'Esclop wrote the file), naming them. A file that turns on
// a permission (Settings › Agents, or where and when files are uploaded) does so only when the
// person says so: a shared file must not quietly let agents run scripts, point a known upload
// target at another endpoint (its Keychain keys go by its name) or upload on its own.

import Foundation

public enum SettingsFile {
    public static let format = "esclop-settings"
    public static let version = 1
    /// What only the person may turn on: the agent permissions, and the upload settings (the
    /// targets, the default one and automatic uploads go together).
    public static func isPermission(_ setting: AnySetting) -> Bool {
        setting.section == .agents || setting.section == .uploads
    }
    /// What the file does not carry, said where it is exported.
    public static let leftBehind = "Pipelines, hotkeys and upload keys are not in the file: they stay on this Mac."

    struct Contents: Codable {
        var format: String
        var version: Int
        var settings: [String: JSONValue]
    }

    /// What a file holds: the values this version knows, checked, and the keys it does not.
    public struct Read: Equatable, Sendable {
        public var values: [String: JSONValue]
        public var unknown: [String]
        /// The permissions the file turns on (`permissionKeys`, set to other than the store's
        /// value and the default), by key. After an import without `allowPermissions` they are
        /// not in `values`: they were skipped.
        public var permissions: [String]
        /// The file's version; above `SettingsFile.version` a newer L'Esclop wrote it.
        public var version: Int

        public var isNewer: Bool { version > SettingsFile.version }

        public init(values: [String: JSONValue] = [:], unknown: [String] = [], permissions: [String] = [], version: Int = SettingsFile.version) {
            self.values = values
            self.unknown = unknown
            self.permissions = permissions
            self.version = version
        }
    }

    /// The settings set in `store`, as the file's JSON.
    public static func export(from store: SettingsStore, registry: SettingsRegistry = .shared) throws -> Data {
        let settings = Dictionary(uniqueKeysWithValues: registry.all.filter { $0.isSet(in: store) }.map { ($0.key, $0.get(in: store)) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Contents(format: format, version: version, settings: settings))
    }

    /// Reads and checks a file; nothing is written. Throws `invalidArgument` naming the problem.
    /// `store` is where it would go, for `Read.permissions`.
    public static func read(_ data: Data, for store: SettingsStore? = nil, registry: SettingsRegistry = .shared) throws -> Read {
        let contents: Contents
        do {
            contents = try JSONDecoder().decode(Contents.self, from: data)
        } catch {
            throw EsclopError.invalidArgument("This is not an L’Esclop settings file: it needs \"format\", \"version\" and \"settings\".")
        }
        guard contents.format == format else {
            throw EsclopError.invalidArgument("This is not an L’Esclop settings file: its format is \(contents.format), not \(format).")
        }
        var read = Read(version: contents.version)
        for (key, value) in contents.settings {
            guard let setting = registry.setting(key) else {
                read.unknown.append(key)
                continue
            }
            do {
                try setting.validate(value)
            } catch {
                throw EsclopError.invalidArgument("\(key) in the file is not a value it takes (\((error as? EsclopError)?.description ?? error.localizedDescription)). Nothing was changed.")
            }
            read.values[key] = value
            // Back to the default (off, no targets) is never a question; but `uploadTarget`'s
            // default "" picks the first target, so it is.
            let turnsOff = value == setting.defaultJSON && setting.key != EsclopSettings.uploadTarget.key
            if isPermission(setting), let store, !turnsOff, value != setting.get(in: store) {
                read.permissions.append(key)
            }
        }
        read.unknown.sort()
        read.permissions.sort()
        return read
    }

    /// Reads a file and applies its values to `store`, all or none. The permissions it turns on
    /// are applied only with `allowPermissions`; without, they are skipped and named.
    @discardableResult
    public static func `import`(_ data: Data, into store: SettingsStore, allowPermissions: Bool = false, registry: SettingsRegistry = .shared) throws -> Read {
        var read = try read(data, for: store, registry: registry)
        if !allowPermissions { read.permissions.forEach { read.values[$0] = nil } }
        try registry.apply(read.values, in: store)
        return read
    }
}
