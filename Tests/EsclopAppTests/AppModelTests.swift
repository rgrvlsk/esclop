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
        #expect(card.presentation.capsule == .result(before: 100_000, after: 40_000))
        #expect(harness.announcements.texts.count == 1, "VoiceOver hears each result once")
        #expect(harness.model.recent.first?.id == result.id)
        #expect(harness.model.service.results.recent(limit: 5).map(\.id) == [result.id], "the CLI and MCP see it in the shared log")
        #expect(events.kinds == ["result"])
        #expect(harness.model.activeFiles == 0)
    }

    @Test func nothingSmallerAndFailuresGetTheirOwnCards() async throws {
        let unchanged = Harness(failure: .alreadySmaller)
        _ = await unchanged.model.run(unchanged.job(unchanged.temp.file("a.png", bytes: 5000)))
        #expect(unchanged.model.cards.first?.presentation.detailTitle == "Already optimised")

        let failing = Harness(failure: .toolMissing("ffmpeg"))
        let events = EventLog()
        let report = await failing.model.run(failing.job(failing.temp.file("b.mov")), events: { events.add($0) })
        #expect(report.failures.first?.error == .toolMissing("ffmpeg"))
        #expect(events.kinds == ["failure"])
        let card = try #require(failing.model.cards.first)
        #expect(card.presentation.capsule == .error(title: "Couldn’t optimise", message: "ffmpeg is missing. Reinstall L’Esclop or run Scripts/build-tools.sh."))
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
        harness.model.interact(hovered, .pointerEnteredButtons)
        #expect(await eventually { harness.model.cards.count == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.model.cards.first?.id == hovered.id, "the hovered card stays")
        harness.model.interact(hovered, .pointerExited)
        // Leaving a card whose time ran out hides it two seconds later.
        #expect(await eventually { harness.model.cards.isEmpty })
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
        #expect(await eventually { !harness.model.cards.isEmpty })
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
        harness.model.perform(.undo, on: card)
        #expect(await eventually { if case .restored = card.phase { return true } else { return false } })
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
        #expect(await eventually { harness.model.cards.first?.result != nil })
        let card = try #require(harness.model.cards.first)
        #expect(card.presentation.fileName == "Copied image")
        #expect(card.origin == .clipboard)
        #expect(await eventually { Clipboard.isOwnWrite(harness.pasteboard) })
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
        #expect(await eventually { harness.model.cards.first?.result != nil })
        #expect(harness.model.cards.count == 1)
        #expect(harness.model.cards.first?.aggressive == true)
        harness.model.optimiseDropped([harness.temp.file("notes2.txt")], harder: false)
        #expect(harness.model.cards.last?.presentation.capsule == .notice(title: "Nothing to optimise", detail: "Drop images, videos, PDFs or audio files."))
    }

    @Test func convertAndDownscaleRunAgainFromTheOriginal() async throws {
        let harness = Harness()
        let file = harness.temp.file("a.png", bytes: 100_000)
        _ = await harness.model.run(harness.job(file))
        let first = try #require(harness.model.cards.first)
        harness.model.perform(.convert(.webp), on: first)
        #expect(await eventually { harness.requests.requests.count == 2 && first.result != nil })
        #expect(harness.model.cards.count == 1, "the new result shows on the same card")
        #expect(first.choice.format == .webp)
        let converted = try #require(harness.requests.requests.last)
        #expect(converted.format == .webp)
        #expect(converted.sources == [file])
        #expect(harness.model.cards.first?.result?.bytesBefore == 100_000, "it started from the restored original")

        let second = try #require(harness.model.cards.first)
        harness.model.perform(.downscale, on: second)
        #expect(await eventually { harness.requests.requests.count == 3 && second.result != nil })
        #expect(harness.requests.requests.last?.downscale == 0.5)
        #expect(harness.requests.requests.last?.format == .webp, "the card's choice stays; downscale adds to it")
    }

    @Test func retryOnAnErrorRunsTheFileAgain() async throws {
        // The delay holds the engine between logging the request and failing, the window a busy
        // CI runner opens by chance.
        let harness = Harness(failure: .toolMissing("ffmpeg"), delay: .milliseconds(300))
        _ = await harness.model.run(harness.job(harness.temp.file("a.mov")))
        let card = try #require(harness.model.cards.first)
        harness.model.perform(.retry, on: card)
        // The engine logs the request before it throws; the card turns to an error only after
        // the job has settled, so wait for that, not for the request.
        #expect(await eventually {
            harness.requests.requests.count == 2 && harness.model.cards.first.map { $0.id != card.id && !$0.isWorking } == true
        })
        #expect(harness.model.cards.count == 1)
        #expect(harness.model.cards.first?.presentation.tone == .error, "the fake engine still fails")
    }

    @Test func onlyOneDetailIsOpenAndOnlyTheNewestThreeShow() async throws {
        let harness = Harness()
        for name in ["a", "b", "c", "d"] {
            _ = await harness.model.run(harness.job(harness.temp.file("\(name).png")))
        }
        #expect(harness.model.cards.count == 4)
        #expect(harness.model.visibleCards.map(\.id) == harness.model.cards.suffix(3).map(\.id), "older ones live on in Recent Results")
        let (first, second) = (harness.model.cards[1], harness.model.cards[2])
        harness.model.interact(first, .openDetail)
        #expect(first.machine.level == .detail)
        harness.model.interact(second, .openDetail)
        #expect(second.machine.level == .detail)
        #expect(first.machine.level == .thumbnail, "details never stack")
    }

    @Test func aStillPointerOpensTheDetailOnTheModelsClock() async throws {
        let harness = Harness()
        var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
        harness.model.now = { clock }
        _ = await harness.model.run(harness.job(harness.temp.file("a.png")))
        let card = try #require(harness.model.cards.first)
        var pointer = CGPoint(x: 100, y: 100)
        harness.model.pointerLocation = { pointer }
        harness.model.interact(card, .pointerEntered)
        // The panel does not hear every move: the pointer slides on without an event.
        pointer.x += 40
        clock += 0.61
        harness.model.advance(card)
        #expect(card.machine.level == .thumbnail, "it moved, so that was a pass")
        clock += 0.3
        harness.model.advance(card)
        #expect(card.machine.level == .thumbnail)
        clock += 0.31
        harness.model.advance(card)
        #expect(card.machine.level == .detail)
        harness.model.interact(card, .closeDetail)
        harness.model.interact(card, .pointerExited)
        clock += 3600
        harness.model.advance(card)
        #expect(harness.model.cards.count == 1, "the time ran out while it was open: two more seconds")
        clock += 2
        harness.model.advance(card)
        #expect(harness.model.cards.isEmpty)
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
