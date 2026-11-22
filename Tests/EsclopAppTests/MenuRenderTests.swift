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

    /// The 7 days chip names its range in the heading; a range with nothing saved says so; each
    /// kind has its own stand-in until its picture loads; the arrows' row is washed.
    @Test func menuPanelWeekKindsAndKeys() async throws {
        let harness = Harness()
        let files: [(String, MediaKind)] = [("Report.pdf", .pdf), ("Interview.m4a", .audio), ("Screen Recording.mov", .video)]
        var ids: [UUID] = []
        for (name, kind) in files {
            let file = harness.temp.url.appendingPathComponent(name)
            let result = OptimisationResult(source: file, output: file, kind: kind, bytesBefore: 8_100_000, bytesAfter: 5_000_000, startedAt: Date(), finishedAt: Date())
            harness.model.record(result)
            ids.append(result.id)
        }
        let actions = MenuPanelActions(settings: {}, pipelines: {}, welcome: {}, checkForUpdates: {}, close: {})
        try await SettingsRenderTests.renderBoth({ _ in
            MenuPanel(model: harness.model, actions: actions, notch: 200, range: .week, highlighted: .result(ids[1])).padding(18)
        }, size: CGSize(width: MenuPanel.width + 36, height: 600), name: "menu-panel-week")
        // The arrows go on past Recent into the commands: one row washed, as in a menu.
        try await SettingsRenderTests.renderBoth({ _ in
            MenuPanel(model: harness.model, actions: actions, notch: 200, range: .week, highlighted: .optimiseFiles).padding(18)
        }, size: CGSize(width: MenuPanel.width + 36, height: 600), name: "menu-panel-command")
        // Nothing yet: no "−0 B".
        let empty = Harness()
        try await SettingsRenderTests.renderBoth({ _ in
            MenuPanel(model: empty.model, actions: actions, notch: 200).padding(18)
        }, size: CGSize(width: MenuPanel.width + 36, height: 520), name: "menu-panel-empty")
    }

    /// "Show floating results" off: a file at work has no card, and the panel lists it with Stop.
    @Test func menuPanelCardlessWork() async throws {
        let harness = Harness(delay: .seconds(600))
        try EsclopSettings.showFloatingResults.set(false, in: harness.settings.store)
        let file = harness.temp.file("Report.pdf", bytes: 10)
        harness.model.record(OptimisationResult(source: file, output: file, kind: .pdf, bytesBefore: 8_100_000, bytesAfter: 5_000_000, startedAt: Date(), finishedAt: Date()))
        harness.model.optimise([harness.temp.file("Holiday.mov")], origin: .dropZone)
        #expect(await eventually { harness.model.cardlessWork.first?.fraction == 0.5 })
        #expect(harness.model.cards.isEmpty)
        let actions = MenuPanelActions(settings: {}, pipelines: {}, welcome: {}, checkForUpdates: {}, close: {})
        try await SettingsRenderTests.renderBoth({ _ in
            MenuPanel(model: harness.model, actions: actions, notch: 200).padding(18)
        }, size: CGSize(width: MenuPanel.width + 36, height: 600), name: "menu-panel-cardless-work")
        harness.model.cardlessWork.forEach { $0.stop() }
        #expect(await eventually { harness.model.cardlessWork.isEmpty })
    }
}
