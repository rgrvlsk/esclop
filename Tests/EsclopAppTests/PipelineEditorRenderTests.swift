// SPDX-License-Identifier: GPL-3.0-or-later
//
// The pipeline editor window. The form (triggers, filter checked against a file, steps with a
// refused value and a script) renders by default; the text view with a marked line and a "Try
// it" result render with ESCLOP_RENDER_ALL=1. ESCLOP_LANGUAGE=ca draws them in Catalan.

import AppKit
import EsclopCore
import EsclopPipelines
@testable import EsclopAppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct PipelineEditorRenderTests {
    static let text = """
    ---
    description: Screenshots for the blog
    icon: photo
    triggers: clipboard, folder("/Volumes/Shared/Inbox")
    ---
    if(types: png, nameContains: "Screenshot") -> crop(longEdge: 1600) -> convert(to: webp) -> runScript(code: "echo $1")
    """

    func model(_ temp: TempDir) throws -> PipelineEditorModel {
        let store = PipelineStore(directory: temp.url.appendingPathComponent("pipelines", isDirectory: true), useTrash: false)
        _ = try store.save(text: Self.text, name: "Blog screenshots")
        _ = try store.save(Pipeline(name: "Archive PDFs", sections: [PipelineSection(kind: .pdf, steps: [.optimise(dpi: 150)])]))
        let engine = ShrinkingEngine(backups: temp.url.appendingPathComponent("backups", isDirectory: true))
        let model = PipelineEditorModel(store: store, engine: engine)
        model.open(name: "Blog screenshots")
        return model
    }

    @Test func form() async throws {
        let temp = TempDir()
        let model = try model(temp)
        // A refused value, marked on its step.
        model.draft.sections[0].steps[0].values["longEdge"] = "-5"
        model.setSample(temp.file("Screenshot 2026-11-10.png"))
        await model.checkFilter()
        try await SettingsRenderTests.renderBoth({ _ in PipelineEditorView(model: model) }, size: CGSize(width: 960, height: 1000), name: "pipelines-form")
        #expect(model.filterMatches == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ESCLOP_RENDER_ALL"] == "1"))
    func textAndTry() async throws {
        let temp = TempDir()
        let model = try model(temp)
        await model.tryIt(on: temp.file("Screenshot 2026-11-10.png", bytes: 240_000))
        model.setShowsText(true)
        model.editText(Self.text.replacingOccurrences(of: "convert(to: webp)", with: "convert(to: webpp)") + "\n")
        try await SettingsRenderTests.renderBoth({ _ in PipelineEditorView(model: model) }, size: CGSize(width: 960, height: 900), name: "pipelines-text", settle: .milliseconds(400))
        #expect(model.textDiagnostics.contains { $0.line == 6 })
    }
}
