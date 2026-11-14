// SPDX-License-Identifier: GPL-3.0-or-later
//
// The menu bar panel in a window, so its words can be seen in each language. ESCLOP_LANGUAGE=ca
// draws it in Catalan.

import AppKit
import EsclopCore
import EsclopIPC
@testable import EsclopAppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct MenuRenderTests {
    @Test func menuPanel() async throws {
        let harness = Harness()
        for (name, before, after) in [("Screenshot 2026-11-13 at 09.41.12.png", 2_400_000, 612_000), ("Report.pdf", 8_100_000, 5_000_000)] {
            let file = harness.temp.file(name, bytes: 10)
            harness.model.record(OptimisationResult(source: file, output: file, kind: .image, bytesBefore: before, bytesAfter: after, startedAt: Date(), finishedAt: Date()))
        }
        let actions = MenuPanelActions(settings: {}, pipelines: {}, welcome: {}, checkForUpdates: {}, close: {})
        let sizes = try await SettingsRenderTests.renderBoth({ _ in
            MenuPanel(model: harness.model, actions: actions, notch: 200).padding(18)
        }, size: CGSize(width: MenuPanel.width + 36, height: 600), name: "menu-panel")
        #expect(sizes.allSatisfy { $0.width == MenuPanel.width + 36 })

        // Paused from Settings, Shortcuts or the CLI: the one line with Resume.
        let running = NSHostingView(rootView: MenuPanel(model: harness.model, actions: actions)).fittingSize.height
        harness.model.setPaused(true)
        try await SettingsRenderTests.renderBoth({ _ in
            MenuPanel(model: harness.model, actions: actions, notch: 200).padding(18)
        }, size: CGSize(width: MenuPanel.width + 36, height: 650), name: "menu-panel-paused")
        let paused = NSHostingView(rootView: MenuPanel(model: harness.model, actions: actions)).fittingSize.height
        #expect(paused > running + 30, "the paused line shows: \(running) → \(paused)")
    }
}
