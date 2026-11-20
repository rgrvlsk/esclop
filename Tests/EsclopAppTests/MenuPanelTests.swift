// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EsclopCore
import EsclopIPC
@testable import EsclopAppKit
import Foundation
import KeyboardShortcuts
import Testing

@MainActor
@Suite struct MenuPanelTests {
    @Test func theSavingCountsTodayAndTheLastSevenDays() {
        let now = Date()
        func saving(_ daysAgo: Int, _ before: Int, _ after: Int) -> ResultsLog.Saving {
            ResultsLog.Saving(id: UUID(), kind: .image, bytesBefore: before, bytesAfter: after, finishedAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!, redacted: nil)
        }
        let log = [saving(0, 1000, 400), saving(3, 2000, 1000), saving(6, 500, 500), saving(10, 5000, 1000)]
        let today = SavingTotals.of(log, in: .today, now: now)
        #expect(today == SavingTotals(before: 1000, after: 400, files: 1))
        #expect(today.fraction == 0.6)
        let week = SavingTotals.of(log, in: .week, now: now)
        #expect(week == SavingTotals(before: 3500, after: 1900, files: 3), "today and the six days before, not the tenth")
        #expect(SavingTotals().fraction == nil, "nothing saved: the arc alone")
    }

    /// Before the log has loaded, Recent gives the figure: never "0 B, nothing saved" over results
    /// with savings (council D1-F3). Once loaded, the log alone: a result restored by the CLI is
    /// withdrawn there and stays out.
    @Test func theSavingCountsRecentBeforeTheLogLoads() {
        let now = Date()
        let file = URL(fileURLWithPath: "/tmp/a.png")
        let first = OptimisationResult(source: file, output: file, kind: .image, bytesBefore: 1000, bytesAfter: 400, startedAt: now, finishedAt: now)
        let second = OptimisationResult(source: file, output: file, kind: .image, bytesBefore: 500, bytesAfter: 300, startedAt: now, finishedAt: now)
        let opening = SavingTotals.savings(nil, recent: [second, first])
        #expect(SavingTotals.of(opening, in: .today, now: now) == SavingTotals(before: 1500, after: 700, files: 2))
        // The log lists only the first one (the second was restored): Recent adds nothing.
        let logged = ResultsLog.Saving(id: first.id, kind: .image, bytesBefore: 1000, bytesAfter: 400, finishedAt: now)
        let loaded = SavingTotals.savings([logged], recent: [second, first])
        #expect(SavingTotals.of(loaded, in: .today, now: now) == SavingTotals(before: 1000, after: 400, files: 1))
    }

    @Test func clearForgetsTheNamesAndKeepsTheSaving() async throws {
        let harness = Harness()
        _ = await harness.model.run(harness.job(harness.temp.file("Private name.png", bytes: 100_000)))
        #expect(!harness.model.recent.isEmpty)
        let before = harness.model.service.results.savings().count
        harness.model.clearRecent()
        #expect(harness.model.recent.isEmpty)
        #expect(harness.model.service.results.recent(limit: 10).isEmpty)
        #expect(harness.model.service.results.savings().count == before)
        #expect(harness.model.cards.count == 1, "the card on screen stays")
    }

    /// The owner's choice: no paused state on the glyph, but while paused the panel says so in
    /// one line, and Resume turns the setting off.
    @Test func pausedShowsOneLineAndResumeTurnsItOff() {
        let harness = Harness()
        harness.model.setPaused(true)
        #expect(EsclopSettings.pauseAutomaticOptimisations.value(in: harness.settings.store))
        // The panel's Resume is the model's setPaused(false), as wired in `MenuPanel`.
        PausedLine { harness.model.setPaused(false) }.resume()
        #expect(!harness.model.paused)
        #expect(!EsclopSettings.pauseAutomaticOptimisations.value(in: harness.settings.store), "the setting itself is off")
    }

