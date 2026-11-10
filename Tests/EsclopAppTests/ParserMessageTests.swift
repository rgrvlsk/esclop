// SPDX-License-Identifier: GPL-3.0-or-later
//
// The parser's messages in the editor's language. The parser builds each message from a
// template (`T("…")`) and keeps printing the English for the CLI; the editor looks the
// template, and the phrases nested in it, up in the catalog.

import EsclopPipelines
@testable import EsclopAppKit
import Foundation
import Testing

@Suite struct ParserMessageTests {
    let ca = Locale(identifier: "ca_ES")

    static let broken = [
        "-> optimise", "optimise -> -> convert(to: webp)", "[imgae]\noptimise", "optimise convert(to: webp)", "optimise)",
        "---\ntrigers: clipboard\n---\noptimise", "---\noptimiseFirst: maybe\n---\noptimise", "convert(to: webp", "optimze",
        "convert(to: webp, too: 1)", "convert", "crop", "runScript", "if", "lowerBitrate(kbps: 2)", "downscale(factor: 50%)",
        "downscale(factor: 2)", "convert(to: webpp)", "targetSize(size: big)", "optimise(location: inPlase)", "copy(to: ~/a/%f)",
        "crop(longEdge: -5)", "rename(to: \"abc)", "---\ntriggers: clipbaord\n---\noptimise",
    ]

    /// Every template the parser can use, from its sources.
    static func templates() throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("Sources/EsclopPipelines")
        let pattern = try NSRegularExpression(pattern: #"\b(?:T|mustBe)\("((?:[^"\\]|\\.)*)""#)
        var found = Set<String>()
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                found.insert(text[range].replacingOccurrences(of: #"\""#, with: "\""))
            }
        }
        return found
    }

    @Test func everyTemplateHasCatalan() throws {
        let templates = try Self.templates()
        #expect(templates.count > 70, "the scan found the parser's templates")
        let missing = templates.filter { CatalanCoverageTests.catalan[$0] == nil }.sorted()
        #expect(missing.isEmpty, "untranslated parser messages: \(missing)")
    }

    @Test func theCLIKeepsItsEnglishAndTheEditorGetsATemplate() throws {
        let templates = try Self.templates()
        var seen = 0
        for text in Self.broken {
            for diagnostic in PipelineParser.check(text).diagnostics {
                seen += 1
                let structured = try #require(diagnostic.text, "\(text): \(diagnostic.message)")
                #expect(structured.english == diagnostic.message, "the CLI prints the same text")
                #expect(structured.templates.allSatisfy(templates.contains), "\(structured.templates)")
                let catalan = PipelineVocabulary.message(diagnostic, locale: ca)
                #expect(!catalan.contains("%@"))
                #expect(catalan != diagnostic.message || structured.template.hasPrefix("`%@` must be `true`"), "\(text): \(catalan)")
            }
        }
        #expect(seen >= Self.broken.count)
    }

    @Test func nestedPhrasesAreTranslatedToo() throws {
        let diagnostic = try #require(PipelineParser.check("lowerBitrate(kbps: 2)").errors.first)
        #expect(diagnostic.message == "`kbps` must be a whole number from 8 to 1024; `2` is too small.")
        #expect(PipelineVocabulary.message(diagnostic, locale: ca) == "`kbps` ha de ser un nombre enter de 8 a 1024; `2` és massa petit.")
        let unknown = try #require(PipelineParser.check("optimze").errors.first)
        #expect(PipelineVocabulary.message(unknown, locale: ca) == "Pas desconegut: `optimze`. Volies dir `optimise`?")
        #expect(PipelineVocabulary.message(unknown, locale: Locale(identifier: "en")) == unknown.message)
    }

    @Test func diagnosticsStillDecodeWithoutText() throws {
        let json = #"{"severity":"error","line":1,"column":2,"length":3,"message":"old"}"#
        let diagnostic = try JSONDecoder().decode(PipelineDiagnostic.self, from: Data(json.utf8))
        #expect(diagnostic.text == nil && diagnostic.message == "old")
        #expect(PipelineVocabulary.message(diagnostic, locale: ca) == "old")
    }
}
