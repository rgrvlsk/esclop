// SPDX-License-Identifier: GPL-3.0-or-later
//
// All Results (`pr6-results-window`): the week's results, once each, grouped by hour today and by
// day before; the search and the kinds; the counts; and the window in light and dark.

import AppKit
import EsclopCore
@testable import EsclopAppKit
import Foundation
import SwiftUI
import Testing

@MainActor @Suite struct AllResultsTests {
    let calendar = Calendar(identifier: .gregorian)
    /// A fixed Thursday, 14:30.
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 14, minute: 30))! }

    func result(_ name: String, from source: String? = nil, _ kind: MediaKind = .image, hoursAgo: Double) -> OptimisationResult {
        let date = now.addingTimeInterval(-hoursAgo * 3600)
        return OptimisationResult(
            source: URL(fileURLWithPath: "/tmp/\(source ?? name)"), output: URL(fileURLWithPath: "/tmp/\(name)"), kind: kind,
            bytesBefore: 2_000_000, bytesAfter: 500_000, startedAt: date, finishedAt: date
        )
    }

    @Test func theWeekHoldsEachResultOnceNewestFirst() {
        let today = result("a.png", hoursAgo: 1)
        let old = result("old.png", hoursAgo: 24 * 8)
        let week = AllResults.week([result("b.png", hoursAgo: 30), today, old, today], now: now, calendar: calendar)
        #expect(week.map(\.output.lastPathComponent) == ["a.png", "b.png"], "once each, newest first, nothing older than 7 days")
    }

    @Test func todayGroupsByHourAndEarlierDaysByDay() {
        let results = AllResults.week([
            result("a.png", hoursAgo: 0.2), result("b.png", hoursAgo: 0.4), result("c.png", hoursAgo: 3),
            result("d.png", hoursAgo: 20), result("e.png", hoursAgo: 50),
        ], now: now, calendar: calendar)
        let groups = AllResults.groups(results, now: now, calendar: calendar)
        #expect(groups.map(\.results.count) == [2, 1, 1, 1])
        #expect(groups[0].label == "14:00" && groups[1].label == "11:00")
        #expect(groups[2].label == Strings.text("Yesterday"))
    }

    @Test func searchAndKindsNarrowTheList() {
        let results = [result("Beach Café.png", hoursAgo: 1), result("Report.pdf", .pdf, hoursAgo: 1), result("Holiday.mov", .video, hoursAgo: 1)]
        #expect(AllResults.filter(results, kind: nil, query: "cafe").map(\.output.lastPathComponent) == ["Beach Café.png"], "accents and case fold")
        #expect(AllResults.filter(results, kind: .pdf, query: "").count == 1)
        #expect(AllResults.filter(results, kind: nil, query: "").count == 3)
    }

    @Test func aConvertedResultChangedFormat() {
        #expect(AllResults.converted([result("a.webp", from: "a.png", hoursAgo: 1), result("b.png", hoursAgo: 1)]) == 1)
        #expect(AllResults.filesCount(1) == Strings.text("1 file"))
    }
}

@MainActor @Suite(.serialized) struct AllResultsRenderTests {
    /// Results today and on earlier days, and one failure still on screen.
    @Test(arguments: [ColorScheme.light, .dark])
    func theWindow(scheme: ColorScheme) async throws {
        let harness = Harness(failure: .toolMissing("ffmpeg"))
        _ = await harness.model.run(harness.job(harness.temp.file("Notes.mov")))
        let now = Date()
        let names = [("Beach.jpg", 0.2, 2_400_000, 612_000), ("Report.pdf", 0.6, 8_100_000, 5_000_000), ("Lake.png", 3.0, 8_100_000, 3_100_000), ("Holiday.mov", 26.0, 24_000_000, 6_100_000)]
        for (name, hoursAgo, before, after) in names {
            let date = now.addingTimeInterval(-hoursAgo * 3600)
            let file = harness.temp.file(name, bytes: 1000)
            let kind: MediaKind = name.hasSuffix(".pdf") ? .pdf : name.hasSuffix(".mov") ? .video : .image
            harness.model.record(OptimisationResult(source: file, output: file, kind: kind, bytesBefore: before, bytesAfter: after, startedAt: date, finishedAt: date))
        }
        try await SettingsRenderTests.renderWindow(AllResultsView(model: harness.model) { now }, size: CGSize(width: 640, height: 720), name: "all-results", scheme: scheme, settle: .milliseconds(900))
        try await SettingsRenderTests.renderWindow(AllResultsView(model: Harness().model), size: CGSize(width: 640, height: 520), name: "all-results-empty", scheme: scheme)
    }
}
