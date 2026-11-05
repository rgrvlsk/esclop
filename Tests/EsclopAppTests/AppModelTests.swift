// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EsclopCore
import EsclopIPC
import EsclopOptimisers
@testable import EsclopAppKit
import Foundation
import Testing

@MainActor
@Suite struct AppModelTests {
    @Test func aJobShowsACardThatEndsWithTheSaving() async throws {
        let harness = Harness()
        let file = harness.temp.file("shot.png", bytes: 100_000)
        let events = EventLog()
        let report = await harness.model.run(harness.job(file), events: { events.add($0) })
        #expect(report.results.count == 1)
        #expect(report.failures.isEmpty)
        let card = try #require(harness.model.cards.first)
        let result = try #require(card.result)
        #expect(result.bytesBefore == 100_000)
        #expect(result.bytesAfter == 40_000)
        #expect(card.presentation.headline == "−60%")
        #expect(harness.model.recent.first?.id == result.id)
        #expect(harness.model.service.results.recent(limit: 5).map(\.id) == [result.id], "the CLI and MCP see it in the shared log")
        #expect(events.kinds == ["result"])
        #expect(harness.model.activeFiles == 0)
    }

    @Test func nothingSmallerAndFailuresGetTheirOwnCards() async throws {
        let unchanged = Harness(failure: .alreadySmaller)
        _ = await unchanged.model.run(unchanged.job(unchanged.temp.file("a.png", bytes: 5000)))
        #expect(unchanged.model.cards.first?.presentation.headline == "Already optimised")

        let failing = Harness(failure: .toolMissing("ffmpeg"))
        let events = EventLog()
        let report = await failing.model.run(failing.job(failing.temp.file("b.mov")), events: { events.add($0) })
        #expect(report.failures.first?.error == .toolMissing("ffmpeg"))
        #expect(events.kinds == ["failure"])
        let card = try #require(failing.model.cards.first)
        #expect(card.presentation.detail == "ffmpeg is missing. Reinstall L'Esclop or run Scripts/build-tools.sh.")
        #expect(failing.model.recent.isEmpty)
    }

    @Test func jobsWithoutResultUIShowNoCard() async {
        let harness = Harness()
        let report = await harness.model.run(harness.job(harness.temp.file("a.png"), showUI: false))
        #expect(report.results.count == 1)
        #expect(harness.model.cards.isEmpty)
    }

    @Test func cardsHideOnTheirOwnUnlessHovered() async throws {
        let harness = Harness()
        harness.model.hideDelayOverride = .milliseconds(50)
        _ = await harness.model.run(harness.job(harness.temp.file("a.png")))
        _ = await harness.model.run(harness.job(harness.temp.file("b.png")))
        let hovered = try #require(harness.model.cards.last)
        hovered.isHovered = true
        #expect(await eventually(.seconds(10)) { harness.model.cards.count == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.model.cards.first?.id == hovered.id, "the hovered card stays")
        hovered.isHovered = false
        // Leaving a card whose time ran out hides it two seconds later.
        #expect(await eventually(.seconds(10)) { harness.model.cards.isEmpty })
    }

    @Test func autoHideCanBeTurnedOff() async throws {
        let harness = Harness()
        try EsclopSettings.autoHideFloatingResults.set(false, in: harness.settings.store)
        harness.model.hideDelayOverride = .milliseconds(20)
        _ = await harness.model.run(harness.job(harness.temp.file("a.png")))
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.model.cards.count == 1)
    }

    @Test func dismissingAWorkingCardStopsItsFile() async throws {
        let harness = Harness(delay: .seconds(30))
        let job = harness.job(harness.temp.file("a.png"))
        let run = Task { await harness.model.run(job) }
        #expect(await eventually(.seconds(10)) { !harness.model.cards.isEmpty })
        harness.model.dismiss(try #require(harness.model.cards.first))
        let report = await run.value
        #expect(report.failures.first?.error == .cancelled)
        #expect(harness.model.cards.isEmpty)
    }

    @Test func restoreFromTheCardPutsTheOriginalBack() async throws {
        let harness = Harness()
        let file = harness.temp.file("a.png", bytes: 100_000)
        _ = await harness.model.run(harness.job(file))
        let card = try #require(harness.model.cards.first)
        #expect(harness.model.restorable.count == 1)
        harness.model.perform(.restore, on: card)
        #expect(await eventually(.seconds(10)) { if case .restored = card.phase { return true } else { return false } })
        #expect(AppModel.size(of: file) == 100_000)
        #expect(harness.model.restorable.isEmpty)
    }

    @Test func revealAndCopyUseTheResult() async throws {
        let harness = Harness()
        let file = harness.temp.file("a.png")
        _ = await harness.model.run(harness.job(file))
        let card = try #require(harness.model.cards.first)
        harness.model.perform(.reveal, on: card)
        #expect(harness.revealed.urls == [file])
        harness.model.perform(.copy, on: card)
        #expect(Clipboard.isOwnWrite(harness.pasteboard))
        #expect(Clipboard.read(harness.pasteboard) == .files([file.standardizedFileURL]))
        harness.model.perform(.dismiss, on: card)
        #expect(harness.model.cards.isEmpty)
    }

    @Test func copiedImagesAreOptimisedAndPutBack() async throws {
        let harness = Harness()
        let data = pngData() + Data(count: 60_000)
        harness.model.handleClipboard(.optimiseImage(data, .png))
        #expect(await eventually(.seconds(10)) { harness.model.cards.first?.result != nil })
        let card = try #require(harness.model.cards.first)
        #expect(card.presentation.fileName == "Copied image")
        #expect(card.origin == .clipboard)
        #expect(await eventually(.seconds(10)) { Clipboard.isOwnWrite(harness.pasteboard) })
    }

    @Test func pauseCyclesLikeClop() throws {
        let harness = Harness()
        let model = harness.model
        #expect(model.status == "Watching the clipboard")
        model.cyclePause()
        #expect(model.skipNextCopy)
        #expect(model.status == "Skipping the next copy")
        model.handleClipboard(.optimiseFiles([harness.temp.file("a.png")]))
        #expect(!model.skipNextCopy, "one copy was skipped")
        #expect(model.cards.count == 1, "only the notice card")
        model.cyclePause()
        model.cyclePause()
        #expect(model.paused)
        #expect(EsclopSettings.pauseAutomaticOptimisations.value(in: harness.settings.store))
        model.cyclePause()
        #expect(!model.paused)
    }

    @Test func droppedFoldersAreExpandedToMedia() async throws {
        let harness = Harness()
        let folder = harness.temp.url.appendingPathComponent("drop", isDirectory: true)
        _ = harness.temp.file("drop/a.png")
        _ = harness.temp.file("drop/notes.txt")
        harness.model.optimiseDropped([folder], harder: true)
        #expect(await eventually(.seconds(10)) { harness.model.cards.first?.result != nil })
        #expect(harness.model.cards.count == 1)
        #expect(harness.model.cards.first?.aggressive == true)
        harness.model.optimiseDropped([harness.temp.file("notes2.txt")], harder: false)
        #expect(harness.model.cards.last?.presentation.headline == "Nothing to optimise")
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [JobEvent] = []

    func add(_ event: JobEvent) { lock.withLock { events.append(event) } }

    var kinds: [String] {
        lock.withLock {
            events.compactMap {
                switch $0 {
                case .progress: return nil
                case .result: return "result"
                case .failure: return "failure"
                }
            }
        }
    }
}
