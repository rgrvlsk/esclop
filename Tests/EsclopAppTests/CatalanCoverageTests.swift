// SPDX-License-Identifier: GPL-3.0-or-later
//
// Catalan everywhere: every setting, option, step and argument the app shows has a Catalan
// entry, so a new one cannot ship untranslated. The registry and the step catalog stay English
// for the CLI and agents; the app looks them up by key.

import EsclopCore
import EsclopIPC
@testable import EsclopOptimisers
import EsclopPipelines
@testable import EsclopAppKit
import Foundation
import Testing

@MainActor @Suite struct CatalanCoverageTests {
    let ca = Locale(identifier: "ca_ES")

    /// The catalog's Catalan, read from the file the app ships.
    nonisolated static let catalan: [String: String] = {
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

    /// Refusals the engine words for agents and logs reach a card in the person's language.
    @Test func engineRefusalsOnACardHaveCatalan() {
        let overwrite = CardPresentation.message(for: EsclopError.notPermitted(ResultWriter.agentOverwriteMessage))
        #expect(Self.catalan[overwrite] != nil, "\(overwrite)")
        #expect(CardPresentation.message(for: EsclopError.notPermitted("Brief.pdf is password protected")) == "Brief.pdf is password protected.")
        #expect(Self.catalan["%@ is password protected."] != nil)
        let restore = CardPresentation.message(for: EsclopError.invalidArgument("No recent result for /tmp/a.png. esclop_recent_results lists what can be restored"))
        #expect(restore == "There is no recent result for a.png to restore.")
        #expect(Self.catalan["There is no recent result for %@ to restore."] != nil)
        #expect(Self.catalan[CardPresentation.message(for: EsclopError.alreadySmaller)] != nil)
    }

    /// A fit that found nothing says both sizes on a card, in the person's language; the CLI and
    /// agents keep the message, code and exit code they had as a plain message.
    @Test func fitFailuresOnACardHaveCatalan() {
        let missed = EsclopError.cannotFit(underBytes: 1_000_000, smallest: 1_400_000)
        #expect(CardPresentation.message(for: missed) == "Could not fit under 1\u{00A0}MB. The smallest attempt was 1.4\u{00A0}MB.")
        // ByteCountFormatter, in the Mac's own format, as before the case existed.
        #expect(missed.description.hasPrefix("Could not fit under 1") && missed.description.contains("; the smallest attempt was 1"))
        #expect(EsclopError.cannotFit(underBytes: 1_000_000, smallest: nil).description.hasSuffix("the smallest attempt was nothing smaller than the original"))
        #expect(missed.code == "other")
        let lossless = EsclopError.losslessCannotFit(format: "FLAC")
        #expect(lossless.description == "FLAC is lossless and cannot be fitted to a size")
        #expect(lossless.code == "invalidArgument")
        for key in ["Could not fit under %@. The smallest attempt was %@.", "Could not fit under %@. No attempt came out smaller than the original.",
                    "%@ is lossless, so it cannot be fitted to a size.", "Fit dropped"] {
            #expect(Self.catalan[key] != nil, "\(key)")
        }
        #expect(Strings.format("Could not fit under %@. The smallest attempt was %@.", "1 MB", "1,4 MB", locale: ca) == "No s’ha pogut deixar per sota de 1 MB. L’intent més petit feia 1,4 MB.")
    }

    /// A built-in template's name is shown translated (preset zones); the name the CLI runs stays.
    @Test func everyBuiltInTemplateNameHasCatalan() {
        for preset in PipelineStore.presets {
            #expect(Self.catalan[preset.name] != nil, "no Catalan for the template “\(preset.name)”")
        }
    }

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
        for status in ["Watching the clipboard", "Watching 1 folder", "Optimising 1 file", "Testing…", "Uploading…", "Uploading… %d %%"] {
            #expect(Self.catalan[status]?.hasPrefix("S’està") == true, "\(status)")
        }
    }

    /// One word for each thing (council round 4, D3): the Trash is «la Paperera», Custom is
    /// «A mida», Skip is «Omet», Fit under is «Per sota de»; no «…de les quals» relative clauses.
    /// English shows the typographic apostrophe, except in engine messages matched as written.
    @Test func oneCatalanWordForEachThing() {
        #expect(!Self.catalan.values.contains { $0.contains("paperera") }, "the Trash is «la Paperera»")
        #expect(!Self.catalan.values.contains { $0.contains("de les quals") })
        #expect(Self.catalan["Fit under"] == "Per sota de")
        #expect(Self.catalan["Custom"] == "A mida" && Self.catalan["Custom…"] == "A mida…")
        #expect(Self.catalan["Skip"] == "Omet" && Self.catalan["Skip if"] == "Omet si")
        #expect(Self.catalan["Working"] == "En curs")
        #expect(Self.catalan["Run a Shortcut"] == "Executa una drecera")
        let straight = Self.catalan.keys.filter { $0.contains("'") && !$0.hasPrefix("L'Esclop") }
        #expect(Set(straight) == [
            "This script uses Clop's variables. In esclop they are `$ESCLOP_BIN` and `$ESCLOP_INPUT_FILE`.",
            "running scripts is turned off; allow it in esclop's settings",
        ], "only the engine's own messages keep a straight apostrophe")
    }

    @Test func theMenuAndTheTourSpeakCatalan() {
        #expect(Strings.text("Watching the clipboard", locale: ca) == "S’està vigilant el porta-retalls")
        #expect(Strings.text("Settings…", locale: ca) == "Configuració…")
        #expect(Strings.text("What macOS will ask", locale: ca) == "Què et preguntarà el macOS")
        #expect(Strings.text("What happens on its own", locale: ca) == "Què es fa automàticament")
        #expect(Strings.text("Agents and MCP", locale: ca) == "Agents i MCP")
    }
}
