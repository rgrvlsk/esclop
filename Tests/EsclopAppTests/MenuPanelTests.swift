// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EsclopCore
import EsclopIPC
@testable import EsclopAppKit
import Foundation
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
}
