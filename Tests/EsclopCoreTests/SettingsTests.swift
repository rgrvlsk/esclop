// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import EsclopCore

/// A throwaway UserDefaults suite per test, named as the app's own is. The first one of a run
/// removes the files earlier runs' suites left in ~/Library/Preferences.
func scratchStore() -> SettingsStore {
    _ = sweptEarlierRuns
    return SettingsStore(suiteName: "dev.esclop.tests.\(UUID().uuidString)")
}

private let sweptEarlierRuns = SettingsStore.removeEarlierSuites(prefix: "dev.esclop.tests.")

/// Sees changes to one key through key-value observation.
final class KeyWatcher: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var changes: Int { lock.withLock { count } }
    override func observeValue(forKeyPath _: String?, of _: Any?, change _: [NSKeyValueChangeKey: Any]?, context _: UnsafeMutableRawPointer?) {
        lock.withLock { count += 1 }
    }
}

@Suite struct SettingsTests {
    /// With ESCLOP_SUPPORT_DIR set, a scripted or test run has settings of its own, apart from
    /// the person's: a named suite for that folder. Not a plist in the folder: a suite at a path
    /// lost writes on CI runners, a setting read back with its earlier value.
    @Test func theSupportFolderHasSettingsOfItsOwn() async throws {
        #expect(Paths.defaultsSuite(environment: [:]) == "dev.esclop.app")
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = Paths.defaultsSuite(environment: ["ESCLOP_SUPPORT_DIR": folder.path])
        #expect(suite.hasPrefix("dev.esclop.support."), "a named suite, not a path: \(suite)")
        #expect(Paths.defaultsSuite(environment: ["ESCLOP_SUPPORT_DIR": folder.path + "/"]) == suite, "one folder, one suite")
        #expect(Paths.defaultsSuite(environment: ["ESCLOP_SUPPORT_DIR": folder.path + "-other"]) != suite)
        // A folder the first command makes keeps its suite, also behind a symlink.
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("real"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.appendingPathComponent("real"))
        let later = ["ESCLOP_SUPPORT_DIR": link.appendingPathComponent("run").path]
        let before = Paths.defaultsSuite(environment: later)
        try FileManager.default.createDirectory(at: link.appendingPathComponent("run"), withIntermediateDirectories: true)
        #expect(Paths.defaultsSuite(environment: later) == before)
        // And spelled with /private, as `pwd -P` gives it.
        let real = "/private" + folder.resolvingSymlinksInPath().appendingPathComponent("again").path
        let first = Paths.defaultsSuite(environment: ["ESCLOP_SUPPORT_DIR": real])
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        #expect(Paths.defaultsSuite(environment: ["ESCLOP_SUPPORT_DIR": real]) == first)

        let store = SettingsStore(suiteName: suite)
        defer {
            store.removeAll()
            try? FileManager.default.removeItem(at: SettingsStore.preferences.appendingPathComponent("\(suite).plist"))
        }
        // What the CLI and the app do: write through one store, read and follow through another.
        let other = SettingsStore(suiteName: suite)
        let watcher = KeyWatcher()
        other.defaults.addObserver(watcher, forKeyPath: EsclopSettings.convertedImageBehaviour.key, context: nil)
        defer { other.defaults.removeObserver(watcher, forKeyPath: EsclopSettings.convertedImageBehaviour.key) }
        try EsclopSettings.convertedImageBehaviour.set(.temporary, in: store)
        try EsclopSettings.convertedImageBehaviour.set(.inPlace, in: store)
        #expect(EsclopSettings.convertedImageBehaviour.value(in: store) == .inPlace)
        #expect(EsclopSettings.convertedImageBehaviour.value(in: other) == .inPlace)
        for _ in 0 ..< 100 where watcher.changes < 2 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(watcher.changes >= 2, "the other store saw both changes")
        EsclopSettings.convertedImageBehaviour.reset(in: store)
        #expect(!EsclopSettings.convertedImageBehaviour.isSet(in: other))
    }

