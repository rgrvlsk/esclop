// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import EsclopCore

/// A throwaway UserDefaults suite per test.
func scratchStore() -> SettingsStore {
    SettingsStore(suiteName: "dev.esclop.tests.\(UUID().uuidString)")
}

@Suite struct SettingsTests {
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
