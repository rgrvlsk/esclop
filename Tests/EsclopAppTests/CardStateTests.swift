// SPDX-License-Identifier: GPL-3.0-or-later
//
// The floating results keep their state and their reach: a recent result comes back to the
// front with its own actions, an open detail stays open while its file changes in place, a file
// at work never loses its Stop, and what a card no longer stands for goes with it.

import AppKit
import EsclopCore
@testable import EsclopAppKit
import Foundation
import Testing

@MainActor
@Suite struct CardStateTests {
    @Test func recentBringsAHiddenCardToTheFront() async throws {
        let harness = Harness()
        var results: [OptimisationResult] = []
        for name in ["a", "b", "c", "d"] {
            let report = await harness.model.run(harness.job(harness.temp.file("\(name).png", bytes: 100_000)))
            results += report.results
        }
        let first = try #require(harness.model.cards.first)
        #expect(!harness.model.visibleCards.contains { $0.id == first.id }, "behind three newer ones")
        harness.model.show(results[0])
        #expect(harness.model.cards.count == 4, "the same card, not a twin")
        #expect(harness.model.visibleCards.last?.id == first.id, "it comes to the front")
    }

    @Test func aCopiedImageComesBackFromRecentAsOne() throws {
        let harness = Harness()
        let file = Paths.temporary.appendingPathComponent("clipboard/\(UUID().uuidString).png")
        let result = OptimisationResult(source: file, output: file, kind: .image, bytesBefore: 2_000, bytesAfter: 1_000, startedAt: Date(), finishedAt: Date())
        harness.model.show(result)
        let card = try #require(harness.model.cards.last)
        #expect(card.origin == .clipboard)
        #expect(card.presentation.tools.first == .copy, "Copy, not Show in Finder")
        #expect(card.presentation.fileName == "Copied image")
    }

    @Test func anOpenDetailStaysOpenWhileItsFileRunsAgain() async throws {
        let harness = Harness()
        _ = await harness.model.run(harness.job(harness.temp.file("a.jpg", bytes: 100_000)))
        let card = try #require(harness.model.cards.first)
        let first = try #require(card.result)
        harness.model.interact(card, .openDetail)
        // The metadata strip's Restore: back to the original, then run again keeping it.
        harness.model.perform(.keepMetadata, on: card)
        #expect(await eventually { card.result.map { $0.id != first.id } ?? false })
        #expect(card.machine.level == .detail, "the detail says it stays")
        // Undo is the one change that goes back to the card.
        harness.model.perform(.undo, on: card)
        #expect(await eventually { if case .restored = card.phase { card.machine.level == .thumbnail } else { false } })
    }

    @Test func aSavedCopyGoesWithTheResultItWasSavedFrom() async throws {
        let harness = Harness()
        let downloads = harness.temp.url.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        harness.model.downloads = { downloads }
        _ = await harness.model.run(harness.job(harness.temp.file("Clipboard.png", bytes: 100_000), origin: .clipboard), displayName: "Copied image")
        let card = try #require(harness.model.cards.first)
        harness.model.perform(.save, on: card)
        #expect(card.savedCopy != nil)
        let first = try #require(card.result)
        harness.model.reprocess(card)
        #expect(await eventually { card.result.map { $0.id != first.id } ?? false })
        #expect(card.savedCopy == nil)
        #expect(card.presentation.secondary.first == .save, "the new result needs its own Save")
    }

    @Test func aWorkingCardIsNeverHidden() async throws {
        let harness = Harness()
        let working = ResultCard(jobID: UUID(), source: harness.temp.file("big.mov", bytes: 10), origin: .dropZone, bytesBefore: 10)
        harness.model.add(working)
        for name in ["a", "b", "c"] {
            _ = await harness.model.run(harness.job(harness.temp.file("\(name).png", bytes: 100_000)))
        }
        #expect(harness.model.visibleCards.first?.id == working.id, "it keeps its place and its Stop")
        #expect(harness.model.visibleCards.count == 3, "still three places")
        // Its result arrives behind the newer ones: it comes to the front, never unseen.
        working.phase = .unchanged(bytes: 10)
        harness.model.settle(working)
        #expect(harness.model.visibleCards.last?.id == working.id)
        #expect(harness.model.visibleCards.count == 3)
    }