    /// Earlier runs' files go, an hour after they were last written; nothing else does.
    @Test func earlierTestSuitesAreSwept() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let prefix = "dev.esclop.sweep-test-\(UUID().uuidString.prefix(8))."
        func file(_ name: String, hoursOld: Double) throws {
            let url = folder.appendingPathComponent(name)
            try Data().write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -hoursOld * 3600)], ofItemAtPath: url.path)
        }
        try file("\(prefix)A.plist", hoursOld: 30)
        try file("\(prefix)B.plist", hoursOld: 2)
        try file("\(prefix)fresh.plist", hoursOld: 0.1)
        try file("\(prefix)A.txt", hoursOld: 30)
        try file("\(prefix.dropLast()).plist", hoursOld: 30)
        try file("dev.esclop.app.plist", hoursOld: 30)
        try file("other.\(prefix)A.plist", hoursOld: 30)
        #expect(SettingsStore.removeEarlierSuites(prefix: prefix, in: folder) == 2)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(left == ["\(prefix)A.txt", "\(prefix)fresh.plist", "\(prefix.dropLast()).plist", "dev.esclop.app.plist", "other.\(prefix)A.plist"].sorted())
    }

    @Test func defaultsWhenNothingIsStored() {
        let store = scratchStore()
        defer { store.removeAll() }
        #expect(EsclopSettings.stripMetadata.value(in: store) == true)
        #expect(EsclopSettings.imageCompression.value(in: store) == 30)
        #expect(EsclopSettings.downscaleFactor.value(in: store) == 0.5)
        #expect(EsclopSettings.formatsToConvertToJPEG.value(in: store) == ["webp", "avif", "heic", "bmp"])
        #expect(EsclopSettings.audioCoverArt.value(in: store) == .optimise)
        #expect(EsclopSettings.allowOverwriteOriginals.value(in: store) == false)
    }

    @Test func everyValueTypeRoundTrips() throws {
        let store = scratchStore()
        defer { store.removeAll() }
        try EsclopSettings.stripMetadata.set(false, in: store)
        try EsclopSettings.imageCompression.set(72, in: store)
        try EsclopSettings.loudnessTarget.set(-14.5, in: store)
        try EsclopSettings.sameFolderNameTemplate.set("%f-small", in: store)
        try EsclopSettings.imageDirs.set(["~/Pictures", "~/Desktop/Shots"], in: store)
        try EsclopSettings.videoEncoder.set(.hevcVideoToolbox, in: store)
        try EsclopSettings.playbackSpeedFrames.set(.dropFrames, in: store)

        // A second store on the same suite sees the same values (the CLI and the app share them).
        let again = SettingsStore(suiteName: store.suiteName!)
        #expect(EsclopSettings.stripMetadata.value(in: again) == false)
        #expect(EsclopSettings.imageCompression.value(in: again) == 72)
        #expect(EsclopSettings.loudnessTarget.value(in: again) == -14.5)
        #expect(EsclopSettings.sameFolderNameTemplate.value(in: again) == "%f-small")
        #expect(EsclopSettings.imageDirs.value(in: again) == ["~/Pictures", "~/Desktop/Shots"])
        #expect(EsclopSettings.videoEncoder.value(in: again) == .hevcVideoToolbox)
        #expect(EsclopSettings.playbackSpeedFrames.value(in: again) == .dropFrames)
        // Enums are stored as their raw string so other tools can read the plist.
        #expect(again.defaults.string(forKey: "videoEncoder") == "hevc_videotoolbox")

        EsclopSettings.imageCompression.reset(in: store)
        #expect(EsclopSettings.imageCompression.value(in: store) == 30)
    }

    @Test func registryGetsAndSetsByKey() throws {
        let store = scratchStore()
        defer { store.removeAll() }
        let registry = SettingsRegistry.shared
        try registry.set("imageCompression", to: .int(55), in: store)
        #expect(try registry.get("imageCompression", in: store) == .int(55))
        try registry.set("formatsToConvertToPNG", text: "tiff, bmp", in: store)
        #expect(try registry.get("formatsToConvertToPNG", in: store) == .array(["tiff", "bmp"]))
        try registry.set("stripMetadata", text: "off", in: store)
        #expect(try registry.get("stripMetadata", in: store) == .bool(false))
        try registry.set("targetVideoFPS", text: "30", in: store)
        #expect(try registry.get("targetVideoFPS", in: store) == .double(30))
        try registry.set("audioCoverArt", text: "remove", in: store)
        #expect(EsclopSettings.audioCoverArt.value(in: store) == .remove)
        try registry.reset("audioCoverArt", in: store)
        #expect(EsclopSettings.audioCoverArt.value(in: store) == .optimise)
        #expect(registry.snapshot(in: store).count == registry.all.count)
    }

    @Test func invalidValuesAreRejected() throws {
        let store = scratchStore()
        defer { store.removeAll() }
        let registry = SettingsRegistry.shared
        #expect(throws: EsclopError.self) { try registry.set("imageCompression", to: .int(101), in: store) }
        #expect(throws: EsclopError.self) { try registry.set("imageCompression", to: .string("high"), in: store) }
        #expect(throws: EsclopError.self) { try registry.set("pdfDPI", to: .int(123), in: store) }
        #expect(throws: EsclopError.self) { try registry.set("videoEncoder", to: .string("libfoo"), in: store) }
        #expect(throws: EsclopError.self) { try registry.set("noSuchSetting", to: .bool(true), in: store) }
        try registry.set("pdfDPI", to: .int(150), in: store)
        #expect(EsclopSettings.pdfDPI.value(in: store) == 150)

        // `apply` writes nothing when one value is bad.
        #expect(throws: EsclopError.self) {
            try registry.apply(["imageCompression": .int(40), "videoCompression": .int(500)], in: store)
        }
        #expect(EsclopSettings.imageCompression.value(in: store) == 30)
    }

    @Test func schemaIsValidJSONAndDescribesEverySetting() throws {
        let schema = SettingsRegistry.shared.schema()
        let data = schema.jsonData(pretty: true)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "object")
        #expect(object["$schema"] as? String == "https://json-schema.org/draft/2020-12/schema")
        let properties = try #require(object["properties"] as? [String: [String: Any]])
        #expect(properties.count == SettingsRegistry.shared.all.count)
        for (key, property) in properties {
            #expect(property["type"] is String, "\(key) has no type")
            #expect(property["title"] is String, "\(key) has no title")
            #expect(property["description"] is String, "\(key) has no description")
            #expect(property["default"] != nil, "\(key) has no default")
        }
        let encoder = try #require(properties["videoEncoder"])
        #expect((encoder["enum"] as? [String])?.contains("h264_videotoolbox") == true)
        let compression = try #require(properties["imageCompression"])
        #expect(compression["minimum"] as? Int == 0)
        #expect(compression["maximum"] as? Int == 100)
    }

    @Test func keysAreUniqueAndSearchable() {
        let keys = SettingsRegistry.shared.keys
        #expect(Set(keys).count == keys.count)
        #expect(SettingsRegistry.shared.search("strip metadata").map(\.key).contains("stripMetadata"))
        #expect(SettingsRegistry.shared.settings(in: .agents).count == 5)
    }

    @Test func otherModulesCanRegisterSettings() throws {
        let registry = SettingsRegistry(EsclopSettings.all)
        let extra = Setting<String>("exampleModuleSetting", default: "on", title: "Example", description: "Registered by another module.", section: .general)
        registry.register(extra)
        #expect(registry.setting("exampleModuleSetting") != nil)
        #expect(registry.all.count == EsclopSettings.all.count + 1)
    }
}

