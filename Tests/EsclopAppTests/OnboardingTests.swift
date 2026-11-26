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

    /// A refusal says which way it failed: switching off said "did not add" (council C7-F5).
    @Test func aRefusedLoginItemSaysWhichWay() {
        struct Refused: LocalizedError { var errorDescription: String? { "Operation not permitted" } }
        let model = OnboardingModel(defaults: settings.store.defaults)
        model.setLoginItem = { _ in throw Refused() }
        model.opensAtLogin = true
        #expect(model.loginError == Strings.format("macOS did not add L’Esclop to the login items: %@. Add it in System Settings › General › Login Items & Extensions.", "Operation not permitted"))
        model.opensAtLogin = false
        #expect(model.loginError == Strings.format("macOS did not remove L’Esclop from the login items: %@. Remove it in System Settings › General › Login Items & Extensions.", "Operation not permitted"))
        model.setLoginItem = { _ in }
        model.opensAtLogin = false
        #expect(model.loginError == nil)
        // In Settings it leads General, with the menu bar rows (council C7-F4).
        #expect(SettingsPane.general.sections.first == .menuBar)
    }

    /// Screenshots saved outside the Desktop: Settings offers that folder (council C8-F1).
    @Test func screenshotsElsewhereAreOfferedInSettings() {
        #expect(FolderListEditor.unwatched("~/Pictures/Screenshots", in: ["~/Desktop"]) == "~/Pictures/Screenshots")
        #expect(FolderListEditor.unwatched("~/Pictures/Screenshots", in: ["~/Desktop", "~/Pictures/Screenshots/"]) == nil, "watched already")
    }

    /// 0 keeps backups for ever: "kept for 0 days" said the opposite, and 1 read "1 days".
    @Test func retentionIsForeverOneDayOrDays() {
        let en = Locale(identifier: "en")
        #expect(SettingPresentation.retention(days: 1) == Strings.text("1 day"))
        #expect(Strings.text("1 day", locale: en) == "1 day" && Strings.format("%d days", 7, locale: en) == "7 days")
        #expect(SettingPresentation.unit("days", key: EsclopSettings.backupRetentionDays.key, value: .int(0)) == Strings.text("days, kept for ever"))
        #expect(SettingPresentation.unit("days", key: EsclopSettings.backupRetentionDays.key, value: .int(1)) == Strings.text("day"))
    }

    @Test func stepsGoForwardAndBack() {
        let model = OnboardingModel(defaults: settings.store.defaults)
        #expect(OnboardingModel.Step.allCases.count == 3, "three steps (pr8-first-run)")
        #expect(model.step == .copy && model.isFirst)
        model.back()
        #expect(model.step == .copy, "nothing before the first step")
        model.next()
        #expect(model.step == .result && model.forward)
        model.next()
        #expect(model.step == .ready)
        model.back()
        #expect(model.step == .result && !model.forward)
        model.go(to: .ready)
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
        model.go(to: .ready)
        model.finish()
        model.restart()
        #expect(model.step == .copy)
    }

    /// The second step shows the first image the person optimised while the tour was open, and
    /// an example before that: an older result or one that grew is not theirs to show.
    @Test func theSecondStepShowsTheFirstImageOptimisedDuringTheTour() {
        let model = OnboardingModel(defaults: settings.store.defaults)
        func result(_ name: String, _ kind: MediaKind = .image, before: Int = 2_000, after: Int = 500, at date: Date) -> OptimisationResult {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            return OptimisationResult(source: url, output: url, kind: kind, bytesBefore: before, bytesAfter: after, startedAt: date, finishedAt: date)
        }
        let opened = model.openedAt
        var recent = [result("old.png", at: opened.addingTimeInterval(-60))]
        model.results = { recent }
        #expect(model.ownResult == nil, "from before the tour opened")
        recent = [
            result("third.png", at: opened.addingTimeInterval(9)),
            result("grew.png", before: 500, after: 600, at: opened.addingTimeInterval(6)),
            result("clip.mov", .video, at: opened.addingTimeInterval(4)),
            result("first.png", at: opened.addingTimeInterval(2)),
        ] + recent
        #expect(model.ownResult?.source.lastPathComponent == "first.png", "the first image during the tour, newest-first list")
    }
}

