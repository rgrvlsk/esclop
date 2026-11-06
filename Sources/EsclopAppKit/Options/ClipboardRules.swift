// SPDX-License-Identifier: GPL-3.0-or-later
//
// Clipboard rules: "Always apply to PNG screenshots" in the options popover turns the current
// choice into a rule keyed by origin and input format (DESIGN.md › Origin rules). They live in
// the settings registry (`clipboardRules`, one JSON object per rule), so the CLI sees them too.
// Unticking deletes the rule; the next copy of that kind gets the default behaviour again.

import EsclopCore
import Foundation
import UniformTypeIdentifiers

public struct ClipboardRule: Codable, Hashable, Identifiable, Sendable {
    public var origin: FileOrigin
    /// The input's UTType identifier ("public.png").
    public var inputType: String
    public var choice: OptimiseChoice

    public init(origin: FileOrigin, inputType: String, choice: OptimiseChoice) {
        self.origin = origin
        self.inputType = inputType
        self.choice = choice
    }

    public var id: String { "\(origin.rawValue)|\(inputType)" }

    var inputFormat: OutputFormat? { OutputFormat.of(type: inputType) }

    /// "PNG screenshots", "HEIC photos from Photos", "MOV screen recordings".
    public func subject(locale: Locale = Strings.locale) -> String {
        Self.phrase(.subject, origin: origin, inputType: inputType, locale: locale)
    }

    /// "Rule: PNG screenshots → WebP · Adaptive"
    public func tooltip(locale: Locale = Strings.locale) -> String {
        Strings.format("Rule: %@ → %@", subject(locale: locale), choice.summary(input: inputFormat, locale: locale), locale: locale)
    }

    /// "Next PNG screenshots will become WebP · Adaptive"
    public func promise(locale: Locale = Strings.locale) -> String {
        Self.phrase(.promise, origin: origin, inputType: inputType, summary: choice.summary(input: inputFormat, locale: locale), locale: locale)
    }

    /// "Always apply to PNG screenshots"
    public static func checkboxTitle(origin: FileOrigin, inputType: String, locale: Locale = Strings.locale) -> String {
        phrase(.checkbox, origin: origin, inputType: inputType, locale: locale)
    }

    enum Phrase { case subject, checkbox, promise }

    /// Whole phrases per origin: languages like Catalan change the article with the noun.
    static func phrase(_ phrase: Phrase, origin: FileOrigin, inputType: String, summary: String = "", locale: Locale) -> String {
        let format = OutputFormat.of(type: inputType)?.displayName
            ?? UTType(inputType)?.preferredFilenameExtension?.uppercased() ?? inputType
        let noun: String
        switch origin {
        case .screenshot: noun = "screenshots"
        case .photos: noun = "photos from Photos"
        case .browser: noun = "images from browsers"
        case .graphic: noun = "graphics with transparency"
        case .animatedGIF: noun = "animated GIFs"
        case .screenRecording: noun = "screen recordings"
        case .pdfExport: noun = "exported documents"
        case .voiceMemo: noun = "voice memos"
        case .unknown: noun = "copied files"
        }
        switch phrase {
        case .subject: return Strings.format("%@ \(noun)", format, locale: locale)
        case .checkbox: return Strings.format("Always apply to %@ \(noun)", format, locale: locale)
        case .promise: return Strings.format("Next %@ \(noun) will become %@", format, summary, locale: locale)
        }
    }
}

/// Reads and writes the rules in the settings registry.
public struct ClipboardRules: Sendable {
    public var settings: SettingsStore

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    public var all: [ClipboardRule] {
        EsclopSettings.clipboardRules.value(in: settings).compactMap { text in
            try? JSONDecoder().decode(ClipboardRule.self, from: Data(text.utf8))
        }
    }

    public func rule(origin: FileOrigin, inputType: String) -> ClipboardRule? {
        all.first { $0.origin == origin && $0.inputType == inputType }
    }

    /// Adds the rule, replacing one with the same origin and input format.
    public func save(_ rule: ClipboardRule) throws {
        var rules = all.filter { $0.id != rule.id }
        rules.append(rule)
        try write(rules)
    }

    public func delete(origin: FileOrigin, inputType: String) throws {
        try write(all.filter { !($0.origin == origin && $0.inputType == inputType) })
    }

    private func write(_ rules: [ClipboardRule]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let texts = try rules.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try EsclopSettings.clipboardRules.set(texts, in: settings)
    }
}

/// What a card knows about its file before the job runs: origin, input format, the choice that
/// will be used and the rule that picked it.
public struct CardContext: Equatable, Sendable {
    public var origin: FileOrigin
    public var inputType: String?
    public var choice: OptimiseChoice
    public var rule: ClipboardRule?

    public init(origin: FileOrigin, inputType: String?, choice: OptimiseChoice = .standard, rule: ClipboardRule? = nil) {
        self.origin = origin
        self.inputType = inputType
        self.choice = choice
        self.rule = rule
    }
}
