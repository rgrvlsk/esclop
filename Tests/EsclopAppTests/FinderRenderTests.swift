// SPDX-License-Identifier: GPL-3.0-or-later
//
// The pipeline editor's triggers with the Finder switch on and the line that says where the
// pipeline shows in Finder. (Finder's own Quick Actions menu is the system's; it is checked
// live.) ESCLOP_LANGUAGE=ca draws it in Catalan.

import AppKit
import EsclopPipelines
@testable import EsclopAppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct FinderRenderTests {
    @Test func finderTrigger() async throws {
        let temp = TempDir()
        let store = PipelineStore(directory: temp.url.appendingPathComponent("pipelines", isDirectory: true), useTrash: false)
        _ = try store.save(Pipeline(name: "Web", triggers: [.rightClick, .clipboard], sections: [PipelineSection(steps: [.optimise()])]))
        let model = PipelineEditorModel(store: store, engine: ShrinkingEngine(backups: temp.url.appendingPathComponent("backups", isDirectory: true)))
        model.open(name: "Web")
        let sizes = try await SettingsRenderTests.renderBoth({ _ in
            Form { PipelineTriggersSection(model: model) }.formStyle(.grouped)
        }, size: CGSize(width: 640, height: 560), name: "finder-trigger")
        #expect(sizes.allSatisfy { $0.width == 640 })
        #expect(model.draft.has(.rightClick))
    }
}
