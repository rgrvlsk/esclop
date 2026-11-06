// SPDX-License-Identifier: GPL-3.0-or-later
//
// Renders the batch window's content, running and finished, light and dark, through the same
// NSHostingView snapshot as the options popover (AppKit buttons and the scroll view draw there,
// not in ImageRenderer). Set ESCLOP_RENDER_DIR to keep the PNGs.

import AppKit
import EsclopCore
@testable import EsclopAppKit
import SwiftUI
import Testing

@MainActor
@Suite struct BatchRenderTests {
    let snapshots = OptionsRenderTests()

    func result(_ name: String, before: Int, after: Int) -> OptimisationResult {
        let url = URL(fileURLWithPath: "/tmp/Holiday/\(name)")
        return OptimisationResult(
            source: url, output: url, backup: URL(fileURLWithPath: "/tmp/backup"), kind: MediaKind.of(url) ?? .image,
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

    @Test(arguments: [ColorScheme.light, .dark])
    func batchWindow(scheme: ColorScheme) async throws {
        let harness = Harness()
        let running = BatchView(batch: batch(running: true), app: harness.model).frame(width: 560, height: 560)
        try await snapshots.snapshot(running, name: "batch-running", scheme: scheme)
        let paused = batch(running: true)
        paused.pause()
        let pausedInfo = BatchPresentation(batch: paused, locale: Locale(identifier: "en"))
        #expect(pausedInfo.title == "Paused at 6 of 9 files")
        let done = BatchPresentation(batch: batch(running: false), locale: Locale(identifier: "en"))
        #expect(done.title == "5 of 7 files optimised")
        #expect(done.counts == "5 optimised · 1 already optimised · 1 failed")
        let finished = BatchView(batch: batch(running: false), app: harness.model).frame(width: 560, height: 520)
        try await snapshots.snapshot(finished, name: "batch-finished", scheme: scheme)
    }
}
