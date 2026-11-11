// SPDX-License-Identifier: GPL-3.0-or-later
//
// Catalan everywhere: every setting, option, step and argument the app shows has a Catalan
// entry, so a new one cannot ship untranslated. The registry and the step catalog stay English
// for the CLI and agents; the app looks them up by key.

import EsclopCore
import EsclopIPC
import EsclopPipelines
@testable import EsclopAppKit
import Foundation
import Testing

@MainActor @Suite struct CatalanCoverageTests {
    let ca = Locale(identifier: "ca_ES")

    /// The catalog's Catalan, read from the file the app ships.
    static let catalan: [String: String] = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/EsclopAppKit/Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = json["strings"] as? [String: [String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for (key, entry) in strings {
            if let ca = (entry["localizations"] as? [String: Any])?["ca"] as? [String: Any],
               let value = (ca["stringUnit"] as? [String: Any])?["value"] as? String { out[key] = value }
        }
        return out
    }()

    /// Why the engine leaves a PDF as it is (engine/.../pdf/reasons.rs): shown as the message.
    @Test func everyEngineReasonHasCatalanAndIsTheMessage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("engine/crates/esclop-engine/src/pdf/reasons.rs"), encoding: .utf8)
        let reasons = source.split(separator: "\n").filter { $0.hasPrefix("pub const") }.compactMap { line -> String? in
            guard let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close else { return nil }
            return String(line[line.index(after: open) ..< close])
        }
        #expect(reasons.count >= 6)
        for reason in reasons {
            #expect(Self.catalan[reason] != nil, "no Catalan for \(reason)")
            #expect(CardPresentation.message(for: EsclopError.leftAsIs(reason)) == reason, "the English card says the reason")
            #expect(EsclopError.leftAsIs(reason).description == reason, "the CLI and MCP say the reason")
            #expect(EsclopError.leftAsIs(reason).code == "unsupportedFile")
        }
        #expect(Strings.text("Signed PDFs are left as they are, so their signatures stay valid.", locale: ca)
            == "Els PDF signats es deixen tal com estan, perquè les signatures continuïn sent vàlides.")
    }

    @Test func everySettingHasACatalanTitleAndDescription() {
        let descriptors = RegistrySettingsProvider(store: TestSettings().store).descriptors()
        #expect(descriptors.count > 80)
        let missing = descriptors.flatMap { [SettingWords.titleKey($0.key), SettingWords.summaryKey($0.key)] }.filter { Self.catalan[$0] == nil }
        #expect(missing.isEmpty, "untranslated settings: \(missing)")
    }

    @Test func everyOptionAndUnitHasCatalan() {
        var words = Array(SettingPresentation.choiceLabels.values) + SettingPresentation.numberChoices.values.flatMap { $0.map(\.1) }
        words += SettingPresentation.units.values.filter { $0.count > 3 && $0 == $0.lowercased() } + ["A quarter of the source", "Half the source", "on", "off", "none"]
        let missing = words.filter { Self.catalan[$0] == nil }
        #expect(missing.isEmpty, "untranslated options: \(missing)")
    }

    @Test func everyStepAndArgumentHasCatalanWords() {
        var missing: [String] = []
        for spec in PipelineLanguage.steps {
            if Self.catalan["step.\(spec.name).summary"] == nil { missing.append("step.\(spec.name).summary") }
            if PipelineVocabulary.stepTitle(spec.name) == spec.name { missing.append("title of \(spec.name)") }
            for param in spec.params {
                let key = PipelineVocabulary.paramHelpKey(step: spec.name, param: param.name)
                if Self.catalan[key] == nil { missing.append(key) }
                if PipelineVocabulary.paramTitle(param.name) == param.name { missing.append("title of \(param.name)") }
            }
        }
        #expect(missing.isEmpty, "untranslated steps: \(missing)")
    }

    @Test func settingsReadInCatalanAndFallBackToEnglish() throws {
        let descriptor = try #require(RegistrySettingsProvider(store: TestSettings().store).descriptors().first { $0.key == "imageDirs" })
        let catalan = SettingWords.localised(descriptor, locale: ca)
        #expect(catalan.title == "Carpetes de captures de pantalla")
        #expect(catalan.summary.hasPrefix("Les imatges noves"))
        #expect(catalan.keywords.contains("Screenshot folders"), "the English stays searchable")
        let english = SettingWords.localised(descriptor, locale: Locale(identifier: "en"))
        #expect(english.title == descriptor.title && english.summary == descriptor.summary)
        #expect(SettingWords.lookup("setting.notAKey.title", english: "Fallback", locale: ca) == "Fallback")
    }

    @Test func settingsSearchFindsCatalanAndEnglishWords() {
        let settings = TestSettings()
        let model = SettingsViewModel(provider: RegistrySettingsProvider(store: settings.store), extraRows: SettingsPaneView.extraRows)
        model.locale = ca
        model.reload()
        model.query = "captures de pantalla"
        #expect(model.hits.contains { $0.id == "imageDirs" }, "Catalan words")
        model.query = "screenshot folders"
        #expect(model.hits.contains { $0.id == "imageDirs" }, "English words")
        model.query = "imatges copiades"
        #expect(model.hits.contains { $0.id == "enableClipboardOptimiser" })
        model.query = "images"
        #expect(model.hits.contains { $0.id == "imageCompression" }, "the English pane name")
    }

    @Test func refusedValuesAreRephrasedWithoutTouchingTheCLI() {
        #expect(SettingWords.problem("Takes a whole number, not abc") == "Takes a whole number, not abc")
        #expect(SettingWords.problem("Must be at most 100") == "Must be at most 100")
        #expect(SettingWords.problem("Something else entirely") == "Something else entirely")
        #expect(String(format: Strings.text("Must be at most %@", locale: ca), "100") == "Ha de ser com a màxim 100")
    }

    /// Descriptions do not open on a bare unit that reads as another word («Segons que…» reads
    /// as "according to", «Dies que…» as "you say that"), and status lines use Apple's «S’està…».
    @Test func catalanWordingAvoidsMisleadingOpenings() {
        let summaries = Self.catalan.filter { $0.key.hasPrefix("setting.") && $0.key.hasSuffix(".summary") }
        let misleading = summaries.filter { ["Segons que", "Dies que", "Mida que", "Com de fort"].contains(where: $0.value.hasPrefix) }
        #expect(misleading.isEmpty, "\(misleading.keys.sorted())")
        for status in ["Watching the clipboard", "Watching 1 folder", "Optimising 1 file", "Testing…"] {
            #expect(Self.catalan[status]?.hasPrefix("S’està") == true, "\(status)")
        }
    }

    @Test func theMenuAndTheTourSpeakCatalan() {
        #expect(Strings.text("Watching the clipboard", locale: ca) == "S’està vigilant el porta-retalls")
        #expect(Strings.text("Settings…", locale: ca) == "Configuració…")
        #expect(Strings.text("What macOS will ask", locale: ca) == "Què et preguntarà el macOS")
        #expect(Strings.text("What happens on its own", locale: ca) == "Què es fa automàticament")
        #expect(Strings.text("Agents and MCP", locale: ca) == "Agents i MCP")
    }
}
