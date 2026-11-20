// SPDX-License-Identifier: GPL-3.0-or-later
//
// The first-run window: it shows once, every step can be skipped, finishing is remembered, the
// menu brings it back at the start, its rows write the same settings as the Settings window, and
// it draws in light and dark.

import AppKit
import EsclopCore
import EsclopIPC
import EsclopMCP
@testable import EsclopAppKit
import SwiftUI
import Testing

@MainActor
@Suite struct OnboardingTests {
    let settings = TestSettings()

    @Test func showsOnceUntilFinished() {
        let model = OnboardingModel(defaults: settings.store.defaults)
        #expect(model.shouldShowAtLaunch)
        var finished = 0
        model.onFinish = { finished += 1 }
        model.finish()
        #expect(!model.shouldShowAtLaunch)
        #expect(finished == 1)
        #expect(!OnboardingModel(defaults: settings.store.defaults).shouldShowAtLaunch, "remembered across launches")
    }

    /// Closing the window with its button or ⌘W ends the tour, or it opens at every launch.
    @Test func closingTheWindowFinishes() {
        let viewModel = SettingsViewModel(provider: RegistrySettingsProvider(store: settings.store), extraRows: SettingsPaneView.extraRows)
        let model = OnboardingModel(defaults: settings.store.defaults)
        let controller = OnboardingWindowController(model: model, settings: SettingsWindowController(model: viewModel, actions: SettingsActions()))
        controller.makeWindow().close()
        #expect(model.isFinished)
    }

    /// Back from System Settings, the badge and the switch show what the person chose there, and a
    /// login item waiting for approval counts as on.
    @Test func permissionsRefreshWhenTheAppComesBack() {
        let model = OnboardingModel(defaults: settings.store.defaults)
        model.readClipboardAccess = { .denied }
        model.readLoginStatus = { .requiresApproval }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(model.clipboardAccess == .denied)
        #expect(model.opensAtLogin && model.loginNeedsApproval)
    }

    /// 0 keeps backups for ever: "kept for 0 days" said the opposite, and 1 read "1 days".
    @Test func retentionIsForeverOneDayOrDays() {
        let en = Locale(identifier: "en")
        #expect(SettingPresentation.retention(days: 1) == Strings.text("1 day"))
        #expect(Strings.text("1 day", locale: en) == "1 day" && Strings.format("%d days", 7, locale: en) == "7 days")
        #expect(SettingPresentation.unit("days", key: EsclopSettings.backupRetentionDays.key, value: .int(0)) == Strings.text("days, kept for ever"))
        #expect(SettingPresentation.unit("days", key: EsclopSettings.backupRetentionDays.key, value: .int(1)) == Strings.text("day"))
        #expect(AutomaticPage.summary(retentionDays: 0) == Strings.text("L’Esclop optimises what you copy as soon as you copy it. Originals are always kept and can be restored from the menu."))
        #expect(!AutomaticPage.summary(retentionDays: 1).contains("1 days"))
    }

    @Test func stepsGoForwardAndBack() {
        let model = OnboardingModel(defaults: settings.store.defaults)
        #expect(model.step == .welcome && model.isFirst)
        model.back()
        #expect(model.step == .welcome, "nothing before the first step")
        model.next()
        #expect(model.step == .automatic && model.forward)
        model.next(); model.next()
        #expect(model.step == .agents)
        model.back()
        #expect(model.step == .permissions && !model.forward)
        model.go(to: .done)
        #expect(model.isLast)
        model.next()
        #expect(model.isFinished, "Continue on the last step finishes")
    }

    @Test func skippingFromAnyStepFinishes() {
        for step in OnboardingModel.Step.allCases {
            let settings = TestSettings()
            let model = OnboardingModel(defaults: settings.store.defaults)
            model.go(to: step)
            model.finish()
            #expect(model.isFinished, "skip from \(step)")
        }
    }

    @Test func reopeningStartsAtTheBeginning() {
        let model = OnboardingModel(defaults: settings.store.defaults)
        model.go(to: .agents)
        model.finish()
        model.restart()
        #expect(model.step == .welcome)
    }

    @Test func automaticRowsAreRegistrySettings() {
        let viewModel = SettingsViewModel(provider: RegistrySettingsProvider(store: settings.store))
        for key in AutomaticPage.keys {
            #expect(viewModel.descriptor(key) != nil, "\(key) is a registry setting")
        }
        // A switch flipped during the tour is the same value Settings and the CLI see.
        #expect(viewModel.set(EsclopSettings.optimisePDFClipboard.key, to: .bool(true)))
        #expect(EsclopSettings.optimisePDFClipboard.value(in: settings.store))
    }
}

/// Each step in a real window. By default each step draws once, alternating light and dark, to
/// keep the suite short; ESCLOP_RENDER_ALL=1 draws every step in both for a pull request.
@MainActor
@Suite(.serialized) struct OnboardingRenderTests {
    let settings = TestSettings()

    /// The shipped icon from `assets/`, as the bundle carries it.
    static let appIcon = NSImage(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("assets/AppIcon.png"))

    func render(_ step: OnboardingModel.Step, scheme: ColorScheme) async throws {
        let viewModel = SettingsViewModel(provider: RegistrySettingsProvider(store: settings.store), extraRows: SettingsPaneView.extraRows)
        let fixture = AgentsFixture()
        fixture.populate()
        let agents = AgentsModel(installer: fixture.installer, command: AgentsFixture.command)
        await agents.refresh()
        let model = OnboardingModel(defaults: settings.store.defaults)
        // Reading the real Desktop would make macOS ask the test runner.
        model.readDesktopAccess = { .allowed }
        model.go(to: step)
        let view = OnboardingView(onboarding: model, settings: viewModel, agents: agents, actions: SettingsActions(), icon: Self.appIcon) {}
        let size = try await SettingsRenderTests.renderWindow(view, size: CGSize(width: 640, height: 560), name: "onboarding-\(step.rawValue + 1)-\(String(describing: step))", scheme: scheme)
        #expect(size.width == 640)
    }

    @Test func everyStep() async throws {
        for step in OnboardingModel.Step.allCases {
            try await render(step, scheme: step.rawValue.isMultiple(of: 2) ? .light : .dark)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ESCLOP_RENDER_ALL"] == "1"), arguments: [ColorScheme.light, .dark])
    func everyStepInBothAppearances(scheme: ColorScheme) async throws {
        for step in OnboardingModel.Step.allCases {
            try await render(step, scheme: scheme)
        }
    }
}
