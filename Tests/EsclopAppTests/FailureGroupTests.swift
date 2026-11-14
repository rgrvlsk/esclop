// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EsclopCore
@testable import EsclopAppKit
import Foundation
import Testing

@MainActor
@Suite struct FailureGroupTests {
    func done(_ harness: Harness, _ name: String) -> ResultCard {
        let file = harness.temp.file(name, bytes: 1000)
        let card = ResultCard(jobID: UUID(), source: file, origin: .dropZone, bytesBefore: 1000)
        card.phase = .done(OptimisationResult(source: file, output: file, kind: .image, bytesBefore: 1000, bytesAfter: 400, startedAt: Date(), finishedAt: Date()))
        harness.model.add(card)
        return card
    }

    @Test func twoFailuresShareOnePlaceAndNeverPushTheResultsOff() async throws {
        let harness = Harness(failure: .toolMissing("ffmpeg"))
        let first = done(harness, "a.png")
        _ = await harness.model.run(harness.job(harness.temp.file("b.mov")))
        #expect(!harness.model.groupsFailures, "one failure keeps its own card")
        #expect(harness.model.visibleCards.count == 2)

        _ = await harness.model.run(harness.job(harness.temp.file("c.mov")))
        _ = await harness.model.run(harness.job(harness.temp.file("d.mov")))
        let second = done(harness, "e.png")
        let third = done(harness, "f.png")
        #expect(harness.model.groupsFailures)
        #expect(harness.model.failedCards.count == 3)
        #expect(harness.model.visibleCards.map(\.id) == [second.id, third.id], "the group takes the third place")
        #expect(!harness.model.visibleCards.contains { $0.id == first.id }, "older results go to Recent Results")
        #expect(FailureGroup.heading(harness.model.failedCards) == "3 not optimised")
    }

    @Test func theHeadingSaysWhatDidNotHappen() {
        func card(_ upload: Bool) -> ResultCard {
            // A folder that is never made, so the file is gone on any machine.
            let card = ResultCard(jobID: UUID(), source: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/a.png"), origin: .dropZone, bytesBefore: 10)
            if upload {
                card.phase = .done(OptimisationResult(source: card.source, output: card.source, kind: .image, bytesBefore: 10, bytesAfter: 5, startedAt: Date(), finishedAt: Date()))
                card.upload = .failed("The server refused it.")
            } else {
                card.phase = .failed("The file is damaged.")
            }
            return card
        }
        #expect(card(true).failure == .upload && card(false).failure == .optimise)
        #expect(FailureGroup.heading([card(true), card(true)]) == "2 not uploaded")
        #expect(FailureGroup.heading([card(true), card(false)]) == "2 failed")
        #expect(FailureGroup.heading([card(false)]) == "Not optimised", "one left needs no number")
        #expect(FailureGroup.retry(for: card(true)) == .retryUpload)
        #expect(FailureGroup.retry(for: card(false)) == nil, "a file that is gone has nothing to try again")
    }

    @Test func retryAllRunsEachAgainAndDismissRemovesOnlyTheFailures() async throws {
        let harness = Harness(failure: .toolMissing("ffmpeg"))
        let kept = done(harness, "a.png")
        for name in ["b.mov", "c.mov"] { _ = await harness.model.run(harness.job(harness.temp.file(name))) }
        #expect(harness.requests.requests.count == 2)
        harness.model.failuresExpanded = true
        harness.model.retryFailures()
        #expect(!harness.model.failuresExpanded, "Retry All closes the list")
        #expect(await eventually { harness.requests.requests.count == 4 }, "each failure ran again")
        #expect(await eventually { harness.model.failedCards.count == 2 }, "and failed again")

        harness.model.failuresExpanded = true
        harness.model.dismissFailures()
        #expect(harness.model.failedCards.isEmpty)
        #expect(harness.model.cards.map(\.id) == [kept.id])
        #expect(!harness.model.failuresExpanded)
    }

    @Test func aFailureInUseStaysItsOwnCard() async throws {
        let harness = Harness(failure: .toolMissing("ffmpeg"))
        _ = await harness.model.run(harness.job(harness.temp.file("b.mov")))
        let open = try #require(harness.model.cards.first)
        harness.model.interact(open, .pointerEntered)
        _ = await harness.model.run(harness.job(harness.temp.file("c.mov")))
        #expect(!harness.model.groupsFailures, "the one under the pointer is not taken into a pill")
        #expect(harness.model.visibleCards.contains { $0.id == open.id })
        _ = await harness.model.run(harness.job(harness.temp.file("d.mov")))
        #expect(harness.model.groupsFailures && harness.model.failedCards.count == 2, "the others group")
        #expect(harness.model.visibleCards.contains { $0.id == open.id }, "and it stays beside them")
    }

    @Test func anOpenListStaysWhileOneIsLeft() async throws {
        let harness = Harness(failure: .toolMissing("ffmpeg"))
        for name in ["b.mov", "c.mov"] { _ = await harness.model.run(harness.job(harness.temp.file(name))) }
        harness.model.failuresExpanded = true
        harness.model.dismiss(try #require(harness.model.failedCards.first))
        #expect(harness.model.groupsFailures, "nothing changes under the pointer")
        harness.model.failuresExpanded = false
        #expect(!harness.model.groupsFailures, "closed, the last one is a card again")
    }
}