    @Test func aLoneFailureBehindNewerResultsComesToTheFront() async throws {
        let harness = Harness()
        let working = ResultCard(jobID: UUID(), source: harness.temp.file("big.mov", bytes: 10), origin: .dropZone, bytesBefore: 10)
        harness.model.add(working)
        for name in ["a", "b", "c"] {
            _ = await harness.model.run(harness.job(harness.temp.file("\(name).png", bytes: 100_000)))
        }
        working.phase = .failed("x")
        harness.model.settle(working)
        #expect(harness.model.visibleCards.last?.id == working.id, "a failure never arrives unseen")
    }

    @Test func neverMoreThanThreePlacesWhileFilesWork() {
        let harness = Harness()
        let working = (0..<4).map { index in
            ResultCard(jobID: UUID(), source: harness.temp.file("\(index).mov", bytes: 10), origin: .dropZone, bytesBefore: 10)
        }
        working.forEach(harness.model.add)
        #expect(harness.model.visibleCards.map(\.id) == working.suffix(3).map(\.id))
    }

    @Test func recentShowsARestoredCardInsteadOfATwin() async throws {
        let harness = Harness()
        let report = await harness.model.run(harness.job(harness.temp.file("a.png", bytes: 100_000)))
        let result = try #require(report.results.first)
        await harness.model.restore(result)
        harness.model.show(result)
        #expect(harness.model.cards.count == 1)
    }

    @Test func dismissStopsTheUpload() async throws {
        let harness = Harness()
        _ = await harness.model.run(harness.job(harness.temp.file("a.png", bytes: 100_000)))
        let card = try #require(harness.model.cards.first)
        let upload = Task<Void, Never> { try? await Task.sleep(for: .seconds(600)) }
        card.uploadTask = upload
        card.upload = .uploading(fraction: 0.3)
        harness.model.dismiss(card)
        #expect(upload.isCancelled)
    }

    @Test func tryAnotherWithoutItsCardKeepsTheFormatItMade() throws {
        let harness = Harness()
        let source = harness.temp.file("a.png", bytes: 100)
        let output = harness.temp.file("a.webp", bytes: 50)
        let result = OptimisationResult(source: source, output: output, kind: .image, bytesBefore: 100, bytesAfter: 50, startedAt: Date(), finishedAt: Date())
        let compare = CompareModel(app: harness.model)
        compare.open(result)
        #expect(compare.choice.format == .webp, "Lossless on a WebP result stays WebP")
        let same = OptimisationResult(source: source, output: source, kind: .image, bytesBefore: 100, bytesAfter: 50, startedAt: Date(), finishedAt: Date())
        compare.open(same)
        #expect(compare.choice.format == nil)
    }

    /// Clop re-runs its steps: a crop and a scale stay through another choice until Reset or
    /// Original take them off.
    @Test func aCropAndAScaleStayThroughAnotherChoice() async throws {
        let harness = Harness()
        _ = await harness.model.run(harness.job(harness.temp.file("a.png", bytes: 100_000)))
        let card = try #require(harness.model.cards.first)
        let rect = CropRect(x: 0, y: 0, width: 16, height: 9)
        func runs(_ count: Int, _ change: () -> Void) async throws -> OptimisationRequest {
            change()
            #expect(await eventually { harness.requests.requests.count == count && card.result != nil })
            return try #require(harness.requests.requests.last)
        }
        _ = try await runs(2) { harness.model.crop(card, to: CropSize(rect: rect)) }
        var request = try await runs(3) { harness.model.apply(OptimiseChoice(format: .webp), to: card) }
        #expect(request.crop?.rect == rect && request.format == .webp, "crop, then WebP: still cropped")
        request = try await runs(4) { harness.model.downscale(card, to: 0.5) }
        #expect(request.crop?.rect == rect && request.downscale == 0.5)
        request = try await runs(5) { harness.model.apply(OptimiseChoice(format: .avif), to: card) }
        #expect(request.crop?.rect == rect && request.downscale == 0.5, "Half, then AVIF: still half")
        let options = OptionsModel(card: card, app: harness.model)
        request = try await runs(6) { options.resetCrop() }
        #expect(request.crop == nil && request.downscale == 0.5, "Reset takes the crop off, the scale stays")
        request = try await runs(7) { harness.model.crop(card, to: CropSize(rect: rect)) }
        #expect(request.crop?.rect == rect && request.downscale == 0.5)
        request = try await runs(8) { options.scale(to: 1) }
        #expect(request.crop == nil && request.downscale == nil, "Original takes both off")
    }

