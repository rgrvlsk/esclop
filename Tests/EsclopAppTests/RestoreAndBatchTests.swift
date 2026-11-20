// SPDX-License-Identifier: GPL-3.0-or-later
//
// One restore truth (HC-33): an original put back from one window is never put back again from
// another, which would send it to the Trash as an "edit"; Originals judges a result rebuilt after
// Recent › Clear by its real finish time, follows backups added while open and names what it
// could not remove; Clear forgets a finished batch; the batch window's selection runs again.

import AppKit
import EsclopCore
import EsclopIPC
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

        // An edit since (another size) matches no cleared line: the backup's time judges it.
        let other = harness.temp.file("Edited.png", bytes: 100_000)
        _ = await harness.model.run(harness.job(other, origin: .app))
        harness.model.clearRecent()
        try Data(repeating: 0x43, count: 12_345).write(to: other)
        let edited = try #require(store.entries().first { $0.original.lastPathComponent == "Edited.png" })
        let rebuilt = try #require(OriginalsModel.items([edited], log: harness.model.service.results).first)
        #expect(rebuilt.result.id == edited.id)
        #expect(rebuilt.result.finishedAt == edited.createdAt)
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

    /// B6: Retry All Failed runs every failed and stopped row again, and only those.
    @Test func retryAllFailedRunsOnlyTheFailures() async throws {
        let harness = Harness()
        let (batch, _) = try await batch(harness)
        batch.rows[1].state = .failed("x")
        batch.rows[2].state = .cancelled
        #expect(batch.retriable.count == 2)
        let before = harness.requests.requests.count
        harness.model.retryFailed(batch)
        #expect(await eventually { !batch.isRunning })
        #expect(harness.requests.requests.count == before + 2)
        #expect(batch.failed == 0 && batch.cancelled == 0)
    }

    // MARK: Renders (ESCLOP_RENDER_DIR keeps them; ESCLOP_LANGUAGE=ca for Catalan)

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
