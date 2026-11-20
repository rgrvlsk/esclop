// SPDX-License-Identifier: GPL-3.0-or-later
//
// The floating result, the options, the drop zone and the menu bar panel do what they say
// (release hillclimb HC-26).

import AppKit
import EsclopCore
@testable import EsclopAppKit
import EsclopOptimisers
import Foundation
import Testing

@MainActor
@Suite struct SurfacePolishTests {
    /// A re-run puts the original back first; when that set an edited version aside, a notice
    /// says where it went, since the restored card that says it lasts only until the run starts.
    @Test func aReRunSaysWhereTheEditWent() async throws {
        let harness = Harness()
        harness.model.restoreBackup = { service, result in
            var outcome = try await service.restoreBackup(of: result, deleteBackup: false)
            outcome.movedToTrash = [result.output.path, result.source.path]
            return outcome
        }
        _ = await harness.model.run(harness.job(harness.temp.file("a.png", bytes: 100_000)))
        let card = try #require(harness.model.cards.first)
        harness.model.perform(.downscale, on: card)
        #expect(await eventually { harness.requests.requests.count == 2 && card.result != nil })
        let notice = CardPresentation.Capsule.notice(
            title: "Your edited version is in the Trash", detail: "It changed after optimising. The new result starts from the original."
        )
        #expect(harness.model.cards.contains { $0.presentation.capsule == notice })
    }

