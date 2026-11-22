// SPDX-License-Identifier: GPL-3.0-or-later
//
// One restore truth (HC-33): an original put back from one window is never put back again from
// another, which would send it to the Trash as an "edit"; Originals judges a result rebuilt after
// Recent › Clear by its real finish time, follows backups added while open and names what it
// could not remove; Clear forgets a finished batch; the batch window's selection runs again.

import AppKit
import EsclopCore
import EsclopIPC
import EsclopMCP
@testable import EsclopAppKit
import Foundation
import SwiftUI
import Testing

@MainActor
@Suite struct RestoreAndBatchTests {
    /// The backups the restore was asked to put back, in order. A second ask for one backup is
    /// the bug (it sends the original to the Trash as an edit): it fails instead and leaves the
    /// disk alone, so a regression never puts a test file in the real Trash.
    final class Restores: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var backups: [String] { lock.withLock { stored } }

        /// True the first time for `backup`.
        func add(_ backup: String) -> Bool {
            lock.withLock {
                defer { stored.append(backup) }
                return !stored.contains(backup)
            }
        }
    }

    /// A finished batch of four, with the restores counted.
    func batch(_ harness: Harness) async throws -> (Batch, Restores) {
        let restores = Restores()
        harness.model.restoreBackup = { service, result in
            guard restores.add(result.backup?.path ?? "") else {
                throw EsclopError.other("put back twice")
            }
            return try await service.restoreBackup(of: result, deleteBackup: false)
        }
        let sources = (1 ... 4).map { harness.temp.file("photo \($0).png", bytes: 100_000) }
        harness.model.optimise(sources, origin: .dropZone)
        let batch = try #require(harness.model.batch)
        #expect(await eventually { !batch.isRunning })
        #expect(batch.optimised == 4)
        return (batch, restores)
    }

    func isRestored(_ row: BatchRow) -> Bool {
        if case .restored = row.state { return true }
        return false
    }

    /// Each backup was put back once, no row or card says an edit went to the Trash, and every
    /// original is back.
    func expectOneRestoreEach(_ batch: Batch, _ restores: Restores, _ harness: Harness) {
        #expect(restores.backups.count == Set(restores.backups).count, "no original put back twice")
        #expect(batch.rows.allSatisfy(isRestored), "every row says restored")
        #expect(batch.rows.allSatisfy { !$0.editInTrash })
        #expect(batch.restorable.isEmpty, "nothing left to restore")
        #expect(harness.model.cards.allSatisfy { !$0.editInTrash })
        #expect(batch.rows.allSatisfy { AppModel.size(of: $0.source) == 100_000 })
    }

    /// The card's ⌘Z (or Compare's Restore Original), then the batch's Restore All.
    @Test func cardThenBatch() async throws {
        let harness = Harness()
        let (batch, restores) = try await batch(harness)
        let result = try #require(batch.rows[0].result)
        harness.model.show(result)
        #expect(await harness.model.restore(result))
        #expect(isRestored(batch.rows[0]), "the row follows at once")
        #expect(batch.restorable.count == 3)
        await harness.model.restoreAll(batch)
        #expect(restores.backups.count == 4)
        expectOneRestoreEach(batch, restores, harness)
    }

    /// The batch row's Restore, then the card's ⌘Z: the card says restored, with no edit.
    @Test func batchThenCard() async throws {
        let harness = Harness()
        let (batch, restores) = try await batch(harness)
        let result = try #require(batch.rows[0].result)
        let card = harness.model.show(result)
        await harness.model.restore(batch.rows[0])
        #expect(await harness.model.restore(result))
        #expect(restores.backups.count == 1)
        guard case .restored = card.phase else {
            Issue.record("the card says restored")
            return
        }
        #expect(!card.editInTrash)
        #expect(!harness.model.restorable.contains { $0.id == result.id }, "Recent offers no Restore")
    }

    /// Recent's Restore Original, then Restore All.
    @Test func recentThenRestoreAll() async throws {
        let harness = Harness()
        let (batch, restores) = try await batch(harness)
        let result = try #require(harness.model.restorable.first { $0.id == batch.rows[2].result?.id })
        #expect(await harness.model.restore(result))
        await harness.model.restoreAll(batch)
        #expect(restores.backups.count == 4)
        expectOneRestoreEach(batch, restores, harness)
    }

    /// Originals' Restore, then Restore All; also with the names cleared, when Originals rebuilds
    /// the result from the manifest.
    @Test(arguments: [false, true])
    func originalsThenBatch(cleared: Bool) async throws {
        let harness = Harness()
        let (batch, restores) = try await batch(harness)
        if cleared { harness.model.clearRecent() }
        let originals = OriginalsModel(app: harness.model)
        await originals.load()
        let item = try #require(originals.items.first { $0.entry.original.lastPathComponent == "photo 2.png" })
        await originals.restore([item])
        #expect(originals.items.first { $0.id == item.id }?.inPlace == true)
        if cleared {
            #expect(harness.model.batch == nil, "Clear forgot the finished batch")
            // The window is gone; Restore All on its batch is still safe.
        }
        await harness.model.restoreAll(batch)
        #expect(restores.backups.count == 4)
        expectOneRestoreEach(batch, restores, harness)
    }

    /// B2: after Recent › Clear, a result whose encode took longer than two seconds is judged by
    /// its own finish time from the cleared line, not by the backup's: restoring sends nothing to
    /// the Trash.
    @Test func aClearedResultKeepsItsFinishTime() async throws {
        let harness = Harness()
        let file = harness.temp.file("Long encode.png", bytes: 100_000)
        _ = await harness.model.run(harness.job(file, origin: .app))
        let logged = try #require(harness.model.cards.first?.result)
        harness.model.clearRecent()
        let store = BackupStore(root: harness.model.service.context.locations.backups)
        var entry = try #require(store.entries().first)
        // The backup is made before the encode: ten seconds of it.
        entry.createdAt = entry.createdAt.addingTimeInterval(-10)
        let item = try #require(OriginalsModel.items([entry], log: harness.model.service.results).first)
        #expect(abs(item.result.finishedAt.timeIntervalSince(logged.finishedAt)) < 2, "the cleared line's time")

        await OriginalsModel(app: harness.model).restore([item])
        #expect(AppModel.size(of: file) == 100_000)
        #expect(harness.model.cards.last?.editInTrash == false, "the optimised file is not called an edit")

        // An edit since is later than that finish: it still goes to the Trash.
        let other = harness.temp.file("Edited.png", bytes: 100_000)
        _ = await harness.model.run(harness.job(other, origin: .app))
        harness.model.clearRecent()
        try Data(repeating: 0x43, count: 12_345).write(to: other)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: other.path)
        let edited = try #require(store.entries().first { $0.original.lastPathComponent == "Edited.png" })
        let rebuilt = try #require(OriginalsModel.items([edited], log: harness.model.service.results).first)
        #expect(rebuilt.result.id == edited.id)
        #expect(!Self.judgedUnchanged(rebuilt.result), "the edit is named")
    }

    /// `BackupStore.holdsOutput`'s date test: the file at the source path is not newer than the
    /// result's finish. (Its size is the file's own for a rebuilt result.)
    nonisolated static func judgedUnchanged(_ result: OptimisationResult) -> Bool {
        let modified = (try? FileManager.default.attributesOfItem(atPath: result.source.path))?[.modificationDate] as? Date
        return modified.map { $0 <= result.finishedAt.addingTimeInterval(2) } ?? false
    }

    /// Y5: a result rebuilt with no log line at all (older than the log keeps) is judged by when
    /// it was put in place, not by the backup's time before a long encode.
    @Test func aResultTheLogNoLongerHasKeepsItsFinishTime() async throws {
        let harness = Harness()
        let file = harness.temp.file("Old.png", bytes: 100_000)
        _ = await harness.model.run(harness.job(file, origin: .app))
        let logged = try #require(harness.model.cards.first?.result)
        let store = BackupStore(root: harness.model.service.context.locations.backups)
        var entry = try #require(store.entries().first)
        entry.createdAt = entry.createdAt.addingTimeInterval(-10)
        let empty = ResultsLog(url: harness.temp.url.appendingPathComponent("empty.jsonl"))
        let item = try #require(OriginalsModel.items([entry], log: empty).first)
        #expect(abs(item.result.finishedAt.timeIntervalSince(logged.finishedAt)) < 2, "the time it was put in place")
        // Refused here: called an edit, the optimised file would go to the real Trash.
        harness.model.restoreBackup = { service, result in
            guard Self.judgedUnchanged(result) else { throw EsclopError.other("called an edit") }
            return try await service.restoreBackup(of: result, deleteBackup: false)
        }
        await OriginalsModel(app: harness.model).restore([item])
        #expect(AppModel.size(of: file) == 100_000, "restored, nothing called an edit")
    }

    /// Y5: restoring several originals from Originals shows one notice, not a card each; Show in
    /// Finder on a row in place shows the original, not the kept copy.
    @Test func originalsRestoreManyWithOneNotice() async throws {
        let harness = Harness()
        let (_, restores) = try await batch(harness)
        let originals = OriginalsModel(app: harness.model)
        await originals.load()
        let cardsBefore = harness.model.cards.count
        await originals.restore(Array(originals.items.prefix(2)))
        #expect(restores.backups.count == 2)
        let added = harness.model.cards.dropFirst(cardsBefore)
        #expect(added.count == 1)
        guard case let .notice(title, _) = added.first?.phase else {
            Issue.record("one notice")
            return
        }
        #expect(title == "2 originals restored")
        let item = try #require(originals.items.first { $0.inPlace })
        originals.reveal([item])
        #expect(harness.revealed.urls.last == item.entry.original)

        // None came back: the notice names them and says why, nothing about them being back.
        let gone = originals.items.filter { !$0.inPlace }
        #expect(gone.count == 2)
        for item in gone { try FileManager.default.removeItem(at: item.entry.backup) }
        #expect(await harness.model.restore(gone.map(\.result)) == 0)
        guard case let .notice(title, detail) = harness.model.cards.last?.phase else {
            Issue.record("a notice")
            return
        }
        #expect(title == "Could not restore \(gone.map(\.entry.original.lastPathComponent).joined(separator: ", "))")
        #expect(!detail.isEmpty && detail != "They are back where they were.")
    }

    /// B7: Clear forgets a finished batch, the menu's tile and its window; a running one stays.
    @Test func clearForgetsAFinishedBatch() async throws {
        let harness = Harness()
        var closed = 0
        harness.model.onBatchForgotten = { closed += 1 }
        _ = try await batch(harness)
        harness.model.clearRecent()
        #expect(harness.model.batch == nil)
        #expect(closed == 1)

        let slow = Harness(delay: .seconds(5))
        slow.model.optimise((1 ... 4).map { slow.temp.file("slow \($0).png") }, origin: .dropZone)
        let running = try #require(slow.model.batch)
        slow.model.clearRecent()
        #expect(slow.model.batch === running, "a running batch keeps its window")
        running.cancelAll()
        #expect(await eventually { !running.isRunning })
    }

    /// B8: the menu's arrows reach Resume and the Last batch tile, top to bottom.
    @Test func theArrowsReachResumeAndTheBatch() {
        let id = UUID()
        #expect(MenuPanel.item(after: nil, by: 1, results: [id], resume: true, batch: true) == .resume)
        #expect(MenuPanel.item(after: .resume, by: 1, results: [id], resume: true, batch: true) == .batch)
        #expect(MenuPanel.item(after: .batch, by: 1, results: [id], resume: true, batch: true) == .result(id))
        #expect(MenuPanel.item(after: .result(id), by: -1, results: [id], batch: true) == .batch)
        #expect(MenuPanel.item(after: .batch, by: -1, results: [id], batch: true) == .batch, "stops at the top")
        #expect(MenuPanel.item(after: nil, by: 1, results: [], batch: true) == .batch)
    }

    /// B4: the open window follows a backup made meanwhile, and Remove names what it could not
    /// delete instead of failing silently.
    @Test func originalsFollowNewBackupsAndNameFailedRemovals() async throws {
        let harness = Harness()
        _ = await harness.model.run(harness.job(harness.temp.file("First.png"), origin: .app))
        let originals = OriginalsModel(app: harness.model)
        await originals.load()
        originals.watch()
        defer { originals.stopWatching() }
        #expect(originals.items.count == 1)
        _ = await harness.model.run(harness.job(harness.temp.file("Second.png"), origin: .app))
        #expect(await eventually(.seconds(20)) { originals.items.count == 2 }, "read again without reopening")

        let first = try #require(originals.items.first { $0.entry.original.lastPathComponent == "First.png" })
        let folder = first.entry.backup.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        await originals.remove([first])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        #expect(originals.removalFailures == ["First.png"])
        #expect(originals.items.count == 2, "nothing claimed removed")
        await originals.removeAll()
        #expect(originals.removalFailures.isEmpty)
        // A reload the deletions started may still be under way: the list ends empty.
        #expect(await eventually { originals.items.isEmpty })
    }

    /// B5: Optimise Again With on the selected rows runs each again from its original, in the
    /// chosen format; the others stay as they are.
    @Test func theSelectionRunsAgainFromItsOriginals() async throws {
        let harness = Harness()
        let (batch, restores) = try await batch(harness)
        let selected = Array(batch.rows.prefix(2))
        let untouched = try #require(batch.rows[3].result)
        let before = harness.requests.requests.count
        await harness.model.rerun(selected, as: .webp)
        #expect(await eventually { selected.allSatisfy { $0.result != nil } && !batch.isRunning })
        let again = harness.requests.requests.dropFirst(before)
        #expect(again.count == 2)
        #expect(again.allSatisfy { $0.format == .webp })
        #expect(restores.backups.count == 2, "each original put back once, first")
        #expect(selected.allSatisfy { $0.result?.bytesBefore == 100_000 }, "from the original, not the optimised file")
        #expect(batch.rows[3].result?.id == untouched.id)
        // Try again after a crop keeps the crop: the row runs as it last ran.
        await harness.model.crop([selected[0]], to: .ratio(16, 9))
        #expect(await eventually { selected[0].result != nil && !batch.isRunning })
        #expect(harness.requests.requests.last?.crop?.aspectRatio == "16:9")
        #expect(harness.requests.requests.last?.format == .webp)
    }

    /// Y6: Retry All Failed runs the failed rows again, and only those: a stopped row stays
    /// stopped (its own Try again runs it).
    @Test func retryAllFailedRunsOnlyTheFailures() async throws {
        let harness = Harness()
        let (batch, _) = try await batch(harness)
        batch.rows[1].state = .failed("x")
        batch.rows[2].state = .cancelled
        #expect(batch.retriable.count == 1)
        let before = harness.requests.requests.count
        harness.model.retryFailed(batch)
        #expect(await eventually { !batch.isRunning })
        #expect(harness.requests.requests.count == before + 1)
        #expect(batch.failed == 0 && batch.cancelled == 1)
    }

    /// Y6: Optimise Again on a row whose backup is gone says why on the row, and runs nothing.
    @Test func optimiseAgainWithoutABackupSaysWhy() async throws {
        let harness = Harness()
        let (batch, restores) = try await batch(harness)
        let row = batch.rows[0]
        let backup = try #require(row.result?.backup)
        try FileManager.default.removeItem(at: backup)
        let before = harness.requests.requests.count
        await harness.model.rerun([row], compression: .aggressive)
        #expect(row.restoreError != nil, "the row says why")
        #expect(restores.backups.count == 1, "asked once, refused")
        #expect(harness.requests.requests.count == before)
    }

    /// An original back in place is not put back again, but one that changed since (optimised
    /// again here) is: the old result's Restore still works.
    @Test func anOldResultRestoresAfterANewOptimisation() async throws {
        let harness = Harness()
        let restores = Restores()
        harness.model.restoreBackup = { service, result in
            // The second put-back would send the new result to the real Trash: recorded only.
            guard restores.add(result.backup?.path ?? "") else {
                return try JSONDecoder().decode(RestoreOutcome.self, from: Data(#"{"restored":"","from":"","backupDeleted":false}"#.utf8))
            }
            return try await service.restoreBackup(of: result, deleteBackup: false)
        }
        let file = harness.temp.file("Again.png")
        _ = await harness.model.run(harness.job(file, origin: .app))
        let first = try #require(harness.model.cards.first?.result)
        #expect(await harness.model.restore(first))
        #expect(await harness.model.restore(first), "in place: nothing to do")
        #expect(restores.backups.count == 1)
        _ = await harness.model.run(harness.job(file, origin: .app))
        #expect(AppModel.size(of: file) == 40_000)
        #expect(await harness.model.restore(first))
        #expect(restores.backups.count == 2, "put back again, not skipped")
    }

    /// Y1: `esclop restore` (another process) put the original back; the card's Undo then only
    /// says restored. It used to put it back again and send the original to the Trash as an edit.
    @Test func anOriginalAnotherProcessPutBackIsNotPutBackAgain() async throws {
        let harness = Harness()
        let restores = Restores()
        harness.model.restoreBackup = { _, result in
            // Recorded only: a second put-back would send the original to the real Trash.
            _ = restores.add(result.backup?.path ?? "")
            return try JSONDecoder().decode(RestoreOutcome.self, from: Data(#"{"restored":"","from":"","backupDeleted":false,"movedToTrash":["x"]}"#.utf8))
        }
        let file = harness.temp.file("Elsewhere.png")
        _ = await harness.model.run(harness.job(file, origin: .app))
        let card = try #require(harness.model.cards.first)
        let result = try #require(card.result)
        let size = AppModel.size(of: file)
        // The CLI's restore: the same store, not through this app.
        _ = try await EsclopService(harness.model.service.context).restoreBackup(of: result, deleteBackup: false)
        #expect(AppModel.size(of: file) != size, "the original is back")
        #expect(await harness.model.restore(result))
        #expect(restores.backups.isEmpty, "not put back again")
        guard case .restored = card.phase else {
            Issue.record("the card says restored")
            return
        }
        #expect(!card.editInTrash)
    }

    /// A row the chosen size would not make smaller stays as it was: not restored, not run.
    @Test func aRowTheSizeDoesNotFitStaysOptimised() async throws {
        let harness = Harness()
        let (batch, restores) = try await batch(harness)
        let before = harness.requests.requests.count
        // The fake engine's files are no pictures: the card would offer no size for them.
        await harness.model.downscale(Array(batch.rows.prefix(2)), longSide: 2000)
        #expect(restores.backups.isEmpty)
        #expect(batch.optimised == 4)
        #expect(harness.requests.requests.count == before)
    }
}

/// Window renders, in a suite CI runs with the other renders (`--filter RenderTests`).
@MainActor
@Suite struct RestoreAndBatchRenderTests {
    /// B3/B4: two IMG_0001.jpg told apart by their folders, with thumbnails; two selected, with
    /// Restore and Remove for them; and the empty window with its one retention sentence. The
    /// batch window's selection renders with the others (`BatchRenderTests`).
    @Test func originalsRenders() async throws {
        let harness = Harness()
        harness.model.loadsThumbnails = true
        for name in ["Trips/IMG_0001.jpg", "Work/Receipts/IMG_0001.jpg", "Screenshot 2026-11-19 at 09.41.12.png"] {
            let file = harness.temp.file(name)
            let image = try #require(NSBitmapImageRep(data: pngData(width: 640, height: 480)))
            try #require(image.representation(using: name.hasSuffix(".jpg") ? .jpeg : .png, properties: [:])).write(to: file)
            _ = await harness.model.run(harness.job(file, origin: .app))
        }
        let originals = OriginalsModel(app: harness.model)
        await originals.load()
        #expect(originals.items.count == 3)
        try await SettingsRenderTests.renderBoth({ _ in OriginalsView(model: originals) }, size: CGSize(width: 520, height: 360), name: "originals", settle: .seconds(1))
        let two = Set(originals.items.prefix(2).map(\.id))
        try await SettingsRenderTests.renderBoth({ _ in OriginalsView(model: originals, selection: two) }, size: CGSize(width: 520, height: 360), name: "originals-selection", settle: .seconds(1))
        let empty = OriginalsModel(app: Harness().model)
        await empty.load()
        try await SettingsRenderTests.renderBoth({ _ in OriginalsView(model: empty) }, size: CGSize(width: 520, height: 360), name: "originals-empty")
    }
}