/// Each step in a real window. By default each step draws once, alternating light and dark, to
/// keep the suite short; ESCLOP_RENDER_ALL=1 draws every step in both for a pull request.
@MainActor
@Suite(.serialized) struct OnboardingRenderTests {
    let settings = TestSettings()

    /// The last step with Login Items waiting for approval, and the first with macOS asking
    /// before every clipboard read.
    @Test(arguments: [ColorScheme.light, .dark])
    func stepsWithWhatMacOSWaitsFor(scheme: ColorScheme) async throws {
        let viewModel = SettingsViewModel(provider: RegistrySettingsProvider(store: settings.store), extraRows: SettingsPaneView.extraRows)
        let model = OnboardingModel(defaults: settings.store.defaults)
        model.readLoginStatus = { .requiresApproval }
        model.readClipboardAccess = { .asks }
        model.refreshAccess()
        try await SettingsRenderTests.renderWindow(OnboardingView(onboarding: model, settings: viewModel) {}, size: CGSize(width: 600, height: 480), name: "onboarding-1-copy-asks", scheme: scheme, settle: .milliseconds(500))
        model.go(to: .ready)
        try await SettingsRenderTests.renderWindow(OnboardingView(onboarding: model, settings: viewModel) {}, size: CGSize(width: 600, height: 480), name: "onboarding-3-ready-login-waiting", scheme: scheme, settle: .milliseconds(500))
        // The longest last step: macOS refused the login item. It has to fit 600 × 480 in Catalan too.
        model.loginError = Strings.format("macOS did not add L’Esclop to the login items: %@. Add it in System Settings › General › Login Items & Extensions.", "Operation not permitted")
        try await SettingsRenderTests.renderWindow(OnboardingView(onboarding: model, settings: viewModel) {}, size: CGSize(width: 600, height: 480), name: "onboarding-3-ready-login-error", scheme: scheme, settle: .milliseconds(500))
    }

    /// The second step with the person's own picture.
    @Test(arguments: [ColorScheme.light, .dark])
    func ownResult(scheme: ColorScheme) async throws {
        let viewModel = SettingsViewModel(provider: RegistrySettingsProvider(store: settings.store), extraRows: SettingsPaneView.extraRows)
        let model = OnboardingModel(defaults: settings.store.defaults)
        let picture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("assets/AppIcon.png")
        let done = model.openedAt.addingTimeInterval(1)
        model.results = { [OptimisationResult(source: picture, output: picture, kind: .image, bytesBefore: 2_400_000, bytesAfter: 590_000, startedAt: done, finishedAt: done)] }
        model.go(to: .result)
        try await SettingsRenderTests.renderWindow(OnboardingView(onboarding: model, settings: viewModel) {}, size: CGSize(width: 600, height: 480), name: "onboarding-2-result-own", scheme: scheme, settle: .milliseconds(1200))
    }

    func render(_ step: OnboardingModel.Step, scheme: ColorScheme) async throws {
        let viewModel = SettingsViewModel(provider: RegistrySettingsProvider(store: settings.store), extraRows: SettingsPaneView.extraRows)
        let model = OnboardingModel(defaults: settings.store.defaults)
        model.readClipboardAccess = { .allowed }
        model.refreshAccess()
        model.go(to: step)
        let view = OnboardingView(onboarding: model, settings: viewModel) {}
        let size = try await SettingsRenderTests.renderWindow(view, size: CGSize(width: 600, height: 480), name: "onboarding-\(step.rawValue + 1)-\(String(describing: step))", scheme: scheme)
        #expect(size.width == 600)
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
