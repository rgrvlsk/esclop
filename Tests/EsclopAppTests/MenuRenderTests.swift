// SPDX-License-Identifier: GPL-3.0-or-later
//
// The menu bar menu's content in a window, so its words can be seen in each language (a real
// menu only draws while it is open). ESCLOP_LANGUAGE=ca draws it in Catalan.

import AppKit
import EsclopCore
import EsclopIPC
import EsclopMCP
@testable import EsclopAppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct MenuRenderTests {
    @Test func menuContent() async throws {
        let harness = Harness()
        try EsclopSettings.imageDirs.set([harness.temp.url.path], in: harness.settings.store)
        harness.model.watchedFolderCount = 2
        let settings = SettingsWindowController(
            model: SettingsViewModel(provider: RegistrySettingsProvider(store: harness.settings.store)),
            agents: AgentsModel(installer: AgentsFixture().installer, command: AgentsFixture.command), actions: SettingsActions()
        )
        let onboarding = OnboardingWindowController(model: OnboardingModel(defaults: harness.settings.store.defaults), settings: settings)
        let sizes = try await SettingsRenderTests.renderBoth({ _ in
            VStack(alignment: .leading, spacing: 8) {
                MenuContent(model: harness.model, settings: settings, onboarding: onboarding)
            }
            .padding(16)
            .frame(width: 360, alignment: .leading)
        }, size: CGSize(width: 360, height: 520), name: "menu")
        #expect(sizes.allSatisfy { $0.width == 360 })
        #expect(MenuContent.foldersLine(count: 2, paused: false) != nil)
    }
}
