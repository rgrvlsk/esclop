// SPDX-License-Identifier: GPL-3.0-or-later
//
// The batch window's logic: which jobs go to it instead of floating results, the aggregate
// figures, pause and resume, stopping and retrying, restoring everything, and its copy.

import EsclopCore
import EsclopIPC
@testable import EsclopAppKit
import Foundation
import Testing

@MainActor
@Suite struct BatchTests {
    func files(_ harness: Harness, _ count: Int, bytes: Int = 100_000) -> [URL] {
        (1 ... count).map { harness.temp.file("file \($0).png", bytes: bytes) }
    }

    @Test func manyDroppedFilesGoToTheBatchWindow() async throws {
        let harness = Harness()
        var shown: [Batch] = []
        harness.model.onBatch = { shown.append($0) }
        harness.model.optimise(files(harness, 5), origin: .dropZone)
        let batch = try #require(harness.model.batch)
        #expect(shown.count == 1, "the window opens once")
        #expect(await eventually { !batch.isRunning })
        #expect(batch.rows.count == 5)
        #expect(harness.model.cards.isEmpty, "no floating result per file")
        #expect(batch.optimised == 5)
        #expect(batch.bytesBefore == 500_000)
        #expect(batch.bytesAfter == 200_000, "the fake engine keeps 40 %")
        #expect(harness.announcements.texts == ["Batch finished: 5 files, 300\u{00A0}kB saved"], "announced once, at the end")
    }

    @Test func fewFilesStayFloatingResults() async throws {
        let harness = Harness()
        harness.model.optimise(files(harness, 3), origin: .dropZone)
        #expect(await eventually { harness.model.cards.count == 3 && harness.model.cards.allSatisfy { $0.result != nil } })
        #expect(harness.model.batch == nil, "three fit the stack of floating results")
    }

    @Test func theThresholdIsASetting() async throws {
        let harness = Harness()
        try EsclopSettings.batchWindowFrom.set(10, in: harness.settings.store)
        harness.model.optimise(files(harness, 5), origin: .dropZone)
        #expect(await eventually { harness.model.cards.count == 5 })
        #expect(harness.model.batch == nil)
    }

    @Test func aJobWithManyFilesFromTheCLIUsesTheBatchAndStillReports() async throws {
        let harness = Harness()
        let job = OptimisationJob(
            request: OptimisationRequest(sources: files(harness, 6), origin: .cli, location: .inPlace, showResultUI: true), operation: .optimise
        )
        let report = await harness.model.run(job)
        #expect(report.results.count == 6, "the CLI gets every result back")
        #expect(harness.model.batch?.rows.count == 6)
        #expect(harness.model.cards.isEmpty)
        // A job that asks for no result UI stays silent.
        let quiet = OptimisationJob(request: OptimisationRequest(sources: files(harness, 4), origin: .mcp, showResultUI: false), operation: .optimise)
        let previous = harness.model.batch?.id
        _ = await harness.model.run(quiet)
        #expect(harness.model.batch?.id == previous)
    }

    @Test func pauseHoldsWaitingFilesUntilResumed() async throws {
        let harness = Harness(delay: .milliseconds(300), gate: WorkGate(limit: 1))
        harness.model.optimise(files(harness, 5), origin: .dropZone)
        let batch = try #require(harness.model.batch)
        #expect(await eventually { batch.rows.contains { if case .working = $0.state { return true } else { return false } } })
        batch.pause()
        // The file already running finishes; the others, queued at the gate or not, wait.
        #expect(await eventually { batch.rows.filter(\.isRunning).allSatisfy { $0.state == .waiting } && batch.finished >= 1 })
        let finishedWhilePaused = batch.finished
        #expect(finishedWhilePaused < 5, "waiting files hold")
        #expect(BatchPresentation(batch: batch).title.hasPrefix("Paused at"))
        batch.resume()
        #expect(await eventually { !batch.isRunning })
        #expect(batch.optimised == 5)
    }

    @Test func stopKeepsTheOriginalsAndARowRunsAgain() async throws {
        let harness = Harness(delay: .milliseconds(500), gate: WorkGate(limit: 1))
        let sources = files(harness, 4)
        harness.model.optimise(sources, origin: .dropZone)
        let batch = try #require(harness.model.batch)
        #expect(await eventually { batch.rows.contains { if case .working = $0.state { return true } else { return false } } })
        batch.cancelAll()
        #expect(await eventually { !batch.isRunning })
        #expect(batch.cancelled >= 3, "the waiting files stop too")
        #expect(batch.bytesBefore == batch.optimised * 100_000, "stopped files do not dilute the saving")
        let stopped = try #require(batch.rows.first { $0.state == .cancelled })
        #expect(AppModel.size(of: stopped.source) == 100_000, "the original is untouched")
        stopped.retry?()
        #expect(await eventually { stopped.result != nil })
        #expect(BatchPresentation.status(of: stopped, locale: Locale(identifier: "en")) == "100\u{00A0}kB → 40\u{00A0}kB")
    }

    @Test func restoreAllPutsEveryOriginalBack() async throws {
        let harness = Harness()
        let sources = files(harness, 4, bytes: 50_000)
        harness.model.optimise(sources, origin: .dropZone)
        let batch = try #require(harness.model.batch)
        #expect(await eventually { !batch.isRunning })
        #expect(batch.restorable.count == 4)
        await harness.model.restoreAll(batch)
        #expect(batch.rows.allSatisfy { if case .restored = $0.state { return true } else { return false } })
        #expect(sources.allSatisfy { AppModel.size(of: $0) == 50_000 })
        #expect(harness.model.cards.isEmpty, "restoring in the window adds no floating result")
        #expect(batch.bytesAfter == batch.bytesBefore, "nothing saved any more")
        let info = BatchPresentation(batch: batch, locale: Locale(identifier: "en"))
        #expect(info.percent == nil, "no −0 % figure")
        #expect(info.counts == "4 restored")
        let row = batch.rows[0]
        batch.remove(row)
        #expect(batch.rows.count == 3)
    }

    @Test func newFilesJoinARunningBatch() async throws {
        let harness = Harness(delay: .milliseconds(300), gate: WorkGate(limit: 1))
        harness.model.optimise(files(harness, 4), origin: .dropZone)
        let first = try #require(harness.model.batch)
        harness.model.optimise((5 ... 8).map { harness.temp.file("more \($0).png") }, origin: .dropZone)
        #expect(harness.model.batch?.id == first.id)
        #expect(first.rows.count == 8)
        #expect(await eventually { !first.isRunning })
    }

    @Test func copyInEnglishAndCatalan() async throws {
        let harness = Harness()
        harness.model.optimise(files(harness, 4, bytes: 2_400_000), origin: .dropZone)
        let batch = try #require(harness.model.batch)
        #expect(await eventually { !batch.isRunning })
        let en = BatchPresentation(batch: batch, locale: Locale(identifier: "en"))
        #expect(en.title == "4 files optimised")
        #expect(en.change == "9.6\u{00A0}MB → 3.8\u{00A0}MB")
        #expect(en.percent == "−60\u{00A0}%")
        #expect(en.counts == "4 optimised")
        let ca = BatchPresentation(batch: batch, locale: Locale(identifier: "ca_ES"))
        #expect(ca.title == "4 fitxers optimitzats")
        #expect(ca.change == "9,6\u{00A0}MB → 3,8\u{00A0}MB")
        #expect(ca.counts == "4 optimitzats")
    }
}
