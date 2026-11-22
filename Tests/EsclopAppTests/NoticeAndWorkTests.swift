// SPDX-License-Identifier: GPL-3.0-or-later
//
// Notices that wait and are heard, work that shows with "Show floating results" off, and the
// launch with the glyph hidden (council round 5, groups C and D).

import AppKit
import EsclopCore
import EsclopIPC
@testable import EsclopAppKit
import Testing

@MainActor
@Suite(.serialized) struct NoticeAndWorkTests {
    /// A notice under the pointer waits, as a card does: the copied address's offer and
    /// "Optimise anyway" stay while the pointer is on them.
    @Test func aNoticeWaitsUnderThePointer() throws {
        let harness = Harness()
        harness.model.hideDelayOverride = nil
        var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
        harness.model.now = { clock }
        harness.model.notice("cove.png", "images.example.com", action: (.download, {}), hideAfter: 4)
        let offer = try #require(harness.model.cards.last)
        harness.model.interact(offer, .pointerEntered)
        clock += 60
        harness.model.advance(offer)
        #expect(harness.model.cards.contains { $0 === offer }, "the pointer is on it")
        harness.model.interact(offer, .pointerExited)
        // Its time ran out while it waited: it goes a little after the pointer left.
        clock += FloatingResultMachine.leaveGrace + 0.01
        harness.model.advance(offer)
        #expect(harness.model.cards.contains { $0 === offer })
        clock += FloatingResultMachine.lateHide + 0.01
        harness.model.advance(offer)
        #expect(!harness.model.cards.contains { $0 === offer }, "it goes once the pointer left")
    }

    /// VoiceOver hears notices and failures as it hears results; a notice with an action waits
    /// for it, and ⌃⇧N reaches that notice.
    @Test func noticesAndFailuresAreHeard() async throws {
        let harness = Harness(failure: .toolMissing("ffmpeg"))
        harness.model.hideDelayOverride = nil
        harness.model.voiceOverRunning = { true }
        harness.model.notice("Paused", "⌃⇧P to resume", hideAfter: 2)
        #expect(harness.announcements.texts.last == "Paused. ⌃⇧P to resume")
        #expect(harness.model.cards.last?.machine.hideDeadline != nil, "a notice with nothing to do still goes")
        harness.model.notice("cove.png", "images.example.com", action: (.download, {}), hideAfter: 4)
        let offer = try #require(harness.model.cards.last)
        #expect(offer.machine.hideDeadline == nil, "under VoiceOver an offer waits for the person")
        #expect(harness.announcements.texts.last == "cove.png. images.example.com. " + CardPresentation.Action.download.title + ". Control-Shift-N to go to it")
        Hotkeys.action(for: .focusNewestResult)(harness.model)
        #expect(offer.wantsFocus && offer.lentKeys, "⌃⇧N lands on the newest notice with an action")

        _ = await harness.model.run(harness.job(harness.temp.file("a.mov")))
        let failed = try #require(harness.model.cards.first { $0.failure != nil })
        #expect(harness.announcements.texts.last == failed.presentation.accessibilityLabel)
        #expect(harness.announcements.texts.last?.contains("ffmpeg") == true)
    }

    /// "Already optimised" is heard as a saving is; a newer notice with the same action and words
    /// takes the older one's place, so "Optimise anyway" for one folder does not pile up, and one
    /// for another folder stays (WatchedFoldersTests.twoTooLargeBurstsKeepBothActions).
    @Test func alreadyOptimisedIsHeardAndNoticesDoNotPileUp() async throws {
        let harness = Harness(failure: .alreadySmaller)
        _ = await harness.model.run(harness.job(harness.temp.file("a.png", bytes: 2_000)))
        #expect(harness.announcements.texts.last?.hasPrefix("Already optimised · ") == true, "\(harness.announcements.texts)")
        harness.model.notice("Too many images", "Desktop", action: (.optimiseAnyway, {}))
        harness.model.notice("Address", "example.com", action: (.download, {}))
        harness.model.notice("Too many images", "Downloads", action: (.optimiseAnyway, {}))
        harness.model.notice("Too many images", "Desktop", action: (.optimiseAnyway, {}))
        let notices = harness.model.cards.compactMap { card -> String? in
            if case let .notice(_, detail) = card.phase { return detail } else { return nil }
        }
        #expect(notices == ["example.com", "Downloads", "Desktop"])
    }

    /// "Show floating results" off: a file at work is still in the menu bar panel, with Stop, and
    /// a failure of what the person asked for says so in a notice.
    @Test func workWithoutCardsShowsAndStops() async throws {
        let harness = Harness(delay: .seconds(600))
        try EsclopSettings.showFloatingResults.set(false, in: harness.settings.store)
        harness.model.optimise([harness.temp.file("Holiday.mov")], origin: .dropZone)
        #expect(await eventually { harness.model.cardlessWork.first?.fraction == 0.5 }, "its progress shows")
        #expect(harness.model.cards.isEmpty)
        harness.model.cardlessWork.first?.stop()
        #expect(await eventually { harness.model.cardlessWork.isEmpty && harness.model.activeFiles == 0 })
        #expect(harness.model.cards.isEmpty, "a file the person stopped needs no notice")
        #expect(harness.model.recent.isEmpty)
    }

    @Test func aFailureWithoutCardsSaysSo() async throws {
        let harness = Harness(failure: .toolMissing("ffmpeg"))
        try EsclopSettings.showFloatingResults.set(false, in: harness.settings.store)
        harness.model.optimise([harness.temp.file("Holiday.mov")], origin: .dropZone)
        #expect(await eventually { !harness.model.cards.isEmpty })
        guard case let .notice(title, detail)? = harness.model.cards.last?.phase else {
            Issue.record("no notice")
            return
        }
        #expect(title == "Could not optimise Holiday.mov")
        #expect(detail.contains("ffmpeg"))
        #expect(harness.model.cardlessWork.isEmpty)
        // A watched folder's or an agent's file is told elsewhere (the batch, the reply).
        #expect(!AppModel.tellsFailures(.watchedFolder) && !AppModel.tellsFailures(.mcp) && !AppModel.tellsFailures(.cli))
    }

    /// With the glyph hidden, a launch by hand shows Settings at the switch that brings it back; a
    /// launch at login, or for the CLI or an agent, stays quiet.
    @Test func aLaunchWithTheGlyphHiddenShowsSettings() throws {
        let settings = TestSettings()
        try EsclopSettings.showMenubarIcon.set(false, in: settings.store)
        let services = AppServices(settings: settings.store)
        #expect(AppServices.launchedQuietly(arguments: ["L’Esclop", AppClient.backgroundLaunch]), "opened by `launchApp`")
        #expect(!AppServices.launchedQuietly(arguments: ["L’Esclop"]))
        services.launched(quietly: true)
        #expect(!services.settingsWindow.isVisible)
        services.launched(quietly: false)
        #expect(services.settingsWindow.isVisible)
        services.settingsWindow.window?.close()

        let shown = AppServices(settings: TestSettings().store)
        shown.launched(quietly: false)
        #expect(!shown.settingsWindow.isVisible, "the glyph is there to find")
    }
}