@Suite struct JSONValueTests {
    @Test func parsesAndPrints() {
        let value = JSONValue(parsing: #"{"a":[1,2.5,"x",true,null],"b":{"c":false}}"#)
        #expect(value["a"]?.arrayValue?.count == 5)
        #expect(value["a"]?.arrayValue?[0] == .int(1))
        #expect(value["a"]?.arrayValue?[1] == .double(2.5))
        #expect(value["b"]?["c"] == .bool(false))
        #expect(JSONValue(parsing: value.jsonString()) == value)
        #expect(JSONValue(parsing: "webp") == .string("webp"))
    }
}

@Suite struct ContractHelperTests {
    @Test func formatNamesAndExtensions() {
        #expect(OutputFormat(name: "jpg") == .jpeg)
        #expect(OutputFormat(name: ".PNG") == .png)
        #expect(OutputFormat(name: "h265") == .hevc)
        #expect(OutputFormat(name: "nope") == nil)
        #expect(OutputFormat.hevc.fileExtension == "mp4")
        #expect(OutputFormat.aac.fileExtension == "m4a")
        #expect(OutputFormat.gifVideo.fileExtension == "gif")
        #expect(OutputFormat.webp.utType?.identifier == "org.webmproject.webp")
        for format in OutputFormat.allCases {
            #expect(format.utType != nil, "\(format) has no type")
        }
    }

