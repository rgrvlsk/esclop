// SPDX-License-Identifier: GPL-3.0-or-later
//
// The pipeline editor in a real window while what it shows goes away under it. These used to
// stop the app with SIGTRAP inside SwiftUI's update (a binding forced onto a step, a filter or a
// section that was gone), which only a hosted window shows: model tests never run the view
// update. Each case acts with the window on screen and waits for the update that would trap.

import AppKit
import EsclopCore
import EsclopPipelines
@testable import EsclopAppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct PipelineEditorStabilityRenderTests {
    static let filtered = "if(types: png) -> crop(longEdge: 1600) -> convert(to: webp)"
    static let threeSections = "optimise\n\n[image]\nif(types: png) -> downscale(factor: 0.5)\n\n[video]\ncapFps(fps: 30)\n"

    final class Rig {
        let temp = TempDir()
        let store: PipelineStore
        let model: PipelineEditorModel
        let window: NSWindow

        @MainActor init() throws {
            store = PipelineStore(directory: temp.url.appendingPathComponent("pipelines", isDirectory: true), useTrash: false)
            _ = try store.save(text: PipelineEditorStabilityRenderTests.filtered, name: "Blog screenshots")
            _ = try store.save(text: PipelineEditorStabilityRenderTests.threeSections, name: "Three kinds")
            _ = try store.save(text: "optimise -> stripExif", name: "Plain")
            model = PipelineEditorModel(store: store, engine: ShrinkingEngine(backups: temp.url.appendingPathComponent("backups", isDirectory: true)))
            model.tryRoot = temp.url.appendingPathComponent("tries", isDirectory: true)
            window = NSWindow(contentViewController: NSHostingController(rootView: PipelineEditorView(model: model)))
            window.isReleasedWhenClosed = false
            window.setContentSize(CGSize(width: 960, height: 900))
            window.orderFrontRegardless()
        }

        /// Does `change` with the window on screen, then lets SwiftUI update it.
        @MainActor func act(_ change: () -> Void) async throws {
            change()
            // One update is enough for the trap these guard against; 80 ms lets it run.
            try await Task.sleep(for: .milliseconds(80))
            window.contentView?.layoutSubtreeIfNeeded()
        }

        @MainActor func open(_ name: String) async throws {
            try await act { model.open(name: name) }
            #expect(model.pendingSelection == nil, "nothing unsaved stood in the way of \(name)")
        }
    }

    @Test func switchingAwayFromAFilteredPipeline() async throws {
        let rig = try Rig()
        try await rig.open("Blog screenshots")
        try await rig.open("to WebP")
        #expect(rig.model.isTemplate)
        try await rig.open("Blog screenshots")
        try await rig.open("Plain")
        rig.window.close()
    }

    @Test func editingAwayWhatTheFormShows() async throws {
        let rig = try Rig()
        let model = rig.model
        try await rig.open("Blog screenshots")
        // The filter off and on again.
        try await rig.act { model.hasFilter = false }
        #expect(model.draft.filter == nil)
        try await rig.act { model.hasFilter = true }
        #expect(model.draft.filter != nil)
        // Remove Step on the last step, then on every step.
        try await rig.act { model.removeStep(model.draft.sections[0].steps.last!.id) }
        try await rig.act { model.draft.sections[0].steps.map(\.id).forEach(model.removeStep) }
        #expect(model.draft.sections[0].steps.isEmpty)
        // Revert brings it all back.
        try await rig.act { model.revert() }
        #expect(model.draft.filter?.values["types"] == "png" && model.draft.sections[0].steps.count == 2)
        rig.window.close()
    }

    @Test func sectionsThatGoAway() async throws {
        let rig = try Rig()
        let model = rig.model
        try await rig.open("Three kinds")
        try await rig.act { model.sectionID = "video" }
        // The selected tab's section removed.
        try await rig.act { model.removeSection("video") }
        #expect(model.draft.sections.map(\.id) == ["any", "image"])
        try await rig.act { model.sectionID = "image" }
        try await rig.act { model.select(model.selection) }
        // From three sections to one, with the last tab selected.
        try await rig.act { model.sectionID = "video" }
        try await rig.open("Plain")
        #expect(model.draft.sections.map(\.id) == ["any"])
        #expect(model.currentSection != nil, "the tab follows")
        rig.window.close()
    }

    @Test func textEditsThatDropTheFilterOrASection() async throws {
        let rig = try Rig()
        let model = rig.model
        try await rig.open("Three kinds")
        try await rig.act { model.sectionID = "video" }
        try await rig.act { model.setShowsText(true) }
        try await rig.act { model.editText("optimise\n\n[image]\ndownscale(factor: 0.5)\n") }
        try await rig.act { model.setShowsText(false) }
        #expect(model.draft.sections.map(\.id) == ["any", "image"])
        try await rig.act { model.save() }
        try await rig.open("Blog screenshots")
        try await rig.act { model.setShowsText(true) }
        try await rig.act { model.editText("crop(longEdge: 1600) -> convert(to: webp)\n") }
        try await rig.act { model.setShowsText(false) }
        #expect(model.draft.filter == nil)
        rig.window.close()
    }

    @Test func thePipelineFileGoesAway() async throws {
        let rig = try Rig()
        let model = rig.model
        try await rig.open("Blog screenshots")
        // Delete from the window.
        try await rig.act { model.delete() }
        #expect(try rig.store.list().map(\.name) == ["Plain", "Three kinds"])
        // The CLI deletes the open pipeline's file.
        try await rig.open("Three kinds")
        try await rig.act { model.sectionID = "image" }
        try rig.store.delete("Three kinds")
        try await rig.act { model.reload() }
        #expect(model.selection == .saved("Plain"))
        rig.window.close()
    }

    @Test func closingTheWindowRemovesTheTriedCopy() async throws {
        let rig = try Rig()
        let controller = PipelineEditorWindowController(model: rig.model)
        rig.window.close()
        controller.show("Blog screenshots")
        await rig.model.tryIt(on: rig.temp.file("shot.png"))
        let folder = try #require(rig.model.tryFolder)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        try await rig.act { controller.window?.close() }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
