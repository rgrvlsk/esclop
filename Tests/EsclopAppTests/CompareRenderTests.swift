// SPDX-License-Identifier: GPL-3.0-or-later
//
// The compare window in real windows: the split by default; side by side, flip with the
// difference overlay, a PDF page and the "original no longer kept" message with
// ESCLOP_RENDER_ALL=1. ESCLOP_LANGUAGE=ca draws them in Catalan. The stability cases change what
// the window shows while it is on screen, where a binding to something gone would trap.

import AppKit
import EsclopCore
@testable import EsclopAppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct CompareRenderTests {
    // Fits a CI runner's smaller screen (a window wider than the screen is clamped).
    static let size = CGSize(width: 960, height: 700)

    func model(_ harness: Harness, mode: CompareModel.Mode, result: OptimisationResult? = nil) async -> CompareModel {
        let compare = CompareModel(app: harness.model)
        compare.mode = mode
        compare.open(result ?? CompareFixtures.imageResult(in: harness.temp.url))
        await compare.load()
        return compare
    }

    @Test func split() async throws {
        let harness = Harness()
        let saved = UserDefaults.standard.string(forKey: CompareModel.modeKey)
        defer { UserDefaults.standard.set(saved, forKey: CompareModel.modeKey) }
        let compare = await model(harness, mode: .split)
        compare.viewport.split = 0.42
        let sizes = try await SettingsRenderTests.renderBoth({ _ in CompareView(model: compare) }, size: Self.size, name: "compare-split")
        #expect(sizes.allSatisfy { $0.width == Self.size.width })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ESCLOP_RENDER_ALL"] == "1"))
    func otherLayouts() async throws {
        let harness = Harness()
        let saved = UserDefaults.standard.string(forKey: CompareModel.modeKey)
        defer { UserDefaults.standard.set(saved, forKey: CompareModel.modeKey) }
        let side = await model(harness, mode: .sideBySide)
        side.viewport.zoom = 2
        side.viewport.pan = CGSize(width: 120, height: 40)
        try await SettingsRenderTests.renderBoth({ _ in CompareView(model: side) }, size: Self.size, name: "compare-side-by-side")
        let flip = await model(harness, mode: .flip)
        flip.showsDifference = true
        try await SettingsRenderTests.renderBoth({ _ in CompareView(model: flip) }, size: Self.size, name: "compare-flip-differences")
        let pdfBefore = harness.temp.url.appendingPathComponent("report.pdf"), pdfAfter = harness.temp.url.appendingPathComponent("report-small.pdf")
        CompareFixtures.pdf(at: pdfBefore, pages: 4)
        CompareFixtures.pdf(at: pdfAfter, pages: 4, shade: 0.4)
        let pdf = await model(harness, mode: .split, result: OptimisationResult(
            source: pdfBefore, output: pdfAfter, kind: .pdf, bytesBefore: 48000, bytesAfter: 21000, startedAt: Date(), finishedAt: Date()
        ))
        pdf.page = 1
        await pdf.load()
        try await SettingsRenderTests.renderBoth({ _ in CompareView(model: pdf) }, size: Self.size, name: "compare-pdf")
        let file = harness.temp.file("gone.png", bytes: 100_000)
        let report = await harness.model.run(harness.job(file))
        let result = try #require(report.results.first)
        try FileManager.default.removeItem(at: try #require(result.backup))
        let pruned = await model(harness, mode: .split, result: result)
        try await SettingsRenderTests.renderBoth({ _ in CompareView(model: pruned) }, size: CGSize(width: 820, height: 560), name: "compare-pruned")
    }
}

@MainActor
@Suite(.serialized) struct CompareStabilityRenderTests {
    @Test func whatTheWindowShowsChangesUnderIt() async throws {
        let harness = Harness()
        let saved = UserDefaults.standard.string(forKey: CompareModel.modeKey)
        defer { UserDefaults.standard.set(saved, forKey: CompareModel.modeKey) }
        let compare = CompareModel(app: harness.model)
        let image = CompareFixtures.imageResult(in: harness.temp.url)
        compare.open(image)
        let window = NSWindow(contentViewController: NSHostingController(rootView: CompareView(model: compare)))
        window.isReleasedWhenClosed = false
        window.setContentSize(CGSize(width: 1040, height: 760))
        window.orderFrontRegardless()
        defer { window.close() }
        func act(_ change: () async -> Void) async throws {
            await change()
            try await Task.sleep(for: .milliseconds(120))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        try await act { await compare.load() }
        // Every layout, zoomed and with the overlay, then back.
        for mode in CompareModel.Mode.allCases {
            try await act { compare.mode = mode }
            try await act { compare.viewport.zoom = 4; compare.showsDifference = true }
            try await act { compare.viewport.fit(); compare.showsDifference = false }
        }
        // Another file: a PDF, through its pages.
        let before = harness.temp.url.appendingPathComponent("doc.pdf"), after = harness.temp.url.appendingPathComponent("doc-small.pdf")
        CompareFixtures.pdf(at: before, pages: 2)
        CompareFixtures.pdf(at: after, pages: 2, shade: 0.4)
        try await act { compare.open(OptimisationResult(source: before, output: after, kind: .pdf, bytesBefore: 9, bytesAfter: 5, startedAt: Date(), finishedAt: Date())) }
        try await act { await compare.load() }
        try await act { compare.nextPage() }
        try await act { await compare.load() }
        // A result with a floating result: try another while open, then restore, then a pruned backup.
        let report = await harness.model.run(harness.job(harness.temp.file("a.png", bytes: 100_000)))
        let first = try #require(report.results.first)
        try await act { compare.open(first) }
        try await act { compare.tryAgain(with: OptimiseChoice()) }
        #expect(await eventually { compare.result.map { $0.id != first.id } ?? false })
        try await act { await compare.restore() }
        #expect(compare.sides == .restored)
        let second = await harness.model.run(harness.job(harness.temp.file("b.png", bytes: 100_000)))
        let pruned = try #require(second.results.first)
        try await act { compare.open(pruned) }
        try await act { try? FileManager.default.removeItem(at: pruned.backup!); compare.mode = .split }
        #expect(compare.sides == .pruned(after: pruned.output))
        // A link to a result the app no longer knows, while a comparison is on screen.
        try await act { #expect(!compare.open(id: UUID())) }
        #expect(compare.isUnknown && compare.result == nil)
        // Back to the image while everything above is gone.
        try await act { compare.open(image) }
        try await act { await compare.load() }
        #expect(compare.afterImage != nil)
    }
}
