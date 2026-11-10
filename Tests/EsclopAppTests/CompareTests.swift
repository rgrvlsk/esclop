// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EsclopCore
import EsclopIPC
@testable import EsclopAppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Pictures with something to look at: shapes, a gradient and text, so compression shows.
enum CompareFixtures {
    static func picture(width: Int = 640, height: Int = 420) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let colors = [CGColor(red: 0.12, green: 0.5, blue: 0.42, alpha: 1), CGColor(red: 0.95, green: 0.78, blue: 0.4, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        context.setFillColor(CGColor(red: 0.95, green: 0.96, blue: 0.95, alpha: 1))
        context.fillEllipse(in: CGRect(x: width / 8, y: height / 5, width: width / 3, height: width / 3))
        context.setStrokeColor(CGColor(red: 0.1, green: 0.12, blue: 0.12, alpha: 1))
        context.setLineWidth(3)
        for i in 0 ..< 12 {
            let x = CGFloat(width / 2 + i * 20)
            context.move(to: CGPoint(x: x, y: 40))
            context.addLine(to: CGPoint(x: x + 60, y: CGFloat(height - 40)))
        }
        context.strokePath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: "L’Esclop 75 %", attributes: [.font: NSFont.systemFont(ofSize: 42, weight: .bold), .foregroundColor: NSColor.black])
            .draw(at: CGPoint(x: 30, y: 30))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    static func write(_ image: CGImage, to url: URL, type: UTType, quality: Double = 1) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    /// A PDF of `pages` pages, each with its number drawn large.
    static func pdf(at url: URL, pages: Int, shade: CGFloat = 0.2) {
        var box = CGRect(x: 0, y: 0, width: 400, height: 520)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for page in 1 ... pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: shade, alpha: 1))
            context.fill(CGRect(x: 40, y: 40, width: 320, height: 60))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSAttributedString(string: "Page \(page)", attributes: [.font: NSFont.systemFont(ofSize: 64, weight: .heavy)]).draw(at: CGPoint(x: 60, y: 300))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// An original PNG and its JPEG at low quality, as a result that went next to the original.
    static func imageResult(in folder: URL, name: String = "shot") -> OptimisationResult {
        let before = folder.appendingPathComponent("\(name).png")
        let after = folder.appendingPathComponent("\(name).jpg")
        let image = picture()
        write(image, to: before, type: .png)
        write(image, to: after, type: .jpeg, quality: 0.15)
        return OptimisationResult(
            source: before, output: after, kind: .image, bytesBefore: AppModel.size(of: before), bytesAfter: AppModel.size(of: after),
            width: image.width, height: image.height, startedAt: Date(), finishedAt: Date()
        )
    }
}

@Suite struct CompareSidesTests {
    let source = URL(fileURLWithPath: "/w/a.png")
    let backup = URL(fileURLWithPath: "/backups/a.png")

    func result(output: URL? = nil, backup: URL? = nil) -> OptimisationResult {
        OptimisationResult(source: source, output: output ?? source, backup: backup, kind: .image, bytesBefore: 10, bytesAfter: 5, startedAt: Date(), finishedAt: Date())
    }

    @Test func theBackupIsTheOriginalForAResultWrittenInPlace() {
        let sides = CompareSides.resolve(result(backup: backup), restored: false) { _ in true }
        #expect(sides == .ready(before: backup, after: source))
    }

    @Test func theOriginalItselfForAResultNextToIt() {
        let next = URL(fileURLWithPath: "/w/a.webp")
        #expect(CompareSides.resolve(result(output: next), restored: false) { _ in true } == .ready(before: source, after: next))
    }

    @Test func aPrunedBackupIsSaidPlainly() {
        let sides = CompareSides.resolve(result(backup: backup), restored: false) { $0 != backup }
        #expect(sides == .pruned(after: source))
        #expect(sides.before == nil && sides.after == source)
    }

    @Test func undoneAndGone() {
        #expect(CompareSides.resolve(result(backup: backup), restored: true) { _ in true } == .restored)
        #expect(CompareSides.resolve(result(backup: backup), restored: false) { _ in false } == .gone)
    }
}

@Suite struct CompareViewportTests {
    let pixels = CGSize(width: 2000, height: 1000)
    let viewport = CGSize(width: 1000, height: 800)

