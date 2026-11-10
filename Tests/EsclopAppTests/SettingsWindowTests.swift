// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Settings window's logic: every registry setting has a pane, deep links resolve to a pane
// and row, the search reaches every pane, values are checked before they are written, resets
// restore the default, and changes made outside the window (the CLI) show up in it.

import EsclopCore
import EsclopIPC
@testable import EsclopAppKit
import Foundation
import Testing

@MainActor
@Suite struct SettingsWindowTests {
    let settings = TestSettings()

    func model(onChange: @escaping (String, JSONValue) -> Void = { _, _ in }) -> SettingsViewModel {
        SettingsViewModel(
            provider: RegistrySettingsProvider(store: settings.store), defaults: settings.store.defaults,
            extraRows: SettingsPaneView.extraRows, onChange: onChange
        )
    }

    // MARK: Panes

    @Test func everySettingHasExactlyOnePane() {
        let model = model()
        var seen: [String: SettingsPane] = [:]
        for pane in SettingsPane.allCases {
            for group in model.groups(in: pane) {
                for setting in group.settings {
                    #expect(seen[setting.key] == nil, "\(setting.key) is in \(seen[setting.key]?.title ?? "") and \(pane.title)")
                    seen[setting.key] = pane
                }
            }
        }
        #expect(Set(seen.keys) == Set(SettingsRegistry.shared.keys), "every registry setting shows up in a pane")
        for section in SettingsSection.allCases {
            #expect(SettingsPane.allCases.filter { $0.sections.contains(section) }.count == 1, "\(section) belongs to one pane")
        }
    }