    /// The gear's Pause L’Esclop and the ⌃⇧P hotkey turn the same setting on and off (council
    /// C4-F1): pausing no longer takes Settings. The hotkey also posts a short notice.
    @Test func theGearAndTheHotkeyPauseAndResume() throws {
        let harness = Harness()
        #expect(KeyboardShortcuts.Name.togglePause.defaultShortcut == .init(.p, modifiers: [.control, .shift]), "Clop's key")
        let others = Hotkeys.all.map(\.name).filter { $0 != .togglePause }.compactMap(\.defaultShortcut)
        #expect(!others.contains(.init(.p, modifiers: [.control, .shift])))
        func notice() -> (String, String)? {
            guard case let .notice(title, detail)? = harness.model.cards.last?.phase else { return nil }
            return (title, detail)
        }
        // The hotkey says what it did: nothing else on screen shows it.
        // The key as this keyboard layout names it.
        let key = try #require(KeyboardShortcuts.Name.togglePause.shortcut)
        Hotkeys.action(for: .togglePause)(harness.model)
        #expect(harness.model.paused)
        #expect(EsclopSettings.pauseAutomaticOptimisations.value(in: harness.settings.store))
        #expect(notice()?.0 == Strings.text("Paused") && notice()?.1 == Strings.format("%@ to resume", "\(key)"))
        let deadline = try #require(harness.model.cards.last?.machine.nextDeadline)
        #expect(deadline.timeIntervalSince(harness.model.now()) <= 2.01, "about two seconds")
        Hotkeys.action(for: .togglePause)(harness.model)
        #expect(!harness.model.paused)
        #expect(notice()?.0 == Strings.text("Resumed"))
        #expect(harness.model.cards.count == 1, "the second notice replaces the first")
        // The gear's item, as wired in `MenuPanel`: the open panel's line shows it, no notice.
        harness.model.cards.forEach(harness.model.dismiss)
        harness.model.togglePause()
        #expect(harness.model.paused)
        #expect(harness.model.cards.isEmpty)
        #expect(Hotkeys.all.contains { $0.name == .togglePause }, "listed in Settings › General with the other hotkeys")
    }

    /// Settings › General › Menu bar (council C4-F2): the glyph can go, and the floating windows
    /// stay out of screenshots unless asked, as in Clop.
    @Test func theMenuBarRowsHideTheGlyphAndKeepWindowsOutOfScreenshots() throws {
        let harness = Harness()
        #expect(harness.model.windowSharing == .none, "Clop's default: not in screenshots")
        let panel = FloatingPanel(content: NSView()) { [weak model = harness.model] in model?.windowSharing ?? .none }
        defer { panel.orderOut(nil) }
        #expect(panel.sharingType == .none)
        try EsclopSettings.showInScreenshots.set(true, in: harness.settings.store)
        panel.orderFrontRegardless()
        #expect(panel.sharingType == .readOnly, "read again when it comes up")
        try EsclopSettings.showInScreenshots.set(false, in: harness.settings.store)
        harness.model.applyWindowSharing()
        #expect(panel.sharingType == .none, "and at once on screen")
        // The snapshot tool needs the pictures, which `.none` leaves empty even for the app.
        harness.model.windowsForSnapshots = true
        #expect(harness.model.windowSharing == .readOnly)

        let item = StatusItemController(model: harness.model) { close in
            MenuPanelActions(settings: {}, pipelines: {}, welcome: nil, checkForUpdates: nil, close: close)
        }
        #expect(item.isIconVisible)
        try EsclopSettings.showMenubarIcon.set(false, in: harness.settings.store)
        item.applyMenuBarIcon()
        #expect(!item.isIconVisible)
        try EsclopSettings.showMenubarIcon.set(true, in: harness.settings.store)
        item.applyMenuBarIcon()
        #expect(item.isIconVisible)
    }
}

@MainActor
@Suite struct MainMenuTests {
    /// Without it, ⌘V does nothing in a Settings field: the app is a menu bar app with no menu
    /// of its own on screen.
    @Test func textFieldsAndWindowsHaveTheirKeys() {
        let items = MainMenu.make().items.flatMap { $0.submenu?.items ?? [] }
        func has(_ action: String, _ key: String) -> Bool {
            items.contains { $0.action == Selector((action)) && $0.keyEquivalent == key }
        }
        #expect(has("paste:", "v") && has("copy:", "c") && has("cut:", "x") && has("selectAll:", "a"))
        #expect(has("undo:", "z") && has("performClose:", "w") && has("terminate:", "q"))
    }
}