    /// Two quick re-runs, or Undo during a re-run, start one restore: a second would put the
    /// original back twice and send it to the Trash as an edit.
    @Test func aSecondRestoreWaitsForTheFirst() async throws {
        let harness = Harness()
        _ = await harness.model.run(harness.job(harness.temp.file("a.png", bytes: 100_000)))
        let card = try #require(harness.model.cards.first)
        harness.model.perform(.downscale, on: card)
        harness.model.perform(.downscale, on: card)
        harness.model.perform(.undo, on: card)
        #expect(await eventually { harness.requests.requests.count == 2 && card.result != nil })
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.requests.requests.count == 2)
        #expect(card.result != nil, "Undo waited, the re-run's result stands")
        #expect(!card.restoring && !card.editInTrash)
    }

    /// After Save to Downloads and Undo, Show in Finder shows the original, not the saved copy.
    @Test func undoForgetsTheSavedCopy() async throws {
        let harness = Harness()
        let downloads = harness.temp.url.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        harness.model.downloads = { downloads }
        let file = harness.temp.file("a.png", bytes: 100_000)
        _ = await harness.model.run(harness.job(file, origin: .dropZone))
        let card = try #require(harness.model.cards.first)
        harness.model.perform(.save, on: card)
        #expect(card.savedCopy != nil)
        harness.model.perform(.undo, on: card)
        #expect(await eventually { if case .restored = card.phase { true } else { false } })
        #expect(card.savedCopy == nil)
        harness.model.perform(.reveal, on: card)
        #expect(harness.revealed.urls.last?.standardizedFileURL == file.standardizedFileURL)
    }

    /// A file copied in Finder comes back from Recent as the copy it was, by its recorded origin.
    @Test func recentUsesTheRecordedOrigin() throws {
        let harness = Harness()
        let file = URL(fileURLWithPath: "/tmp/Desktop/Report.png")
        var result = OptimisationResult(source: file, output: file, kind: .image, bytesBefore: 2_000, bytesAfter: 1_000, startedAt: Date(), finishedAt: Date())
        result.origin = .clipboard
        let card = harness.model.show(result)
        #expect(card.origin == .clipboard)
        #expect(card.presentation.tools.first == .copy, "Copy, as when it was copied")
        #expect(card.presentation.fileName == "Report.png", "it has a name of its own")
    }

    /// Undo never deletes: when it moved an edited version to the Trash, the card says so.
    @Test func undoSaysWhereTheEditWent() throws {
        let file = URL(fileURLWithPath: "/tmp/a.png")
        let inPlace = OptimisationResult(source: file, output: file, kind: .image, bytesBefore: 2_000, bytesAfter: 1_000, startedAt: Date(), finishedAt: Date())
        var converted = inPlace
        converted.output = URL(fileURLWithPath: "/tmp/a.webp")
        #expect(!AppModel.editWentToTrash(trashed: 0, restoring: inPlace))
        #expect(AppModel.editWentToTrash(trashed: 1, restoring: inPlace))
        #expect(!AppModel.editWentToTrash(trashed: 1, restoring: converted), "the converted output alone")
        #expect(AppModel.editWentToTrash(trashed: 2, restoring: converted))

        let card = ResultCard(jobID: inPlace.id, source: file, origin: .dropZone, bytesBefore: 2_000, phase: .restored(inPlace))
        #expect(!card.presentation.caption.contains("Trash"))
        card.editInTrash = true
        #expect(card.presentation.caption == "Your edited version is in the Trash")
        #expect(card.presentation.accessibilityLabel.hasSuffix("Your edited version is in the Trash"))
        #expect(CardPresentation(card: card, locale: Locale(identifier: "ca")).caption == "La teva versió editada és a la Paperera")
    }
}
