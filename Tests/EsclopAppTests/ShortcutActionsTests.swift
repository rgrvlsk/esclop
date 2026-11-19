// SPDX-License-Identifier: GPL-3.0-or-later

import AppIntents
import AppKit
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

    @Test func theSharedChoicesMapToTheRequest() async throws {
        let harness = Harness()
        let factory = harness.model.factory
        let video = harness.temp.file("a.mp4"), image = harness.temp.file("b.png")
        // Defaults: where Settings say, as before these choices existed.
        let plain = ShortcutActions.job(.optimise(harder: false), for: image, options: .init(), factory: factory).request
        #expect(plain.locationFromSettings == true && plain.showResultUI && plain.quality == .normal && !plain.removeAudio)
        let folder = harness.temp.url.appendingPathComponent("out", isDirectory: true)
        let places: [(ShortcutActions.Place, OutputLocation)] = [(.inPlace, .inPlace), (.besideOriginal, .sameFolder), (.folder(folder), .path(folder.path + "/"))]
        for (place, location) in places {
            let request = ShortcutActions.job(.convert(.webp), for: image, options: .init(place: place), factory: factory).request
            #expect(request.location == location && request.locationFromSettings != true, "\(place)")
        }
        let options = ShortcutActions.Options(hideResult: true, compression: .lossless, removeAudio: true)
        let forVideo = ShortcutActions.job(.downscale(0.5), for: video, options: options, factory: factory).request
        #expect(!forVideo.showResultUI && forVideo.removeAudio && forVideo.quality == CompressionQuality(tier: .custom, factor: 0))
        #expect(!ShortcutActions.job(.downscale(0.5), for: image, options: options, factory: factory).request.removeAudio, "videos only")
        // Optimise harder is aggressive unless a compression is chosen, which wins.
        #expect(ShortcutActions.job(.optimise(harder: true), for: image, options: .init(), factory: factory).request.quality == .aggressive)
        #expect(ShortcutActions.job(.optimise(harder: true), for: image, options: .init(compression: .adaptive), factory: factory).request.quality == .normal)
        let speed = ShortcutActions.job(.playbackSpeed(2), for: video, options: .init(), factory: factory)
        #expect(speed.request.playbackSpeed == 2 && speed.operation == .optimise)
        let crop = ShortcutActions.job(.cropPDF(PDFCropSpec(aspectRatio: 0.75)), for: harness.temp.file("c.pdf"), options: .init(), factory: factory)
        #expect(crop.operation == .cropPDF(PDFCropSpec(aspectRatio: 0.75)))
    }

    @Test func aFolderIsNeededForInAFolder() throws {
        #expect(throws: ShortcutActions.Failure.self) { try shortcutOptions(place: .folder, folder: nil, hideResult: false, copy: false) }
        let temp = TempDir()
        let file = temp.file("a.png")
        #expect(throws: ShortcutActions.Failure.self, "a file is not a folder") {
            try shortcutOptions(place: .folder, folder: IntentFile(fileURL: file), hideResult: false, copy: false)
        }
        let options = try shortcutOptions(place: .folder, folder: IntentFile(fileURL: temp.url), hideResult: true, copy: true, compression: .aggressive)
        #expect(options == ShortcutActions.Options(hideResult: true, place: .folder(temp.url), compression: .aggressive, copy: true))
        #expect(try shortcutOptions(place: .besideOriginal, folder: nil, hideResult: false, copy: false).place == .besideOriginal)
    }

    @Test func resultsGoWhereAskedAndOnTheClipboard() async throws {
        let harness = Harness()
        let file = harness.temp.file("a.png")
        let outputs = try await withModel(harness) {
            try await ShortcutActions.run(.optimise(harder: false), on: [file], options: .init(place: .besideOriginal, copy: true))
        }
        #expect(outputs.count == 1 && outputs[0] != file, "a new file beside the original")
        #expect(outputs[0].deletingLastPathComponent() == file.deletingLastPathComponent())
        await harness.clipboardSettles()
        let copied = harness.pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        #expect(copied == outputs)
        _ = try await withModel(harness) { try await ShortcutActions.run(.optimise(harder: false), on: [harness.temp.file("b.png")], options: .init(hideResult: true)) }
        #expect(harness.model.cards.count == 1, "a hidden result shows no card")
    }

    @Test func manyFilesAreOneBatchWindowAndComeBackInOrder() async throws {
        let harness = Harness()
        let files = (1 ... harness.model.batchThreshold).map { harness.temp.file("\($0).png") }
        let outputs = try await withModel(harness) { try await ShortcutActions.run(.optimise(harder: false), on: files) }
        #expect(outputs == files)
        #expect(harness.model.batch?.rows.count == files.count, "one window for all of them")
        #expect(harness.model.cards.isEmpty, "no floating result per file")
    }

    @Test func speedTakesVideoAndAudioOnly() async throws {
        let harness = Harness()
        try await withModel(harness) {
            _ = try await ShortcutActions.run(.playbackSpeed(1.5), on: [harness.temp.file("a.mp4"), harness.temp.file("b.mp3")])
            await #expect(throws: ShortcutActions.Failure.self) { try await ShortcutActions.run(.playbackSpeed(2), on: [harness.temp.file("c.png")]) }
            await #expect(throws: ShortcutActions.Failure.self) { try await ShortcutActions.run(.playbackSpeed(0), on: [harness.temp.file("d.mp4")]) }
        }
        #expect(harness.requests.requests.map(\.playbackSpeed) == [1.5, 1.5])
    }

    @Test func cropPDFSetsTheCropBoxOfPDFsOnly() async throws {
        let harness = Harness()
        let pdf = harness.temp.url.appendingPathComponent("doc.pdf")
        // Portrait: the crop turns the ratio to each page's orientation.
        var box = CGRect(x: 0, y: 0, width: 300, height: 500)
        let context = try #require(CGContext(pdf as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 260, height: 460))
        context.endPDFPage()
        context.closePDF()
        let spec = try CropPDFIntent.spec("3:4", extend: false)
        #expect(spec.aspectRatio == 0.75)
        #expect(try CropPDFIntent.spec("A4", extend: true) == PDFCropSpec(aspectRatio: 210.0 / 297.0, extend: true))
        #expect(throws: ShortcutActions.Failure.self) { try CropPDFIntent.spec("roughly square", extend: false) }
        let outputs = try await withModel(harness) { try await ShortcutActions.run(.cropPDF(spec), on: [pdf], options: .init(place: .besideOriginal)) }
        let page = try #require(CGPDFDocument(outputs[0] as CFURL)?.page(at: 1))
        let crop = page.getBoxRect(.cropBox)
        #expect(abs(crop.width / crop.height - 0.75) < 0.01, "cropped to 3:4: \(crop)")
        await withModel(harness) {
            await #expect(throws: ShortcutActions.Failure.self) { try await ShortcutActions.run(.cropPDF(spec), on: [harness.temp.file("a.png")]) }
        }
    }

    @Test func optimiseFromURLDownloadsThenOptimises() async throws {
        let harness = Harness()
        let downloaded = harness.temp.file("photo.png")
        let fetched = Fetched()
        ShortcutActions.download = { url in fetched.append(url); return downloaded }
        defer { ShortcutActions.download = { try await WebDownload.fetch($0) } }
        let outputs = try await withModel(harness) {
            try await ShortcutActions.optimise(addresses: [URL(string: "https://example.com/photo")!], harder: true)
        }
        #expect(fetched.urls == [URL(string: "https://example.com/photo")!])
        #expect(outputs == [downloaded])
        #expect(harness.requests.requests.first?.quality == .aggressive)
        await withModel(harness) {
            await #expect(throws: ShortcutActions.Failure.self) { try await ShortcutActions.optimise(addresses: [URL(string: "ftp://example.com/a.png")!], harder: false) }
            await #expect(throws: ShortcutActions.Failure.self) { try await ShortcutActions.optimise(addresses: [], harder: false) }
        }
        #expect(fetched.urls.count == 1, "only http and https are fetched")
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

/// The addresses a test download was asked for.
final class Fetched: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [URL] = []
    func append(_ url: URL) { lock.lock(); list.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return list }
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
        #expect(keys.contains("Optimise ${files} and save ${place}"))
    }
}