    @Test func requestDecodesWithoutNewFields() throws {
        // Payloads from before the optional fields existed still decode.
        let request = OptimisationRequest(sources: [URL(fileURLWithPath: "/tmp/a.png")], origin: .cli, fpsCap: 30)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        object.removeValue(forKey: "fpsCap")
        let decoded = try JSONDecoder().decode(OptimisationRequest.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.fpsCap == nil)
        #expect(decoded.sources == request.sources)
    }
}

/// `esclop settings export|import` and Settings › General: the settings the person changed, to
/// carry to another Mac.
@Suite struct SettingsFileTests {
    @Test func exportHoldsOnlyWhatWasSetAndImportBringsItBack() throws {
        let from = scratchStore(), to = scratchStore()
        try EsclopSettings.batchWindowFrom.set(9, in: from)
        try EsclopSettings.imageDirs.set(["~/Pictures/Shots"], in: from)
        try EsclopSettings.enableAutomaticPDFOptimisations.set(true, in: from)
        let data = try SettingsFile.export(from: from)
        let read = try SettingsFile.read(data)
        #expect(Set(read.values.keys) == ["batchWindowFrom", "imageDirs", "enableAutomaticPDFOptimisations"], "defaults are not written")
        try EsclopSettings.batchWindowFrom.set(3, in: to)
        try EsclopSettings.minImageSizeKB.set(7, in: to)
        let imported = try SettingsFile.import(data, into: to)
        #expect(imported.unknown.isEmpty)
        #expect(EsclopSettings.batchWindowFrom.value(in: to) == 9)
        #expect(EsclopSettings.imageDirs.value(in: to) == ["~/Pictures/Shots"])
        #expect(EsclopSettings.enableAutomaticPDFOptimisations.value(in: to))
        #expect(EsclopSettings.minImageSizeKB.value(in: to) == 7, "a key the file does not hold stays")
    }

    @Test func unknownKeysAreSkippedAndNamed() throws {
        let store = scratchStore()
        let data = Data(#"{"format": "esclop-settings", "version": 2, "settings": {"batchWindowFrom": 6, "fromTheFuture": true}}"#.utf8)
        let imported = try SettingsFile.import(data, into: store)
        #expect(imported.unknown == ["fromTheFuture"])
        #expect(EsclopSettings.batchWindowFrom.value(in: store) == 6)
    }

    /// A shared file turns on agent permissions only when asked to; turning one off needs no ask.
    @Test func agentPermissionsComeOnlyWhenAllowed() throws {
        let store = scratchStore()
        try EsclopSettings.allowDeleteBackups.set(true, in: store)
        let data = Data(#"""
        {"format": "esclop-settings", "version": 1, "settings": {"batchWindowFrom": 6, "allowRunScripts": true, "allowUploads": true,
         "allowDeleteBackups": true, "allowOverwriteOriginals": false}}
        """#.utf8)
        let read = try SettingsFile.import(data, into: store)
        #expect(read.permissions == ["allowRunScripts", "allowUploads"], "one already on is not turned on")
        #expect(Set(read.values.keys) == ["batchWindowFrom", "allowDeleteBackups", "allowOverwriteOriginals"])
        #expect(!EsclopSettings.allowRunScripts.value(in: store) && !EsclopSettings.allowUploads.value(in: store))
        #expect(EsclopSettings.batchWindowFrom.value(in: store) == 6)
        let allowed = try SettingsFile.import(data, into: store, allowPermissions: true)
        #expect(allowed.permissions == ["allowRunScripts", "allowUploads"])
        #expect(EsclopSettings.allowRunScripts.value(in: store) && EsclopSettings.allowUploads.value(in: store))
        #expect(try SettingsFile.import(data, into: store).permissions.isEmpty, "nothing left to turn on")
    }

    @Test func aNewerFileIsNamedAndABadChoiceListsTheChoices() throws {
        let store = scratchStore()
        let newer = try SettingsFile.import(Data(#"{"format": "esclop-settings", "version": 2, "settings": {}}"#.utf8), into: store)
        #expect(newer.isNewer && newer.version == 2)
        #expect(try !SettingsFile.read(SettingsFile.export(from: store)).isNewer)
        let bad = Data(#"{"format": "esclop-settings", "version": 1, "settings": {"optimiseURLClipboard": "always"}}"#.utf8)
        #expect { try SettingsFile.import(bad, into: store) } throws: { error in
            (error as? EsclopError)?.description.contains("must be one of offer, download, ignore") == true
        }
    }

    /// A bad file changes nothing: not JSON, another format, or one value a setting does not take.
    @Test func aBadFileIsRefusedWhole() throws {
        let store = scratchStore()
        for text in ["not json", #"{"format": "clop", "version": 1, "settings": {}}"#, #"{"settings": {"batchWindowFrom": 6}}"#,
                     #"{"format": "esclop-settings", "version": 1, "settings": {"batchWindowFrom": 6, "imageDirs": 12}}"#] {
            #expect(throws: EsclopError.self, "\(text)") { try SettingsFile.import(Data(text.utf8), into: store) }
        }
        #expect(!EsclopSettings.batchWindowFrom.isSet(in: store), "nothing was written")
    }
}
