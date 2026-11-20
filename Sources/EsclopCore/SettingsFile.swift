// SPDX-License-Identifier: GPL-3.0-or-later
//
// The settings file: `esclop settings export|import` and Settings › General › Export… and
// Import…, to carry the settings the person changed to another Mac (iCloud sync waits for 0.3).
// It holds only the keys stored in the suite, so the other Mac keeps its own defaults for the
// rest. Import checks every value against its setting before it writes any, and skips the keys
// this version does not know (a newer L'Esclop wrote the file), naming them.

import Foundation

public enum SettingsFile {
    public static let format = "esclop-settings"
    public static let version = 1

    struct Contents: Codable {
        var format: String
        var version: Int
        var settings: [String: JSONValue]
    }

    /// What a file holds: the values this version knows, checked, and the keys it does not.
    public struct Read: Equatable, Sendable {
        public var values: [String: JSONValue]
        public var unknown: [String]
    }

    /// The settings set in `store`, as the file's JSON.
    public static func export(from store: SettingsStore, registry: SettingsRegistry = .shared) throws -> Data {
        let settings = Dictionary(uniqueKeysWithValues: registry.all.filter { $0.isSet(in: store) }.map { ($0.key, $0.get(in: store)) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Contents(format: format, version: version, settings: settings))
    }

    /// Reads and checks a file; nothing is written. Throws `invalidArgument` naming the problem.
    public static func read(_ data: Data, registry: SettingsRegistry = .shared) throws -> Read {
        let contents: Contents
        do {
            contents = try JSONDecoder().decode(Contents.self, from: data)
        } catch {
            throw EsclopError.invalidArgument("This is not an L’Esclop settings file: it needs \"format\", \"version\" and \"settings\".")
        }
        guard contents.format == format else {
            throw EsclopError.invalidArgument("This is not an L’Esclop settings file: its format is \(contents.format), not \(format).")
        }
        var read = Read(values: [:], unknown: [])
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
        }
        read.unknown.sort()
        return read
    }

    /// Reads a file and applies its values to `store`, all or none.
    @discardableResult
    public static func `import`(_ data: Data, into store: SettingsStore, registry: SettingsRegistry = .shared) throws -> Read {
        let read = try read(data, registry: registry)
        try registry.apply(read.values, in: store)
        return read
    }
}