    @Test func fitAndOneHundredPercent() {
        var view = CompareViewport()
        #expect(view.scale(pixels: pixels, in: viewport, displayScale: 2) == 0.5, "fit: 2000 px into 1000 pt")
        #expect(view.label(pixels: pixels, in: viewport, displayScale: 2) == "Fit")
        view.zoom = 1
        #expect(view.scale(pixels: pixels, in: viewport, displayScale: 2) == 0.5, "100 % on a Retina screen: one pixel per screen pixel")
        #expect(view.label(pixels: pixels, in: viewport, displayScale: 2) == "100\u{00A0}%")
        view.zoom = 4
        #expect(view.scale(pixels: pixels, in: viewport, displayScale: 1) == 4)
    }

    @Test func zoomStepsAndBackToFit() {
        var view = CompareViewport()
        view.zoomIn(pixels: pixels, in: viewport, displayScale: 1)
        #expect(view.zoom == 1, "from fit (50 %) to 100 %")
        view.zoomIn(pixels: pixels, in: viewport, displayScale: 1)
        #expect(view.zoom == 2)
        view.zoomOut(pixels: pixels, in: viewport, displayScale: 1)
        #expect(view.zoom == 1)
        view.zoomOut(pixels: pixels, in: viewport, displayScale: 1)
        #expect(view.zoom == nil, "below 100 % it fits again")
        for _ in 0 ..< 10 { view.zoomIn(pixels: pixels, in: viewport, displayScale: 1) }
        #expect(view.zoom == 8, "8× at most")
    }

    @Test func panStopsAtTheEdgesAndTheDividerStaysGrabbable() {
        var view = CompareViewport(zoom: 1)
        // 2000 × 1000 points in a 1000 × 800 viewport: 500 and 100 of slack each way.
        #expect(view.clamped(CGSize(width: 900, height: -400), pixels: pixels, in: viewport, displayScale: 1) == CGSize(width: 500, height: -100))
        view.zoom = nil
        #expect(view.clamped(CGSize(width: 50, height: 50), pixels: pixels, in: viewport, displayScale: 1) == .zero, "at fit there is nothing to pan")
        #expect(CompareViewport.split(at: -20, width: 1000) == 0.02)
        #expect(CompareViewport.split(at: 2000, width: 1000) == 0.98)
        #expect(CompareViewport.split(at: 250, width: 1000) == 0.25)
    }
}

@Suite struct CompareMediaTests {
    @Test func theDifferenceIsZeroForTheSamePictureAndMarksWhatChanged() throws {
        let picture = CompareFixtures.picture()
        let same = try #require(CompareMedia.difference(picture, picture))
        #expect(same.changed == 0)
        let temp = TempDir()
        let jpeg = temp.url.appendingPathComponent("low.jpg")
        CompareFixtures.write(picture, to: jpeg, type: .jpeg, quality: 0.1)
        let lossy = try #require(CompareMedia.image(at: jpeg))
        let different = try #require(CompareMedia.difference(picture, lossy))
        #expect(different.changed > 0.001, "JPEG at 10 % leaves artefacts: \(different.changed)")
        #expect(different.mask.width == picture.width && different.mask.height == picture.height)
    }

    @Test func aSmallerOptimisedPictureIsComparedAtTheOriginalsSize() throws {
        let picture = CompareFixtures.picture()
        let small = CompareFixtures.picture(width: 320, height: 210)
        let difference = try #require(CompareMedia.difference(picture, small))
        #expect(difference.mask.width == 640 && difference.mask.height == 420)
        #expect(difference.changed < 0.5, "a downscale differs at edges, not everywhere: \(difference.changed)")
    }

    @Test func pdfPagesAreDrawnFromTheirMediaBox() throws {
        let temp = TempDir()
        let url = temp.url.appendingPathComponent("doc.pdf")
        CompareFixtures.pdf(at: url, pages: 3)
        #expect(CompareMedia.pageCount(of: url) == 3)
        let page = try #require(CompareMedia.page(1, of: url, longEdge: 1040))
        #expect(page.height == 1040 && page.width == 800)
        #expect(CompareMedia.page(5, of: url) == nil)
    }
}

@MainActor @Suite struct CompareModelTests {
    @Test func opensFromTheResultAndLoadsBothSides() async throws {
        let harness = Harness()
        let result = CompareFixtures.imageResult(in: harness.temp.url)
        let compare = CompareModel(app: harness.model)
        compare.open(result)
        #expect(compare.sides == .ready(before: result.source, after: result.output))
        await compare.load()
        #expect(compare.beforeImage?.width == 640 && compare.afterImage?.width == 640)
        #expect((compare.difference?.changed ?? 0) > 0)
        #expect(compare.pixels == CGSize(width: 640, height: 420))
    }

