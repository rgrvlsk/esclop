// SPDX-License-Identifier: GPL-3.0-or-later
//
// All Results (`pr6-results-window`): the week's results, once each, grouped by hour today and by
// day before; the search and the kinds; the counts; and the window in light and dark.

import AppKit
import EsclopCore
@testable import EsclopAppKit
import Foundation
import ImageIO
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
        let hour = { (h: Int) in self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: h))!.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: Strings.locale, calendar: self.calendar)) }
        #expect(groups[0].label == hour(14) && groups[1].label == hour(11), "the hour in the Mac's own time format")
        #expect(groups[2].label == Strings.text("Yesterday"))
        let rows = AllResults.rows(results, now: now, calendar: calendar)
        #expect(rows.map(\.label) == [hour(14), nil, hour(11), Strings.text("Yesterday"), rows[4].label], "the label on each group's first row only")
        #expect(rows[4].label != nil)
    }

    @Test func searchAndKindsNarrowTheList() {
        let results = [result("Beach Café.png", hoursAgo: 1), result("Report.pdf", .pdf, hoursAgo: 1), result("Holiday.mov", .video, hoursAgo: 1)]
        #expect(AllResults.filter(results, kind: nil, query: "cafe").map(\.output.lastPathComponent) == ["Beach Café.png"], "accents and case fold")
        #expect(AllResults.filter(results, kind: .pdf, query: "").count == 1)
        #expect(AllResults.filter(results, kind: nil, query: "").count == 3)
        #expect(!AllResults.matches(name: "Notes.mov", kind: .video, filter: .pdf, query: ""), "a failure follows the kind too")
        #expect(AllResults.matches(name: "Notes.mov", kind: .video, filter: nil, query: "note"))
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
        // A Friday afternoon: two results in one hour, one earlier today, yesterday, and the
        // longest weekday name, Wednesday.
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 14, minute: 40))!
        let names = [("Beach.jpg", 0.2, 2_400_000, 612_000), ("Report.pdf", 0.5, 8_100_000, 5_000_000), ("Lake.png", 3.0, 8_100_000, 3_100_000), ("Holiday.mov", 26.0, 24_000_000, 6_100_000), ("Minutes.pdf", 50.0, 3_200_000, 1_400_000)]
        for (name, hoursAgo, before, after) in names {
            let date = now.addingTimeInterval(-hoursAgo * 3600)
            let file = harness.temp.file(name, bytes: 1000)
            // Real pictures and a real page, so the rows show thumbnails as they would.
            if name.hasSuffix(".jpg") || name.hasSuffix(".png") { try Self.writeLandscape(to: file, mountains: name.hasPrefix("Lake")) }
            if name.hasSuffix(".pdf") { Self.writePage(to: file) }
            // The beach was converted to HEIC: it can be compared, so its "…" shows.
            if name == "Beach.jpg" {
                let webp = harness.temp.file("Beach.heic", bytes: 1000)
                try Self.writeLandscape(to: webp, mountains: false)
                harness.model.record(OptimisationResult(source: file, output: webp, kind: kind(name), bytesBefore: before, bytesAfter: after, startedAt: date, finishedAt: date))
                continue
            }
            harness.model.record(OptimisationResult(source: file, output: file, kind: kind(name), bytesBefore: before, bytesAfter: after, startedAt: date, finishedAt: date))
        }
        try await SettingsRenderTests.renderWindow(AllResultsView(model: harness.model) { now }, size: CGSize(width: 860, height: 840), name: "all-results", scheme: scheme, settle: .milliseconds(900), warm: true)
        // The first result under the pointer: Copy, Show in Finder and the menu.
        let first = try #require(harness.model.recent.max { $0.finishedAt < $1.finishedAt })
        try await SettingsRenderTests.renderWindow(AllResultsView(model: harness.model, now: { now }, hovered: first.id), size: CGSize(width: 860, height: 520), name: "all-results-hover", scheme: scheme, settle: .milliseconds(900), warm: true)
        try await SettingsRenderTests.renderWindow(AllResultsView(model: Harness().model), size: CGSize(width: 860, height: 520), name: "all-results-empty", scheme: scheme, warm: true)
        // The arrow keys on a result, and a search that finds nothing.
        try await SettingsRenderTests.renderWindow(AllResultsView(model: harness.model, now: { now }, ringed: first.id), size: CGSize(width: 860, height: 520), name: "all-results-keys", scheme: scheme, settle: .milliseconds(900), warm: true)
        try await SettingsRenderTests.renderWindow(AllResultsView(model: harness.model, now: { now }, initialQuery: "zebra"), size: CGSize(width: 860, height: 520), name: "all-results-no-match", scheme: scheme, settle: .milliseconds(600), warm: true)
        // The narrowest window: the header on two rows, every count at one size.
        try await SettingsRenderTests.renderWindow(AllResultsView(model: harness.model) { now }, size: CGSize(width: 720, height: 640), name: "all-results-narrow", scheme: scheme, settle: .milliseconds(900), warm: true)
    }

    func kind(_ name: String) -> MediaKind { name.hasSuffix(".pdf") ? .pdf : name.hasSuffix(".mov") ? .video : .image }

    /// A small landscape: sky, sea or a mountain, sand.
    static func writeLandscape(to url: URL, mountains: Bool) throws {
        let width = 320, height = 220
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bands: [(CGFloat, CGFloat, CGColor)] = mountains
            ? [(0, 0.45, CGColor(srgbRed: 0.20, green: 0.45, blue: 0.40, alpha: 1)), (0.45, 0.7, CGColor(srgbRed: 0.55, green: 0.6, blue: 0.65, alpha: 1)), (0.7, 1, CGColor(srgbRed: 0.55, green: 0.75, blue: 0.95, alpha: 1))]
            : [(0, 0.3, CGColor(srgbRed: 0.93, green: 0.85, blue: 0.68, alpha: 1)), (0.3, 0.62, CGColor(srgbRed: 0.10, green: 0.62, blue: 0.70, alpha: 1)), (0.62, 1, CGColor(srgbRed: 0.45, green: 0.72, blue: 0.95, alpha: 1))]
        for (low, high, color) in bands {
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: CGFloat(height) * low, width: CGFloat(width), height: CGFloat(height) * (high - low)))
        }
        let image = try #require(context.makeImage())
        let type = url.pathExtension == "png" ? "public.png" : url.pathExtension == "heic" ? "public.heic" : "public.jpeg"
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// A one-page PDF with a title and lines of text.
    static func writePage(to url: URL) {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.15, alpha: 1))
        context.fill(CGRect(x: 60, y: 740, width: 260, height: 22))
        context.setFillColor(CGColor(gray: 0.55, alpha: 1))
        for line in 0 ..< 22 { context.fill(CGRect(x: 60, y: 690 - line * 26, width: line % 5 == 4 ? 300 : 470, height: 9)) }
        context.endPDFPage()
        context.closePDF()
    }
}
