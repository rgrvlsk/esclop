// SPDX-License-Identifier: GPL-3.0-or-later

import EsclopCore
import EsclopIPC
import EsclopPipelines
@testable import EsclopAppKit
import Foundation
import Testing

/// What the Shortcuts actions do, driven without Shortcuts: the same functions the intents call.
@MainActor @Suite(.serialized) struct ShortcutActionsTests {
    func withModel<T>(_ harness: Harness, _ body: () async throws -> T) async rethrows -> T {
        ShortcutActions.model = harness.model
        defer { ShortcutActions.model = nil }
        return try await body()
    }

    @Test func optimiseReturnsTheResultsAsFiles() async throws {
        let harness = Harness()
        let files = [harness.temp.file("a.png"), harness.temp.file("b.png")]
        let outputs = try await withModel(harness) { try await ShortcutActions.run(.optimise(harder: false), on: files) }
        #expect(outputs.map(\.lastPathComponent) == ["a.png", "b.png"], "in order, chainable")
        #expect(harness.requests.requests.allSatisfy { $0.origin == .shortcuts && $0.quality == .normal })
        _ = try await withModel(harness) { try await ShortcutActions.run(.optimise(harder: true), on: [harness.temp.file("c.png")]) }
        #expect(harness.requests.requests.last?.quality == .aggressive)
    }

    @Test func convertDownscaleCropAndPipelineSetTheirRequest() async throws {
        let harness = Harness()
        try await withModel(harness) {
            _ = try await ShortcutActions.run(.convert(.webp), on: [harness.temp.file("a.png")])
            _ = try await ShortcutActions.run(.downscale(0.5), on: [harness.temp.file("b.png")])
            _ = try await ShortcutActions.run(.crop(CropSize(aspectRatio: "16:9")), on: [harness.temp.file("c.png")])
        }
        let requests = harness.requests.requests
        #expect(requests[0].format == .webp)
        #expect(requests[1].downscale == 0.5)
        #expect(requests[2].crop?.aspectRatio == "16:9")
    }

    @Test func badInputIsRefusedWithAReason() async throws {
        let harness = Harness()
        ShortcutActions.model = harness.model
        defer { ShortcutActions.model = nil }
        await #expect(throws: ShortcutActions.Failure.self) { try await ShortcutActions.run(.optimise(harder: false), on: []) }
        await #expect(throws: ShortcutActions.Failure.self) { try await ShortcutActions.run(.optimise(harder: false), on: [harness.temp.file("notes.txt")]) }
        await #expect(throws: ShortcutActions.Failure.self) { try await ShortcutActions.run(.downscale(1.5), on: [harness.temp.file("a.png")]) }
        #expect(harness.requests.requests.isEmpty, "nothing ran")
        #expect(throws: ShortcutActions.Failure.self) { try CropFilesIntent.size(width: nil, height: nil, longEdge: nil, aspectRatio: nil, smart: false) }
        #expect(throws: ShortcutActions.Failure.self) { try CropFilesIntent.size(width: nil, height: nil, longEdge: nil, aspectRatio: "wide", smart: false) }
        #expect(try CropFilesIntent.size(width: 800, height: nil, longEdge: nil, aspectRatio: " ", smart: true) == CropSize(width: 800, smart: true))
    }

    @Test func aFailedFileFailsTheActionWithItsReason() async throws {
        let harness = Harness(failure: .toolMissing("ffmpeg"))
        await withModel(harness) {
            do {
                _ = try await ShortcutActions.run(.optimise(harder: false), on: [harness.temp.file("a.png")])
                Issue.record("expected the action to fail")
            } catch let failure as ShortcutActions.Failure {
                #expect(failure.message.contains("ffmpeg"))
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
    }

    @Test func anActionWaitsForTheAppToStart() async throws {
        let harness = Harness()
        ShortcutActions.model = nil
        defer { ShortcutActions.model = nil }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            ShortcutActions.model = harness.model
        }
        let outputs = try await ShortcutActions.run(.optimise(harder: false), on: [harness.temp.file("a.png")])
        #expect(outputs.count == 1)
    }

    @Test func settingsAreReadAndCheckedByTheRegistry() async throws {
        let harness = Harness()
        ShortcutActions.model = harness.model
        defer { ShortcutActions.model = nil }
        #expect(try await ShortcutActions.set("imageCompression", to: "45") == "45")
        #expect(try await ShortcutActions.value(of: "imageCompression") == "45")
        await #expect(throws: ShortcutActions.Failure.self) { try await ShortcutActions.set("imageCompression", to: "500") }
        await #expect(throws: ShortcutActions.Failure.self) { try await ShortcutActions.value(of: "noSuchSetting") }
        #expect(try await ShortcutActions.set("pauseAutomaticOptimisations", to: "true") == "true")
        #expect(harness.model.paused, "the app follows the pause")
        #expect(try await ShortcutActions.setPaused(false) == false)
        #expect(!harness.model.paused)
    }

    @Test func choicesComeFromTheRegistryTheStoreAndTheFormats() async throws {
        let harness = Harness()
        _ = try harness.model.service.context.pipelines.save(Pipeline(name: "web", steps: [.optimise()]))
        ShortcutActions.model = harness.model
        defer { ShortcutActions.model = nil }
        #expect(try await PipelineQuery().suggestedEntities().map(\.id) == ["web"])
        #expect(try await PipelineQuery().entities(for: ["web", "gone"]).map(\.id) == ["web"])
        let settings = try await SettingQuery().suggestedEntities()
        #expect(settings.count == SettingsRegistry.shared.all.count)
        #expect(settings.first { $0.id == "imageDirs" }?.title == "Screenshot folders")
        // The formats the options popover offers, the ones the engine writes.
        let offered: Set<OutputFormat> = [.png, .jpeg, .webp, .avif, .heic, .gif, .mp4, .hevc, .av1, .webm, .mov, .aac, .mp3, .opus, .flac]
        #expect(Set(ConvertFormat.allCases.map(\.output)) == offered)
    }
}

/// Everything Shortcuts shows for L'Esclop's actions has Catalan: titles, descriptions,
/// parameter names and summaries, read from the intents' sources.
@Suite struct ShortcutStringsTests {
    @Test func everyActionStringHasCatalan() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("Sources/EsclopAppKit/Intents")
        let patterns = [
            #"LocalizedStringResource = "([^"]+)""#, #"IntentDescription\("([^"]+)""#, #"@Parameter\(title: "([^"]+)""#,
            #"Summary\("([^"]+)""#, #"TypeDisplayRepresentation = "([^"]+)""#,
        ].map { try! NSRegularExpression(pattern: $0) }
        var keys = Set<String>()
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for pattern in patterns {
                for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let range = Range(match.range(at: 1), in: text) else { continue }
                    // "Optimise \(\.$files)" is "Optimise ${files}" in the metadata.
                    let key = String(text[range]).replacingOccurrences(of: #"\\\(\\\.\$(\w+)\)"#, with: "\\${$1}", options: .regularExpression)
                    keys.insert(key)
                }
            }
        }
        #expect(keys.count > 30, "the scan found the actions' strings: \(keys.count)")
        let missing = keys.filter { CatalanCoverageTests.catalan[$0] == nil }.sorted()
        #expect(missing.isEmpty, "untranslated: \(missing)")
        #expect(keys.contains("Optimise ${files}"))
    }
}