    @Test func opensByIdFromTheRecentResultsAndLinks() throws {
        let harness = Harness()
        let result = CompareFixtures.imageResult(in: harness.temp.url)
        harness.model.record(result)
        let compare = CompareModel(app: harness.model)
        #expect(compare.open(id: result.id))
        #expect(compare.result?.id == result.id)
        #expect(!compare.open(id: UUID()))
        #expect(CompareWindowController.route(URL(string: "esclop://compare/\(result.id.uuidString)")!) == result.id)
        #expect(CompareWindowController.route(URL(string: "esclop://compare/nope")!) == nil)
        #expect(CompareWindowController.route(URL(string: "esclop://pipelines/x")!) == nil)
    }

    @Test func aPrunedBackupStillOpensAndSaysSo() async throws {
        let harness = Harness()
        let file = harness.temp.file("a.png", bytes: 100_000)
        let report = await harness.model.run(harness.job(file))
        let result = try #require(report.results.first)
        let backup = try #require(result.backup)
        let compare = CompareModel(app: harness.model)
        compare.open(result)
        #expect(compare.sides == .ready(before: backup, after: result.output))
        try FileManager.default.removeItem(at: backup)
        #expect(compare.sides == .pruned(after: result.output))
    }

    @Test func restoreFromTheWindow() async throws {
        let harness = Harness()
        let report = await harness.model.run(harness.job(harness.temp.file("a.png", bytes: 100_000)))
        let result = try #require(report.results.first)
        let compare = CompareModel(app: harness.model)
        compare.open(result)
        await compare.restore()
        #expect(compare.sides == .restored)
        #expect(AppModel.size(of: result.source) == 100_000, "the original is back")
    }

    @Test func tryAnotherFollowsTheNewResult() async throws {
        let harness = Harness()
        let report = await harness.model.run(harness.job(harness.temp.file("a.png", bytes: 100_000)))
        let first = try #require(report.results.first)
        let compare = CompareModel(app: harness.model)
        compare.open(first)
        var choice = compare.choice
        choice.compression = .aggressive
        compare.tryAgain(with: choice)
        #expect(await eventually { compare.result.map { $0.id != first.id } ?? false })
        #expect(compare.sides.before != nil, "the new result has its own backup")
        #expect(harness.requests.requests.last?.quality == OptimiseChoice.Compression.aggressive.quality)
    }

    @Test func keepDismissesTheResultAndCloses() async throws {
        let harness = Harness()
        let report = await harness.model.run(harness.job(harness.temp.file("a.png", bytes: 100_000)))
        let result = try #require(report.results.first)
        let compare = CompareModel(app: harness.model)
        var closed = false
        compare.onClose = { closed = true }
        compare.open(result)
        compare.keep()
        #expect(closed)
        #expect(!harness.model.cards.contains { $0.result?.id == result.id })
    }

    @Test func theLayoutIsRemembered() {
        let harness = Harness()
        let saved = UserDefaults.standard.string(forKey: CompareModel.modeKey)
        defer { UserDefaults.standard.set(saved, forKey: CompareModel.modeKey) }
        CompareModel(app: harness.model).mode = .flip
        #expect(CompareModel(app: harness.model).mode == .flip)
    }

    @Test func pdfPagesStayInStep() async throws {
        let harness = Harness()
        let before = harness.temp.url.appendingPathComponent("doc.pdf")
        let after = harness.temp.url.appendingPathComponent("doc-small.pdf")
        CompareFixtures.pdf(at: before, pages: 3)
        CompareFixtures.pdf(at: after, pages: 3, shade: 0.35)
        let result = OptimisationResult(source: before, output: after, kind: .pdf, bytesBefore: 2000, bytesAfter: 1000, startedAt: Date(), finishedAt: Date())
        let compare = CompareModel(app: harness.model)
        compare.open(result)
        await compare.load()
        #expect(compare.pageCount == 3)
        compare.nextPage()
        await compare.load()
        #expect(compare.page == 1 && compare.beforeImage != nil && compare.afterImage != nil)
        compare.nextPage()
        compare.nextPage()
        #expect(compare.page == 2, "not past the last page")
        compare.previousPage()
        #expect(compare.page == 1)
    }
}
