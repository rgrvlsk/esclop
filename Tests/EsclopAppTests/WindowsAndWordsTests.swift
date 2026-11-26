// SPDX-License-Identifier: GPL-3.0-or-later
//
// Council round 3, group S (HC-27): a batch stays reachable after it ends, every kept original
// can be restored from the Originals window, Compare restores only what has a backup, Open at
// login is in Settings, the tour starts watching folders on its Permissions page, the Settings
// search folds accents, and a custom Fit has its own chip.

import AppKit
import EsclopCore
import EsclopIPC
@testable import EsclopAppKit
import SwiftUI
import Testing

@MainActor
@Suite struct WindowsAndWordsTests {
    let settings = TestSettings()

    /// W7: a batch restore that sent an edited version to the Trash says so on the row.
    @Test func aBatchRestoreSaysTheEditWentToTheTrash() async throws {
        let harness = Harness()
        harness.model.optimise((1 ... 4).map { harness.temp.file("shot \($0).png") }, origin: .dropZone)
        let batch = try #require(harness.model.batch)
        #expect(await eventually { !batch.isRunning })
        harness.model.restoreBackup = { service, result in
            var outcome = try await service.restoreBackup(of: result, deleteBackup: false)
            outcome.movedToTrash = [result.source.path]
            return outcome
        }
        let row = batch.rows[0]
        await harness.model.restore(row)
        #expect(row.editInTrash)
        #expect(BatchPresentation.status(of: row, locale: Locale(identifier: "en")).hasSuffix("· Your edited version is in the Trash"))
    }

    /// W3: every kept original is listed with its name and size, restores from the list, then
    /// reads as in place; Remove All deletes them.
    @Test func originalsListRestoresAndRemoves() async throws {
        let harness = Harness()
        let file = harness.temp.file("Holiday.png", bytes: 100_000)
        harness.model.optimise([file], origin: .app)
        #expect(await eventually { harness.model.cards.first?.result != nil })
        #expect(AppModel.size(of: file) == 40_000)
        let originals = OriginalsModel(app: harness.model)
        await originals.load()
        let item = try #require(originals.items.first)
        #expect(originals.items.count == 1)
        #expect(item.entry.original.lastPathComponent == "Holiday.png")
        #expect(originals.totalBytes == 100_000)
        #expect(!item.inPlace)
        #expect(item.result.id == harness.model.cards.first?.result?.id, "the logged result, so the restore judges the file by it")

        await originals.restore([item])
        #expect(AppModel.size(of: file) == 100_000, "the original is back")
        #expect(originals.items.first?.inPlace == true, "nothing left to put back")

        await originals.removeAll()
        #expect(originals.items.isEmpty)
        #expect(originals.store.entries().isEmpty)
    }

    /// W3: an original the log no longer knows (cleared names) still restores, from its manifest.
    @Test func anOriginalOutsideTheLogRestoresFromItsManifest() async throws {
        let harness = Harness()
        let file = harness.temp.file("Scan.png", bytes: 100_000)
        harness.model.optimise([file], origin: .app)
        #expect(await eventually { harness.model.cards.first?.result != nil })
        harness.model.clearRecent()
        let originals = OriginalsModel(app: harness.model)
        await originals.load()
        let item = try #require(originals.items.first)
        #expect(item.result.backup == item.entry.backup)
        await originals.restore([item])
        #expect(AppModel.size(of: file) == 100_000)
        // A backup with no output named never matches the file there, which goes to the Trash.
        let bare = BackupEntry(id: UUID(), original: file, backup: harness.temp.url.appendingPathComponent("elsewhere.png"), output: nil, requestID: nil, createdAt: Date(), bytes: 100_000)
        #expect(OriginalsModel.items([bare], log: harness.model.service.results).first?.result.bytesAfter == -1)
    }

    /// W4: a result written beside its original has no backup: restoring says why in a sentence
    /// of its own, never "…; it was not changed in place is no longer there."
    @Test func aResultWithoutABackupSaysThereIsNothingToRestore() async {
        let harness = Harness()
        let source = harness.temp.file("Poster.png")
        let output = harness.temp.file("Poster.webp", bytes: 40_000)
        let result = OptimisationResult(source: source, output: output, kind: .image, bytesBefore: 100_000, bytesAfter: 40_000, startedAt: Date(), finishedAt: Date())
        #expect(await harness.model.restore(result) == false)
        guard case let .notice(title, detail) = harness.model.cards.last?.phase else {
            Issue.record("a notice says why")
            return
        }
        #expect(title == "Could not restore Poster.png")
        #expect(detail == "The original was never changed. It is still where it was.")
        #expect(FileManager.default.fileExists(atPath: output.path), "nothing moved")
        let inPlace = OptimisationResult(source: source, output: source, kind: .image, bytesBefore: 100_000, bytesAfter: 40_000, startedAt: Date(), finishedAt: Date())
        #expect(AppModel.noBackupMessage(for: inPlace) == "L’Esclop kept no copy of this original.")
        #expect(Strings.text("The original was never changed. It is still where it was.", locale: Locale(identifier: "ca")).hasPrefix("L’original no s’ha tocat mai"))
    }