    /// A photo dropped from Safari or Photos lives in L'Esclop's temporary folder, which macOS
    /// clears: its card offers a copied image's actions, and ⌘S saves it to Downloads, in the
    /// popover as on the card.
    @Test func aFileInTheTemporaryFolderActsAsACopiedImage() async throws {
        let harness = Harness()
        let downloads = harness.temp.url.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        harness.model.downloads = { downloads }
        let folder = try Paths.ensure(Paths.temporary.appendingPathComponent("dropped/test-\(UUID().uuidString.prefix(8))", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Beach.jpg")
        try Data(count: 100_000).write(to: file)
        _ = await harness.model.run(harness.job(file, origin: .dropZone))
        let card = try #require(harness.model.cards.first)
        let info = card.presentation
        #expect(info.tools.first == .copy)
        #expect(info.primary == .copy && info.secondary.first == .save)
        #expect(info.menu.contains(.saveAs) && !info.menu.contains(.trash), "\(info.menu)")
        #expect(harness.model.press("s", on: card), "⌘S is Save to Downloads")
        #expect(card.savedCopy?.deletingLastPathComponent().standardizedFileURL == downloads.standardizedFileURL)
    }

    /// Only a copied image is "Copied image" when it comes back from Recent; a dropped file in
    /// the temporary folder keeps its name.
    @Test func onlyACopiedImageIsNamedCopiedImage() {
        let harness = Harness()
        func shown(_ source: URL) -> String {
            let result = OptimisationResult(source: source, output: source, kind: .image, bytesBefore: 2_000, bytesAfter: 1_000, startedAt: Date(), finishedAt: Date())
            return harness.model.show(result).presentation.fileName
        }
        #expect(shown(Clipboard.folder.appendingPathComponent("Clipboard.png")) == "Copied image")
        #expect(shown(Paths.temporary.appendingPathComponent("dropped/1a2b3c4d/Beach.jpg")) == "Beach.jpg")
    }

    /// Save to Downloads that fails says why, as Save As does, instead of a beep.
    @Test func aFailedSaveSaysWhy() async throws {
        let harness = Harness()
        harness.model.downloads = { harness.temp.url.appendingPathComponent("missing", isDirectory: true) }
        _ = await harness.model.run(harness.job(harness.temp.file("Clipboard.png", bytes: 100_000), origin: .clipboard), displayName: "Copied image")
        let card = try #require(harness.model.cards.first)
        harness.model.perform(.save, on: card)
        #expect(card.savedCopy == nil)
        guard case let .notice(title, _)? = harness.model.cards.last?.presentation.capsule else {
            Issue.record("no notice")
            return
        }
        #expect(title.hasPrefix("Could not save Copied image"))
        #expect(harness.announcements.texts.last == title)
    }

    /// A Fit stays with the card, as the crop does: another choice fits again, Original takes it
    /// off.
    @Test func aFitIsKeptAcrossReRuns() async throws {
        let harness = Harness()
        _ = await harness.model.run(harness.job(harness.temp.file("a.png", bytes: 100_000)))
        let card = try #require(harness.model.cards.first)
        harness.model.fit(card, under: 20_000)
        #expect(await eventually { harness.requests.requests.count == 2 && card.result != nil })
        #expect(card.fit == 20_000)
        var choice = card.choice
        choice.stripMetadata = false
        harness.model.apply(choice, to: card)
        #expect(await eventually { harness.requests.requests.count == 3 && card.result != nil })
        #expect(harness.requests.requests.last?.targetBytes == 20_000, "fitted again")
        harness.model.downscale(card, to: 1)
        #expect(await eventually { harness.requests.requests.count == 4 && card.result != nil })
        #expect(harness.requests.requests.last?.targetBytes == nil && card.fit == nil, "Original takes it off")
    }

    /// ⌥ on a format tile keeps both, and the copy has the card's crop, scale and fit.
    @Test func keepBothMakesTheCardsStepsAgain() async throws {
        let harness = Harness()
        _ = await harness.model.run(harness.job(harness.temp.file("a.png", bytes: 100_000)))
        let card = try #require(harness.model.cards.first)
        let rect = CropRect(x: 0, y: 0, width: 10, height: 10)
        harness.model.crop(card, to: CropSize(rect: rect))
        #expect(await eventually { harness.requests.requests.count == 2 && card.result != nil })
        harness.model.downscale(card, to: 0.5)
        #expect(await eventually { harness.requests.requests.count == 3 && card.result != nil })
        harness.model.fit(card, under: 20_000)
        #expect(await eventually { harness.requests.requests.count == 4 && card.result != nil })
        harness.model.convertKeepingBoth(card, to: .webp)
        #expect(await eventually { harness.requests.requests.count == 5 })
        let request = try #require(harness.requests.requests.last)
        #expect(request.crop?.rect == rect && request.downscale == 0.5 && request.targetBytes == 20_000)
        #expect(request.format == .webp)
    }

    /// The drop answers with what the source allows: with ⌘ held Finder offers a move only, and
    /// a drop that answered "copy" was refused.
    @Test func theDropAnswersWhatTheSourceAllows() throws {
        #expect(DropTargetView.operation(for: .every) == .copy)
        #expect(DropTargetView.operation(for: [.generic, .move]) == .generic)
        #expect(DropTargetView.operation(for: []) == [])
        let temp = TempDir()
        let view = DropTargetView(frame: .zero)
        let state = DropZoneState(fileCount: 1)
        state.frames[DropZoneState.plainTarget] = CGRect(x: -1, y: -1, width: 2, height: 2)
        view.state = state
        let drag = FakeDrag([temp.file("a.png")])
        defer { drag.draggingPasteboard.releaseGlobally() }
        drag.draggingSourceOperationMask = .move
        #expect(view.draggingEntered(drag) == .move)
    }

    /// Over a built-in preset zone the line names it in the person's language.
    @Test func thePresetZoneLineUsesTheZonesTitle() {
        let zone = PresetZone(name: "to WebP", builtIn: true)
        let state = DropZoneState(fileCount: 1, zones: [zone], hoveredZone: zone.name)
        #expect(state.title == Strings.format("Drop to run “%@”", zone.title))
    }

    /// An exported document is a PDF: "exported PDFs", never "PDF exported documents".
    @Test func exportedPDFsAreNamedSo() {
        let en = Locale(identifier: "en")
        #expect(ClipboardRule.checkboxTitle(origin: .pdfExport, inputType: "com.adobe.pdf", locale: en) == "Always apply to exported PDFs")
        #expect(ClipboardRule.checkboxTitle(origin: .pdfExport, inputType: "com.adobe.pdf", locale: Locale(identifier: "ca")) == "Aplica-ho sempre als PDF exportats")
    }

    /// The arrows reach the commands with Recent empty, and stop at the ends.
    @Test func theArrowsReachTheCommandsWithRecentEmpty() {
        #expect(MenuPanel.item(after: nil, by: 1, results: []) == .optimiseFiles)
        #expect(MenuPanel.item(after: .optimiseFiles, by: 1, results: []) == .optimiseClipboard)
        #expect(MenuPanel.item(after: .optimiseClipboard, by: 1, results: []) == .optimiseClipboard)
        let id = UUID()
        #expect(MenuPanel.item(after: nil, by: 1, results: [id]) == .result(id))
        #expect(MenuPanel.item(after: .result(id), by: 1, results: [id]) == .optimiseFiles)
        #expect(MenuPanel.item(after: nil, by: -1, results: [id]) == .optimiseClipboard)
    }
}
