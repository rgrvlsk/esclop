// SPDX-License-Identifier: GPL-3.0-or-later
//
// The app's copy. English is the base; `Localizable.xcstrings` carries the Catalan from the
// storyboards. Lookups pick the `.lproj` by locale rather than through the main bundle, so the
// menu bar app, its tests and still renders can each ask for a language: `ESCLOP_LANGUAGE=ca`
// shows Catalan whatever the system language is. SwiftPM's Swift Build backend compiles the
// catalog into `.lproj` tables; its native build system copies the catalog as it is, so when
// no table exists the lookup reads the catalog itself.

import Foundation

public enum Strings {
    /// The language the copy is written in: `ESCLOP_LANGUAGE`, else the system's.
    public static var locale: Locale {
        if let code = ProcessInfo.processInfo.environment["ESCLOP_LANGUAGE"], !code.isEmpty { return Locale(identifier: code) }
        let available = ["en"] + Bundle.module.localizations + Catalog.shared.languages
        let language = Bundle.preferredLocalizations(from: Array(Set(available)), forPreferences: Locale.preferredLanguages).first ?? "en"
        // Keep the region's number format when it speaks the same language ("ca_ES").
        if Locale.current.language.languageCode?.identifier == language { return .current }
        return Locale(identifier: language)
    }

    /// The translation of `key` (the English text) for `locale`, or the key itself.
    public static func text(_ key: String, locale: Locale = Strings.locale) -> String {
        if let bundle = bundle(for: locale) { return bundle.localizedString(forKey: key, value: key, table: nil) }
        return Catalog.shared.value(key, language: locale.language.languageCode?.identifier ?? "en") ?? key
    }

    /// `text` with `%@` / `%d` filled in.
    public static func format(_ key: String, _ arguments: any CVarArg..., locale: Locale = Strings.locale) -> String {
        String(format: text(key, locale: locale), locale: locale, arguments: arguments)
    }

    /// "Quality 82 %"
    public static func quality(_ value: Int, locale: Locale = Strings.locale) -> String {
        format("Quality %d %%", value, locale: locale).replacingOccurrences(of: " %", with: Figures.space + "%")
    }

    nonisolated(unsafe) private static var bundles: [String: Bundle] = [:]
    private static let lock = NSLock()

    private static func bundle(for locale: Locale) -> Bundle? {
        let code = locale.language.languageCode?.identifier ?? "en"
        lock.lock()
        defer { lock.unlock() }
        if let cached = bundles[code] { return cached }
        // English is the base: its text is the key, so it needs no table.
        let path = Bundle.module.path(forResource: code, ofType: "lproj")
        let bundle = path.flatMap(Bundle.init(path:))
        bundles[code] = bundle
        return bundle
    }
}

/// `Localizable.xcstrings` read directly, for builds that copy it instead of compiling it.
final class Catalog: Sendable {
    static let shared = Catalog(url: Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings"))

    /// Language, then key, then text.
    private let tables: [String: [String: String]]

    init(url: URL?) {
        var tables: [String: [String: String]] = [:]
        if let url, let data = try? Data(contentsOf: url),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let strings = root["strings"] as? [String: Any]
        {
            for (key, entry) in strings {
                let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
                for (language, localization) in localizations {
                    let unit = (localization as? [String: Any])?["stringUnit"] as? [String: Any]
                    if let value = unit?["value"] as? String { tables[language, default: [:]][key] = value }
                }
            }
        }
        self.tables = tables
    }

    var languages: [String] { Array(tables.keys) }

    func value(_ key: String, language: String) -> String? { tables[language]?[key] }
}