    /// W5: Open at login is a Settings › General row the search finds, in both languages.
    @Test func openAtLoginIsInGeneral() {
        let model = SettingsViewModel(provider: RegistrySettingsProvider(store: settings.store), extraRows: SettingsPaneView.extraRows)
        model.query = "login"
        #expect(model.hits.contains { $0.id == SettingsPaneView.openAtLoginRow && $0.pane == .general })
        #expect(model.pane(of: SettingsPaneView.openAtLoginRow) == .general)
        model.query = "startup"
        #expect(model.hits.contains { $0.id == SettingsPaneView.openAtLoginRow })
    }

    /// W6: on the first run the folders are watched once the last step says macOS will ask about
    /// the Desktop, never before, and once only; skipping or closing the tour starts them too.
    @Test func theTourStartsWatchingOnItsLastStep() {
        let model = OnboardingModel(defaults: settings.store.defaults)
        var started = 0
        model.onPermissions = { started += 1 }
        model.next()
        #expect(started == 0, "the result step asks nothing")
        model.next()
        #expect(model.step == .ready)
        #expect(started == 1)
        model.back()
        model.next()
        model.finish()
        #expect(started == 1, "once")

        let skipped = OnboardingModel(defaults: TestSettings().store.defaults)
        var skippedStarts = 0
        skipped.onPermissions = { skippedStarts += 1 }
        skipped.finish()
        #expect(skippedStarts == 1, "skipping from the first step still starts watching")
    }

    /// W8: accents fold on both sides of the search.
    @Test func searchFoldsAccents() {
        let model = SettingsViewModel(provider: RegistrySettingsProvider(store: settings.store), extraRows: SettingsPaneView.extraRows)
        model.locale = Locale(identifier: "ca")
        model.reload()
        model.query = "copies de seguretat"
        #expect(model.hits.contains { $0.id == EsclopSettings.backupRetentionDays.key }, "“còpies” without its accent")
        model.query = "CÒPIES"
        #expect(model.hits.contains { $0.id == EsclopSettings.backupRetentionDays.key })
    }

    /// W10: a custom fit has a chip of its own; a preset's fit has none beside its chip.
    @Test func aCustomFitHasItsOwnChip() {
        #expect(FitChips.custom(750_000) == 750_000)
        #expect(FitChips.custom(1_000_000) == nil)
        #expect(FitChips.custom(nil) == nil)
    }
}

/// The surfaces these findings change, in real windows: light and dark; ESCLOP_LANGUAGE=ca draws
/// them in Catalan.
@MainActor
@Suite(.serialized) struct WindowsAndWordsRenderTests {
    /// W1: the menu keeps a "Last batch" row while the model holds a batch, after it ended.
    @Test func theLastBatchStaysInTheMenu() async throws {
        let harness = Harness()
        let actions = MenuPanelActions(settings: {}, pipelines: {}, welcome: {}, checkForUpdates: {}, close: {})
        let without = NSHostingView(rootView: MenuPanel(model: harness.model, actions: actions)).fittingSize.height
        harness.model.optimise((1 ... 5).map { harness.temp.file("photo \($0).png") }, origin: .dropZone)
        let batch = try #require(harness.model.batch)
        #expect(await eventually { !batch.isRunning })
        let with = NSHostingView(rootView: MenuPanel(model: harness.model, actions: actions)).fittingSize.height
        #expect(with > without + 30, "the row shows after the batch ended: \(without) → \(with)")
        try await SettingsRenderTests.renderBoth({ _ in
            MenuPanel(model: harness.model, actions: actions, notch: 200).padding(18)
        }, size: CGSize(width: MenuPanel.width + 36, height: 640), name: "menu-panel-last-batch")
    }

    /// W5: Open at login in Settings › General.
    @Test func openAtLoginInGeneral() async throws {
        let settings = TestSettings()
        let model = SettingsViewModel(provider: RegistrySettingsProvider(store: settings.store), extraRows: SettingsPaneView.extraRows)
        let login = OnboardingModel(defaults: settings.store.defaults)
        login.readLoginStatus = { .enabled }
        login.refreshAccess()
        model.login = login
        model.pane = .general
        // A changed switch, so its reset arrow shows at the trailing edge (W8).
        let toggle = try #require(model.groups(in: .general).first { $0.section == .general }?.settings.first { $0.value?.boolValue != nil })
        #expect(model.set(toggle.key, to: .bool(!(toggle.value?.boolValue ?? false))))
        try await SettingsRenderTests.renderBoth({ _ in SettingsView(model: model) }, size: CGSize(width: 800, height: 620), name: "settings-general-login")
        // The search's way there: the row scrolled into view and marked.
        model.open(SettingsRoute(pane: .general, row: SettingsPaneView.openAtLoginRow))
        try await SettingsRenderTests.renderBoth({ _ in SettingsView(model: model) }, size: CGSize(width: 800, height: 620), name: "settings-general-login-link", settle: .milliseconds(700)) {
            #expect(await eventually(.seconds(10)) { model.markInView == SettingsPaneView.openAtLoginRow }, "in view and marked")
        }
    }

    /// W10: a custom Fit the card keeps is a chosen chip with its value.
    @Test(arguments: [ColorScheme.light, .dark])
    func customFitChip(scheme: ColorScheme) async throws {
        let snapshots = OptionsRenderTests()
        let fitted = snapshots.card(.done(snapshots.renders.saved()))
        fitted.fit = 750_000
        fitted.adjusted = true
        try await snapshots.snapshot(snapshots.model(fitted, harness: Harness()) { $0.tab = .size }, name: "options-size-fit-custom", scheme: scheme)
    }
}