    @Test func panesTheBriefNames() {
        #expect(SettingsPane.allCases.map(\.title) == [
            "General", "Images", "Video", "PDF", "Audio", "Clipboard", "Floating results", "Agents and MCP", "Advanced",
        ])
        #expect(model().groups(in: .agents).flatMap(\.settings).map(\.key) == AgentPermission.allCases.map(\.rawValue))
    }

    @Test func everySettingGetsAControl() {
        for descriptor in model().descriptors {
            let control = SettingPresentation.control(for: descriptor)
            if case let .picker(choices) = control {
                #expect(!choices.isEmpty, "\(descriptor.key) has choices")
                #expect(choices.contains { SettingsViewModel.same($0.value, descriptor.defaultValue) }, "\(descriptor.key)'s default is one of its choices")
                for choice in choices {
                    #expect(!choice.label.isEmpty && choice.label.first?.isLowercase == false, "sentence case: \(descriptor.key): \(choice.label)")
                }
            }
            if descriptor.type == .bool { #expect(control == .toggle) }
        }
        let descriptors = model().descriptors
        func control(_ key: String) -> SettingControl? { descriptors.first { $0.key == key }.map(SettingPresentation.control(for:)) }
        #expect(control("imageCompression") == .slider(range: 0 ... 100, step: 1, format: .plain))
        #expect(control("imageDirs") == .folders)
        #expect(control("clipboardIgnoredAppBundleIds") == .apps)
        #expect(control("formatsToConvertToJPEG") == .extensions)
        #expect(control("maxImageSizeMB") == .number(unit: "MB", step: 1))
    }

    @Test func choicesReadAsWords() {
        #expect(SettingPresentation.label(for: "bottomRight") == "Bottom right")
        #expect(SettingPresentation.label(for: "sameFolder") == "Next to the original")
        #expect(SettingPresentation.label(for: "somethingNew") == "Something new")
        let dpi = model().descriptor("pdfDPI")!
        #expect(SettingPresentation.display(.int(0), for: dpi) == "Automatic")
        #expect(SettingPresentation.display(.double(0.5), for: model().descriptor("downscaleFactor")!) == "50 %")
    }

    // MARK: Deep links

    func route(_ link: String) -> SettingsRoute? {
        let model = model()
        return SettingsRoute(url: URL(string: link)!, paneOf: model.pane(of:))
    }

    @Test func deepLinks() {
        #expect(route("esclop://settings") == SettingsRoute())
        #expect(route("esclop://settings/images") == SettingsRoute(pane: .images))
        #expect(route("esclop://settings/Floating%20results") == SettingsRoute(pane: .floatingResults))
        #expect(route("esclop://settings/mcp") == SettingsRoute(pane: .agents))
        #expect(route("esclop://settings/interface") == SettingsRoute(pane: .floatingResults), "a registry section names its pane")
        #expect(route("esclop://settings/imageCompression") == SettingsRoute(pane: .images, row: "imageCompression"))
        #expect(route("esclop://settings/images/imageCompression") == SettingsRoute(pane: .images, row: "imageCompression"))
        #expect(route("esclop://settings/video/imageCompression") == SettingsRoute(pane: .images, row: "imageCompression"), "the row's own pane wins over a stale one")
        #expect(route("esclop://settings/agents?highlight=allowRunScripts") == SettingsRoute(pane: .agents, row: "allowRunScripts"))
        #expect(route("esclop://settings/hotkey.togglePause") == SettingsRoute(pane: .general, row: "hotkey.togglePause"))
        #expect(route("esclop://settings/sameFolderNameTemplate") == SettingsRoute(pane: .general, row: "sameFolderNameTemplate"))
        #expect(route("esclop://results/recent") == nil)
        #expect(route("https://settings/images") == nil)
    }

    @Test func everyRowHasALinkThatLeadsBack() throws {
        let model = model()
        for row in model.descriptors.map(\.key) + SettingsPaneView.extraRows.map(\.id) {
            let link = try #require(model.link(to: row))
            #expect(SettingsRoute(url: link, paneOf: model.pane(of:)) == SettingsRoute(pane: model.pane(of: row), row: row), "\(link)")
        }
        #expect(model.link(to: "allowRunScripts")?.absoluteString == "esclop://settings/agents/allowRunScripts")
    }

    @Test func refusalsLinkToTheirSwitch() throws {
        // The link in the agent refusal messages must open the right row.
        let model = model()
        for permission in AgentPermission.allCases {
            let link = try #require(URL(string: "esclop://settings/agents/\(permission.rawValue)"))
            #expect(SettingsRoute(url: link, paneOf: model.pane(of:)) == SettingsRoute(pane: .agents, row: permission.rawValue))
        }
    }

    @Test func openingALinkSelectsPaneAndRow() {
        let model = model()
        model.open(SettingsRoute(pane: .pdf, row: "pdfDPI"))
        #expect(model.pane == .pdf)
        #expect(model.highlighted == "pdfDPI")
        model.open(SettingsRoute(pane: nil, row: nil))
        #expect(model.pane == .pdf, "a bare link keeps the pane")
    }

    // MARK: Search

    @Test func searchFindsAcrossPanes() {
        let model = model()
        model.query = "aggressive"
        let panes = Set(model.hits.map(\.pane))
        #expect(panes.isSuperset(of: [.images, .video, .pdf, .audio]))
        model.query = "shortcut"
        #expect(model.hits.map(\.id).contains("hotkey.optimiseClipboard"))
        model.query = "agents overwrite"
        #expect(model.hits.map(\.id) == ["allowOverwriteOriginals"])
        model.query = "loudness LUFS"
        #expect(model.hits.map(\.id).contains("loudnessTarget"))
        model.query = "  "
        #expect(model.hits.isEmpty)
        model.query = "zzznothing"
        #expect(model.hits.isEmpty)
    }

    @Test func searchByPaneName() {
        let model = model()
        model.query = "floating results"
        #expect(model.hits.count == model.groups(in: .floatingResults).flatMap(\.settings).count)
    }

    // MARK: Writing

    @Test func validValuesAreWrittenThroughTheRegistry() throws {
        var changes: [String] = []
        let model = model { key, _ in changes.append(key) }
        #expect(model.set("imageCompression", text: "55"))
        #expect(try SettingsRegistry.shared.get("imageCompression", in: settings.store) == .int(55))
        #expect(model.value("imageCompression") == .int(55))
        #expect(model.set("floatingResultsCorner", to: .string("topLeft")))
        #expect(EsclopSettings.floatingResultsCorner.value(in: settings.store) == .topLeft)
        #expect(model.set("imageDirs", to: .array(["~/Desktop", "~/Screen, shots"])))
        #expect(EsclopSettings.imageDirs.value(in: settings.store) == ["~/Desktop", "~/Screen, shots"], "a comma inside a folder name survives")
        #expect(changes == ["imageCompression", "floatingResultsCorner", "imageDirs"])
    }

    @Test func invalidValuesAreRefusedAndExplained() {
        let model = model()
        #expect(model.problem("imageCompression", text: "101") != nil)
        #expect(model.problem("imageCompression", text: "abc") != nil)
        #expect(model.problem("imageCompression", text: "40") == nil)
        #expect(model.problem("pdfDPI", text: "120") != nil, "only the listed resolutions")
        #expect(model.problem("pdfDPI", text: "150") == nil)
        #expect(!model.set("imageCompression", text: "101"))
        #expect(model.errors["imageCompression"] == "Must be at most 100, got 101", "the row names the setting; the error does not repeat the key")
        #expect(EsclopSettings.imageCompression.value(in: settings.store) == 30, "nothing was written")
        #expect(model.set("imageCompression", text: "31"))
        #expect(model.errors["imageCompression"] == nil, "a good value clears the error")
    }

    @Test func resetRestoresTheDefault() {
        let model = model()
        #expect(!model.isModified("gifFPS"))
        model.set("gifFPS", text: "24")
        #expect(model.isModified("gifFPS"))
        model.reset("gifFPS")
        #expect(!model.isModified("gifFPS"))
        #expect(!EsclopSettings.gifFPS.isSet(in: settings.store), "the stored value is gone, so a new default would apply")
        #expect(model.value("gifFPS") == .int(15))
    }

    @Test func resetAllTurnsAgentPermissionsOff() {
        let model = model()
        model.set("allowRunScripts", to: .bool(true))
        model.set("videoCompression", text: "80")
        model.resetAll()
        #expect(!EsclopSettings.allowRunScripts.value(in: settings.store))
        #expect(EsclopSettings.videoCompression.value(in: settings.store) == 50)
        #expect(!model.descriptors.contains { model.isModified($0.key) })
    }

    @Test func dependentRowsFollowTheirSwitch() {
        let model = model()
        #expect(model.isEnabled("targetVideoFPS"))
        model.set("capVideoFPS", to: .bool(false))
        #expect(!model.isEnabled("targetVideoFPS"))
        #expect(!model.isEnabled("specificFolderTemplate"), "no kind of file goes to a specific folder by default")
        model.set("optimisedPDFBehaviour", to: .string("specificFolder"))
        #expect(model.isEnabled("specificFolderTemplate"))
        #expect(model.isEnabled("sameFolderNameTemplate"), "converted images go next to the original by default")
    }

    // MARK: Staying in sync

    @Test func changesFromTheCommandLineShowUp() async {
        let model = model()
        // What `esclop settings set` does: write the registry in the same suite, from elsewhere.
        try? SettingsRegistry.shared.set("videoCompression", text: "77", in: settings.store)
        #expect(await eventually { model.value("videoCompression") == .int(77) })
        try? SettingsRegistry.shared.reset("videoCompression", in: settings.store)
        #expect(await eventually { model.value("videoCompression") == .int(50) })
    }

    @Test func changesFromAnotherProcessShowUp() async throws {
        let suite = try #require(settings.store.suiteName)
        let model = model()
        let defaults = Process()
        defaults.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        defaults.arguments = ["write", suite, "gifFPS", "-int", "12"]
        try defaults.run()
        defaults.waitUntilExit()
        #expect(await eventually { model.value("gifFPS") == .int(12) })
    }

    @Test func shellQuoting() {
        #expect(SettingRow.shellQuoted("55") == "55")
        #expect(SettingRow.shellQuoted("%f-optimised") == "%f-optimised")
        #expect(SettingRow.shellQuoted("[\"~/My Shots\"]") == "'[\"~/My Shots\"]'")
        #expect(SettingRow.shellQuoted("it's") == "\"it's\"", "an apostrophe alone reads better in double quotes")
        #expect(SettingRow.shellQuoted("it's \"$5\"") == "'it'\\''s \"$5\"'")
    }
}
