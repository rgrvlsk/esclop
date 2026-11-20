// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EsclopCore
import EsclopIPC
import EsclopPipelines
@testable import EsclopAppKit
import Foundation
import Testing

/// Finder's Quick Actions: what Info.plist declares, in which languages, and what the app does
/// with the files macOS sends.
@MainActor @Suite struct FinderServicesTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func services() throws -> [[String: Any]] {
        let url = root.appendingPathComponent("Scripts/templates/Info.plist.in")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        return try #require(plist?["NSServices"] as? [[String: Any]])
    }

    @Test func infoPlistDeclaresFourServicesTheAppAnswers() throws {
        let services = try Self.services()
        let provider = FinderServices(model: Harness().model, pipelines: { [] })
        #expect(services.count == 4)
        for service in services {
            let message = try #require(service["NSMessage"] as? String)
            #expect(provider.responds(to: NSSelectorFromString("\(message):userData:error:")), "the app answers \(message)")
            #expect(service["NSPortName"] as? String == "L'Esclop", "the port is the app's name")
            #expect(service["NSRequiredContext"] != nil, "shown for files in Finder")
            let types = try #require(service["NSSendFileTypes"] as? [String])
            // Folders too: `handle` takes the media files inside them.
            if message == "convertFilesToWebP" {
                #expect(types == ["public.image", "public.folder"], "only images convert to WebP")
            } else {
                #expect(Set(types) == ["public.image", "public.movie", "public.audio", "com.adobe.pdf", "public.folder"], "only the kinds L'Esclop handles")
            }
            // Clop's key for its Optimise service, so the habit carries over; the others have none.
            let key = (service["NSKeyEquivalent"] as? [String: String])?["default"]
            #expect(key == (message == "optimiseFiles" ? "^O" : nil), "\(message)")
        }
    }

    /// Open With and a drop on the Dock icon: offered for every kind L'Esclop optimises, never as
    /// their default app.
    @Test func infoPlistOffersOpenWithNeverAsTheDefault() throws {
        let url = Self.root.appendingPathComponent("Scripts/templates/Info.plist.in")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        let types = try #require(plist?["CFBundleDocumentTypes"] as? [[String: Any]])
        #expect(types.allSatisfy { $0["LSHandlerRank"] as? String == "Alternate" && $0["CFBundleTypeRole"] as? String == "Viewer" })
        #expect(Set(types.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }) == ["public.image", "public.movie", "public.audio", "com.adobe.pdf"])
    }

    @Test func everyServiceTitleHasCatalan() throws {
        let strings = Self.root.appendingPathComponent("Scripts/templates/ServicesMenu/ca.lproj/ServicesMenu.strings")
        let catalan = try #require(NSDictionary(contentsOf: strings) as? [String: String])
        for service in try Self.services() {
            let title = try #require((service["NSMenuItem"] as? [String: String])?["default"])
            #expect(catalan[title]?.isEmpty == false, "no Catalan for “\(title)”")
            #expect(title.contains("L’Esclop"), "the title says whose action it is")
        }
    }

    @Test func optimiseAndHarderGoThroughTheUsualJobs() async throws {
        let harness = Harness()
        let services = FinderServices(model: harness.model, pipelines: { [] })
        services.handle(.optimise, files: [harness.temp.file("a.png")])
        #expect(await eventually { harness.requests.requests.count == 1 })
        #expect(harness.requests.requests[0].origin == .finder)
        #expect(harness.model.cards.count == 1, "a floating result")
        services.handle(.optimiseHarder, files: [harness.temp.file("b.png")])
        #expect(await eventually { harness.requests.requests.count == 2 })
        #expect(harness.requests.requests[1].quality == .aggressive)
    }

    @Test func aFolderBringsTheMediaInside() async throws {
        let harness = Harness()
        let services = FinderServices(model: harness.model, pipelines: { [] })
        let image = harness.temp.file("shots/inner/a.png")
        _ = harness.temp.file("shots/notes.txt")
        services.handle(.optimise, files: [image.deletingLastPathComponent().deletingLastPathComponent()])
        #expect(await eventually { harness.requests.requests.count == 1 })
        #expect(harness.requests.requests[0].sources.map(\.lastPathComponent) == ["a.png"], "the text file is left out")
    }

    @Test func manyFilesGoToTheBatchWindow() async throws {
        let harness = Harness()
        let services = FinderServices(model: harness.model, pipelines: { [] })
        let files = (1 ... harness.model.batchThreshold).map { harness.temp.file("\($0).png") }
        services.handle(.optimise, files: files)
        #expect(harness.model.batch?.rows.count == files.count)
        #expect(await eventually { harness.requests.requests.count == files.count })
    }

    /// ⌃O on a folder changes its whole tree: past the batch threshold it asks once, and a "no"
    /// leaves every file alone. Files chosen one by one never ask.
    @Test func aLargeFolderAsksOnce() async throws {
        let harness = Harness()
        let services = FinderServices(model: harness.model, pipelines: { [] })
        var asked: [String] = []
        var answer = false
        services.confirm = { question, _ in asked.append(question); return answer }
        let count = harness.model.batchThreshold + 1
        let files = (1 ... count).map { harness.temp.file("Photos export/\($0).png") }
        let folder = files[0].deletingLastPathComponent()
        services.handle(.optimise, files: [folder])
        #expect(asked == ["Optimise \(count) files in Photos export?"])
        #expect(harness.model.batch == nil && harness.requests.requests.isEmpty, "nothing runs after a no")
        answer = true
        services.handle(.optimiseHarder, files: [folder])
        #expect(asked.count == 2)
        #expect(await eventually { harness.requests.requests.count == count })
        services.handle(.optimise, files: (1 ... count).map { harness.temp.file("loose/\($0).png") })
        #expect(asked.count == 2, "a selection of files does not ask")
    }

    @Test func webPConvertsOnlyImagesAndOtherFilesAreLeftWithANotice() async throws {
        let harness = Harness()
        let services = FinderServices(model: harness.model, pipelines: { [] })
        services.handle(.convertToWebP, files: [harness.temp.file("a.png"), harness.temp.file("b.mp3")])
        #expect(await eventually { harness.requests.requests.count == 1 })
        #expect(harness.requests.requests[0].format == .webp)
        #expect(harness.requests.requests[0].sources.first?.lastPathComponent == "a.png")
        services.handle(.optimise, files: [harness.temp.file("notes.txt")])
        #expect(harness.model.cards.contains { if case let .notice(title, _) = $0.phase { return title == "Nothing to optimise" } else { return false } })
    }

    @Test func runPipelineOffersThePipelinesForFinder() async throws {
        let harness = Harness()
        let web = Pipeline(name: "web", triggers: [.rightClick], sections: [PipelineSection(steps: [.optimise()])])
        let archive = Pipeline(name: "Archive", triggers: [.rightClick, .clipboard], sections: [PipelineSection(steps: [.stripExif])])
        let elsewhere = Pipeline(name: "elsewhere", triggers: [.clipboard], sections: [PipelineSection(steps: [.optimise()])])
        var offered: [String] = []
        var shown: [Pipeline] = []
        let services = FinderServices(model: harness.model, pipelines: { shown })
        services.choosePipeline = { pipelines, choose in
            offered = pipelines.map(\.name)
            choose(pipelines[0])
        }
        services.handle(.runPipeline, files: [harness.temp.file("a.png")])
        #expect(harness.model.cards.contains { if case let .notice(title, _) = $0.phase { return title == "No pipeline for Finder yet" } else { return false } })
        shown = [elsewhere, web]
        services.handle(.runPipeline, files: [harness.temp.file("b.png")])
        #expect(offered.isEmpty, "one pipeline runs straight away")
        shown = [web, elsewhere, archive]
        services.handle(.runPipeline, files: [harness.temp.file("c.png")])
        #expect(offered == ["Archive", "web"], "only Finder's, by name")
    }

    @Test func theFilesComeFromTheServicesPasteboard() throws {
        let harness = Harness()
        let pasteboard = NSPasteboard.withUniqueName()
        let file = harness.temp.file("a.png")
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        #expect(FinderServices.files(on: pasteboard).map(\.lastPathComponent) == ["a.png"])
    }
}
