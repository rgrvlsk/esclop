// SPDX-License-Identifier: GPL-3.0-or-later
//
// What VoiceOver reads (UI check, N3, N4): an agent row starts with the agent, and an open
// detail offers "Hide details" and a working "More options". SwiftUI builds its accessibility
// tree only for an assistive client, which a test process cannot be, so the per-segment names
// of the tabs and the compression control are checked live.

import AppKit
import EsclopCore
import EsclopIPC
@testable import EsclopAppKit
import Testing

@MainActor
@Suite struct AccessibilityNamesTests {
    let renders = RenderTests()

    @Test func agentRowsStartWithTheAgent() {
        #expect(AgentRow.accessibilityLabel(name: "Codex CLI and ChatGPT desktop", state: "Not connected. ~/.codex/config.toml")
            == "Codex CLI and ChatGPT desktop: Not connected. ~/.codex/config.toml")
    }

    @Test func anOpenDetailCanBeClosedAndLeadsToTheOptions() async throws {
        let harness = Harness()
        let card = renders.card(.done(renders.saved()))
        harness.model.add(card)
        harness.model.interact(card, .openDetail)
        #expect(card.machine.level == .detail)
        let actions = FloatingResultView.actions(card.presentation, level: card.machine.level)
        #expect(actions.contains(.closeDetail) && !actions.contains(.openDetail))
        #expect(CardPresentation.Action.closeDetail.accessibilityName == "Hide details")
        #expect(actions.contains(.more))

        // "More options" from the detail: the detail closes and the popover opens.
        harness.model.perform(.more, on: card)
        #expect(card.machine.level == .thumbnail)
        #expect(card.machine.menuOpen)
        #expect(card.machine.showsHoverButtons, "the row, and its \"…\", is there for the popover to hang from")
    }
}

@MainActor
@Suite struct SettingsWindowTitleTests {
    /// Opened on a pane by a link, the window is named after the pane at once (UI check, N6).
    @Test func aLinkOpensTheWindowNamedAfterThePane() throws {
        let settings = TestSettings()
        let model = SettingsViewModel(provider: RegistrySettingsProvider(store: settings.store))
        let controller = SettingsWindowController(
            model: model, agents: AgentsModel(installer: AgentsFixture().installer, command: AgentsFixture.command), actions: SettingsActions()
        )
        #expect(controller.open(try #require(URL(string: "esclop://settings/agents"))))
        let window = try #require(controller.window)
        defer { window.close() }
        #expect(window.title == SettingsPane.agents.title)
        controller.show(SettingsRoute(pane: .clipboard, row: nil))
        #expect(window.title == SettingsPane.clipboard.title)
    }
}

@Suite struct CatalanVerbTests {
    /// One verb in Catalan: "Optimitzat" on results, so "No s’ha pogut optimitzar" on errors (N8).
    @Test func theErrorTitleUsesTheSameVerb() {
        let ca = Locale(identifier: "ca")
        #expect(Strings.text("Not optimised", locale: ca) == "No optimitzat")
        #expect(Strings.text("Optimised", locale: ca) == "Optimitzat")
    }
}
