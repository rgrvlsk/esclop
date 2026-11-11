// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EsclopCore
import EsclopIPC
import EsclopPipelines
@testable import EsclopAppKit
import Foundation
import SwiftUI
import Testing

/// Preset zones: which pipelines are zones, their order, what a drag shows, where a drop goes.
@MainActor @Suite(.serialized) struct PresetZonesTests {
    static func pipeline(_ name: String, _ text: String, zone: Bool = true) throws -> Pipeline {
        var pipeline = try PipelineParser.parse(text, name: name)
        if zone { pipeline.triggers = [.presetZone] }
        return pipeline
    }

    static let images = "[image]\noptimise"
    static let everything = "optimise"

    @Test func savedPipelinesWithTheTriggerAndNamedTemplatesAreZonesInTheSettingsOrder() throws {
        let saved = try [
            Self.pipeline("Zeta", Self.everything), Self.pipeline("Alpha", Self.images),
            Self.pipeline("Plain", Self.everything, zone: false),
        ]
        let builtIn = try [Self.pipeline("to WebP", Self.images, zone: false), Self.pipeline("fit under 1 MB", Self.everything, zone: false)]
        // Nothing named: the saved zones by name, then everything that is off.
        var catalog = PresetZones.catalog(saved: saved, builtIn: builtIn, order: [])
        #expect(catalog.filter(\.isOn).map(\.name) == ["Alpha", "Zeta"])
        #expect(catalog.filter { !$0.isOn }.map(\.name) == ["fit under 1 MB", "Plain", "to WebP"])
        // The setting turns a template on and orders what it names; the rest follow by name.
        catalog = PresetZones.catalog(saved: saved, builtIn: builtIn, order: ["to webp", "Zeta"])
        #expect(catalog.filter(\.isOn).map(\.name) == ["to WebP", "Zeta", "Alpha"])
        #expect(catalog.first { $0.name == "to WebP" }?.builtIn == true)
        // A name in the setting does not make a saved pipeline a zone: its trigger does.
        catalog = PresetZones.catalog(saved: saved, builtIn: builtIn, order: ["Plain"])
        #expect(!(catalog.first { $0.name == "Plain" }?.isOn ?? true))
        // A saved pipeline with a template's name hides the template, as running by name does.
        let shadow = try Self.pipeline("to WebP", Self.everything)
        catalog = PresetZones.catalog(saved: [shadow], builtIn: builtIn, order: ["to WebP"])
        #expect(catalog.filter { $0.name == "to WebP" }.map(\.builtIn) == [false])
    }

    @Test func aDragShowsTheFirstFourThatWorkOnEveryKindInIt() throws {
        let saved = try (1 ... 6).map { try Self.pipeline("All \($0)", Self.everything) } + [Self.pipeline("Images", Self.images)]
        let catalog = PresetZones.catalog(saved: saved, builtIn: [], order: ["Images"])
        #expect(PresetZones.shown(catalog, dragged: [.image]).map(\.name) == ["Images", "All 1", "All 2", "All 3"])
        #expect(PresetZones.shown(catalog, dragged: [.image, .video]).map(\.name) == ["All 1", "All 2", "All 3", "All 4"], "an image pipeline does nothing for the video")
        #expect(PresetZones.shown(catalog, dragged: []).count == PresetZones.limit, "folders alone: every zone takes them")
    }

    @Test func movingAndTurningRewriteTheOrder() throws {
        let saved = try [Self.pipeline("A", Self.everything), Self.pipeline("B", Self.everything)]
        let builtIn = try [Self.pipeline("T", Self.everything, zone: false)]
        let catalog = PresetZones.catalog(saved: saved, builtIn: builtIn, order: ["T"])
        #expect(catalog.filter(\.isOn).map(\.name) == ["T", "A", "B"])
        #expect(PresetZones.moving("B", by: -1, in: catalog) == ["T", "B", "A"])
        #expect(PresetZones.moving("T", by: -1, in: catalog) == ["T", "A", "B"], "the first stays first")
        #expect(PresetZones.moving("T", by: 5, in: catalog) == ["A", "B", "T"])
        #expect(PresetZones.turning("T", on: false, in: catalog) == ["A", "B"])
        #expect(PresetZones.turning("T", on: true, in: PresetZones.catalog(saved: saved, builtIn: builtIn, order: [])) == ["A", "B", "T"])
    }

    @Test func theBuiltInTemplatesAreThereToTurnOn() {
        let catalog = PresetZones.catalog(saved: [], order: [])
        #expect(catalog.count == PipelineStore.presets.count)
        #expect(catalog.allSatisfy { $0.builtIn && !$0.isOn })
    }

    @Test func aDropOnAZoneRunsItsPipelineThroughTheUsualJobs() async throws {
        let harness = Harness()
        let store = harness.model.service.context.pipelines
        try store.save(Self.pipeline("Shrink", Self.everything))
        harness.model.runPresetZone("Shrink", on: [harness.temp.file("a.png")])
        #expect(await eventually { harness.requests.requests.count == 1 })
        #expect(harness.requests.requests[0].origin == .dropZone)
        #expect(harness.model.cards.count == 1, "a floating result")
        // Four files or more go to the batch window, as a plain drop does.
        let many = (1 ... 4).map { harness.temp.file("m\($0).png") }
        harness.model.runPresetZone("Shrink", on: many)
        #expect(await eventually { harness.model.batch != nil })
        #expect(await eventually { harness.requests.requests.count == 5 })
    }

