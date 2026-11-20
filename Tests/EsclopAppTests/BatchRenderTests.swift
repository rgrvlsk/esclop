// SPDX-License-Identifier: GPL-3.0-or-later
//
// Renders the batch window's content, running and finished, light and dark, in a window: its
// rows are a native list, which draws only there. Set ESCLOP_RENDER_DIR to keep the PNGs.

import AppKit
import EsclopCore
@testable import EsclopAppKit
import SwiftUI
import Testing

@MainActor
@Suite struct BatchRenderTests {
    /// A backup that exists, so Restore shows as it would.
    static let backup: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("esclop-render-backup")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }()

    func result(_ name: String, before: Int, after: Int) -> OptimisationResult {
        let url = URL(fileURLWithPath: "/tmp/Holiday/\(name)")
        return OptimisationResult(
            source: url, output: url, backup: Self.backup, kind: MediaKind.of(url) ?? .image,
            bytesBefore: before, bytesAfter: after, startedAt: Date(), finishedAt: Date()
        )
    }

    func batch(running: Bool) -> Batch {
        let batch = Batch(origin: .dropZone)
        let done: [(String, Int, Int)] = [
            ("Beach 01.jpg", 4_812_000, 1_204_000), ("Beach 02.jpg", 5_130_000, 1_366_000), ("Harbour.heic", 3_204_000, 1_960_000),
            ("Menu scan.pdf", 12_800_000, 3_100_000), ("Screenshot 2026-11-05 at 10.42.png", 2_448_000, 612_000),
        ]
        for (name, before, after) in done {
            batch.add(URL(fileURLWithPath: "/tmp/Holiday/\(name)"), bytes: before).state = .done(result(name, before: before, after: after))
        }
        batch.add(URL(fileURLWithPath: "/tmp/Holiday/Map.png"), bytes: 180_000).state = .unchanged
        if running {
            batch.add(URL(fileURLWithPath: "/tmp/Holiday/Sunset walk.mov"), bytes: 84_000_000).state = .working(0.42)
            batch.add(URL(fileURLWithPath: "/tmp/Holiday/Voice note.m4a"), bytes: 6_200_000)
            batch.add(URL(fileURLWithPath: "/tmp/Holiday/Ferry.jpg"), bytes: 3_900_000)
        } else {
            batch.add(URL(fileURLWithPath: "/tmp/Holiday/Broken.mov"), bytes: 1_000_000).state = .failed("ffmpeg stopped with code 1: Invalid data found when processing input")
        }
        return batch
    }

    /// In a window: the rows are a native list, which draws only there.
    func render(_ batch: Batch, _ app: AppModel, height: CGFloat = 520, selection: Set<BatchRow.ID> = [], name: String) async throws {
        try await SettingsRenderTests.renderBoth({ _ in BatchView(batch: batch, app: app, selection: selection) }, size: CGSize(width: 560, height: height), name: name)
    }

    @Test func batchWindow() async throws {
        let harness = Harness()
        try await render(batch(running: true), harness.model, height: 560, name: "batch-running")
        let paused = batch(running: true)
        paused.pause()
        let pausedInfo = BatchPresentation(batch: paused, locale: Locale(identifier: "en"))
        #expect(pausedInfo.title == "Paused at 6 of 9 files")
        let done = BatchPresentation(batch: batch(running: false), locale: Locale(identifier: "en"))
        #expect(done.title == "5 of 7 files optimised")
        #expect(done.counts == "5 optimised · 1 already optimised · 1 failed")
        let restored = batch(running: false)
        for row in restored.rows { if let result = row.result { row.state = .restored(result) } else { row.state = .cancelled } }
        try await render(restored, harness.model, height: 420, name: "batch-restored")
        try await render(batch(running: false), harness.model, name: "batch-finished")
        // A Restore that failed: the row keeps its saving and says why.
        let failedRestore = batch(running: false)
        failedRestore.rows[0].restoreError = CardPresentation.message(for: EsclopError.backupRemoved(file: "/tmp/Holiday/Beach 01.jpg", afterDays: 7))
        try await render(failedRestore, harness.model, name: "batch-restore-failed")
        // Automatic uploads: each row says how its upload goes, the saving stays in the figure.
        let uploading = batch(running: false)
        uploading.rows[0].upload = .uploaded(URL(string: "https://files.example.com/Beach%2001.jpg")!)
        uploading.rows[1].upload = .uploading(fraction: 0.4)
        uploading.rows[2].upload = .failed(Strings.text("The upload target did not answer."))
        try await render(uploading, harness.model, name: "batch-uploads")
        // Three rows selected for the context menu's actions, and Retry All Failed (HC-33).
        let selected = batch(running: false)
        try await render(selected, harness.model, selection: Set(selected.rows.prefix(3).map(\.id)), name: "batch-selection")
    }
}
