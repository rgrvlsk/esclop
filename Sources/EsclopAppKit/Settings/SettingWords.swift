// SPDX-License-Identifier: GPL-3.0-or-later
//
// The settings in the app's language. The registry stays English at the source, because the
// CLI, the MCP server and agents read it; the app looks each setting up by key in the catalog
// (`setting.<key>.title`, `setting.<key>.summary`) and falls back to the registry's English.
// The English words stay searchable: they become keywords of the localised descriptor.

import EsclopCore
import EsclopIPC
import Foundation

enum SettingWords {
    static func titleKey(_ key: String) -> String { "setting.\(key).title" }
    static func summaryKey(_ key: String) -> String { "setting.\(key).summary" }

    /// The catalog's text for `catalogKey`, or `english` when it has none for the locale.
    static func lookup(_ catalogKey: String, english: String, locale: Locale = Strings.locale) -> String {
        let text = Strings.text(catalogKey, locale: locale)
        return text == catalogKey ? english : text
    }

    /// The descriptor with its title and summary in the app's language, the English kept as
    /// search words.
    static func localised(_ descriptor: SettingDescriptor, locale: Locale = Strings.locale) -> SettingDescriptor {
        var localised = descriptor
        localised.title = lookup(titleKey(descriptor.key), english: descriptor.title, locale: locale)
        localised.summary = lookup(summaryKey(descriptor.key), english: descriptor.summary, locale: locale)
        if localised.title != descriptor.title || localised.summary != descriptor.summary {
            localised.keywords += [descriptor.title, descriptor.summary]
        }
        return localised
    }

    /// A refused value in the app's language. The settings parser (shared with the CLI) writes
    /// "<key> takes a whole number, not x" and the like; the app rephrases the known shapes and
    /// keeps anything else as it is.
    static func problem(_ english: String) -> String {
        let patterns: [(String, String)] = [
            (#"^[Tt]akes true or false, not (.*)$"#, "Takes on or off, not %@"),
            (#"^[Tt]akes a whole number, not (.*)$"#, "Takes a whole number, not %@"),
            (#"^[Tt]akes a number, not (.*)$"#, "Takes a number, not %@"),
            (#"^[Tt]akes one of (.*), not (.*)$"#, "Takes one of %@, not %@"),
            (#"^[Mm]ust be at least (.*)$"#, "Must be at least %@"),
            (#"^[Mm]ust be at most (.*)$"#, "Must be at most %@"),
        ]
        for (pattern, key) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: english, range: NSRange(english.startIndex..., in: english)) else { continue }
            let values = (1 ..< match.numberOfRanges).compactMap { Range(match.range(at: $0), in: english).map { String(english[$0]) } }
            switch key {
            case "Takes on or off, not %@": return Strings.format("Takes on or off, not %@", values[0])
            case "Takes a whole number, not %@": return Strings.format("Takes a whole number, not %@", values[0])
            case "Takes a number, not %@": return Strings.format("Takes a number, not %@", values[0])
            case "Takes one of %@, not %@": return Strings.format("Takes one of %@, not %@", values[0], values[1])
            case "Must be at least %@": return Strings.format("Must be at least %@", values[0])
            default: return Strings.format("Must be at most %@", values[0])
            }
        }
        return english
    }
}