    /// The zone under the drag is the one the view drew there: in a real window, the frames the
    /// views report decide which zone a point is over, and the drop goes to that zone.
    @Test func theHitTestFollowsTheZonesOnScreen() async throws {
        let harness = Harness()
        let store = harness.model.service.context.pipelines
        for name in ["One", "Two", "Three"] { try store.save(Self.pipeline(name, Self.everything)) }
        let controller = DropZoneController(model: harness.model, pipelines: { (try? store.list()) ?? [] }, resultsFrame: { nil })
        defer { controller.hide() }
        controller.show(files: 2, kinds: [.image])
        #expect(controller.state.zones.map(\.name) == ["One", "Three", "Two"])
        try await Task.sleep(for: .milliseconds(200))
        controller.target.layoutSubtreeIfNeeded()
        let target = controller.target
        var dropped: [(String?, Int)] = []
        let original = target.onDrop
        target.onDrop = { urls, _, zone in dropped.append((zone, urls.count)) }
        defer { target.onDrop = original }
        for name in ["One", "Two", "Three", DropZoneState.plainTarget] {
            let frame = try #require(controller.state.frames[name], "\(name) reported its frame")
            // The state's space has its origin at the top left; the view's at the bottom left.
            let inView = NSPoint(x: frame.midX, y: target.bounds.height - frame.midY)
            let inWindow = target.convert(inView, to: nil)
            #expect(target.target(at: inWindow) == name)
        }
        #expect(target.target(at: target.convert(NSPoint(x: 1, y: 1), to: nil)) == nil, "the margin is no target")
        // Zones sit toward the screen: on the left of the plain target in a right corner.
        let plain = try #require(controller.state.frames[DropZoneState.plainTarget])
        #expect(try #require(controller.state.frames["One"]).maxX <= plain.minX)
    }

    @Test func theLinkShowsTheZoneUntilItIsHidden() async throws {
        let harness = Harness()
        let controller = DropZoneController(model: harness.model, resultsFrame: { nil })
        defer { controller.hide() }
        #expect(!controller.open(URL(string: "esclop://settings")!))
        #expect(controller.open(URL(string: "esclop://dropzone?kind=video")!))
        #expect(controller.isVisible && controller.pinned)
        #expect(controller.state.fileCount == 0)
        #expect(controller.open(URL(string: "esclop://dropzone?hide")!))
        #expect(!controller.isVisible && !controller.pinned)
    }

    /// The Settings row in a window while what it lists changes under it: switches turned, a
    /// template moved, the saved pipeline deleted by another process.
    @Test func theSettingsRowFollowsItsPipelines() async throws {
        let temp = TempDir()
        let settings = TestSettings()
        let store = PipelineStore(directory: temp.url, useTrash: false)
        try store.save(Self.pipeline("Mine", Self.everything))
        let model = SettingsViewModel(provider: RegistrySettingsProvider(store: settings.store), extraRows: [])
        model.pipelines = store
        model.open(SettingsRoute(pane: .floatingResults, row: "presetZones"))
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
        window.isReleasedWhenClosed = false
        window.setContentSize(CGSize(width: 800, height: 620))
        window.orderFrontRegardless()
        defer { window.close() }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(120))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        func catalog() -> [PresetZone] {
            PresetZones.catalog(saved: (try? store.list()) ?? [], order: EsclopSettings.presetZones.value(in: settings.store))
        }
        try await settle()
        let webp = try #require(catalog().first { $0.name == "to WebP" })
        PresetZoneList.turn(webp, on: true, in: catalog(), model: model)
        try await settle()
        #expect(catalog().filter(\.isOn).map(\.name) == ["Mine", "to WebP"])
        model.set("presetZones", to: .array(PresetZones.moving("to WebP", by: -1, in: catalog()).map { .string($0) }))
        try await settle()
        #expect(catalog().filter(\.isOn).map(\.name) == ["to WebP", "Mine"])
        let mine = try #require(catalog().first { $0.name == "Mine" })
        PresetZoneList.turn(mine, on: false, in: catalog(), model: model)
        try await settle()
        #expect(try !store.load("Mine").triggers.contains(.presetZone), "the switch is the pipeline's trigger")
        try store.delete("Mine")
        PresetZoneList.turn(mine, on: true, in: catalog(), model: model)
        try await settle()
        #expect(!store.contains("Mine"), "a pipeline that went away is not made again")
        #expect(catalog().filter(\.isOn).map(\.name) == ["to WebP"])
    }

    @Test func theSettingIsInTheRegistryWithItsOwnRow() throws {
        #expect(EsclopSettings.all.contains { $0.key == "presetZones" })
        let descriptor = try RegistrySettingsProvider(store: TestSettings().store).descriptor(forKey: "presetZones")
        #expect(SettingPresentation.control(for: descriptor) == .presetZones)
        #expect(SettingsPane.pane(for: .interface) == .floatingResults)
    }
}
