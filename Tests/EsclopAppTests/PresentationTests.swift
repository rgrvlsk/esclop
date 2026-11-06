// SPDX-License-Identifier: GPL-3.0-or-later

import EsclopCore
@testable import EsclopAppKit
import Foundation
import Testing

@MainActor
@Suite struct PresentationTests {
    func result(before: Int, after: Int, backup: Bool = true) -> OptimisationResult {
        OptimisationResult(
            source: URL(fileURLWithPath: "/tmp/shot.png"), output: URL(fileURLWithPath: "/tmp/shot.png"),
            backup: backup ? URL(fileURLWithPath: "/tmp/backup.png") : nil, kind: .image,
            bytesBefore: before, bytesAfter: after, startedAt: Date(), finishedAt: Date()
        )
    }

    @Test func percentUsesATrueMinusAndOneDecimalBelowTen() {
        #expect(CardPresentation.percent(result(before: 1_200_000, after: 340_000)) == "−72%")
        #expect(CardPresentation.percent(result(before: 1000, after: 996)) == "−0.4%")
        #expect(CardPresentation.percent(result(before: 1000, after: 1120)) == "+12%")
        #expect(CardPresentation.percent(result(before: 1000, after: 1000)) == "−0%")
        #expect(CardPresentation.percent(result(before: 0, after: 0)) == "0%")
    }

    @Test func savedCardShowsTheFigureTheSizesAndWhereTheBarEnds() {
        let card = ResultCard(jobID: UUID(), source: URL(fileURLWithPath: "/tmp/shot.png"), origin: .clipboard, bytesBefore: 1_200_000)
        card.phase = .done(result(before: 1_200_000, after: 300_000))
        let info = card.presentation
        #expect(info.headline == "−75%")
        #expect(info.headlineIsFigure)
        #expect(info.tone == .saving)
        #expect(info.detail == "1.2 MB → 300 KB")
        #expect(info.barEnd == 0.25)
        #expect(info.actions == [.restore, .reveal, .copy, .dismiss])
        #expect(info.accessibilityLabel == "shot.png, 75% smaller, 1.2 MB to 300 KB")
    }

    @Test func noBackupMeansNoRestoreAndAggressiveIsWarm() {
        let card = ResultCard(jobID: UUID(), source: URL(fileURLWithPath: "/tmp/shot.png"), origin: .dropZone, aggressive: true, bytesBefore: 1000)
        #expect(card.presentation.headline == "Optimising harder")
        #expect(card.presentation.tone == .warm)
        card.phase = .done(result(before: 1000, after: 500, backup: false))
        #expect(!card.presentation.actions.contains(.restore))
        #expect(card.presentation.tone == .warm)
    }

    @Test func onlyAFinishedCardCanBeDraggedOutAndItGivesTheFileItShows() {
        let source = URL(fileURLWithPath: "/tmp/in.png")
        let output = URL(fileURLWithPath: "/tmp/in-optimised.png")
        let done = OptimisationResult(
            source: source, output: output, backup: nil, kind: .image,
            bytesBefore: 1000, bytesAfter: 400, startedAt: Date(), finishedAt: Date()
        )
        let card = ResultCard(jobID: UUID(), source: source, origin: .clipboard, bytesBefore: 1000)
        #expect(card.draggableFile == nil)
        card.phase = .done(done)
        #expect(card.draggableFile == output)
        card.phase = .restored(done)
        #expect(card.draggableFile == source)
        card.phase = .unchanged(bytes: 1000)
        #expect(card.draggableFile == source)
        card.phase = .failed("broken")
        #expect(card.draggableFile == nil)
        card.phase = .notice(title: "Paused", detail: "")
        #expect(card.draggableFile == nil)
    }

    @Test func otherPhases() {
        let card = ResultCard(jobID: UUID(), source: URL(fileURLWithPath: "/tmp/none.png"), origin: .app, bytesBefore: 412_000)
        card.phase = .working(fraction: 0.4)
        #expect(card.presentation.progress == 0.4)
        #expect(card.presentation.barEnd == 1)
        card.phase = .working(fraction: -1)
        #expect(card.presentation.progress == nil)
        card.phase = .unchanged(bytes: 412_000)
        #expect(card.presentation.headline == "Already optimised")
        #expect(card.presentation.detail == "Kept the original, 412 KB")
        card.phase = .failed("ffmpeg is missing.")
        #expect(card.presentation.tone == .error)
        #expect(card.presentation.barEnd == nil)
        #expect(card.presentation.actions == [.dismiss], "the file is not there, so no Show in Finder")
        card.displayName = "Copied image"
        #expect(card.presentation.fileName == "Copied image")
    }

    @Test func errorMessagesSayWhatToDo() {
        #expect(CardPresentation.message(for: EsclopError.toolMissing("ffmpeg")) == "ffmpeg is missing. Reinstall L'Esclop or run Scripts/build-tools.sh.")
        #expect(CardPresentation.message(for: EsclopError.toolFailed(tool: "gs", exitCode: 1, stderr: "x\nBad PDF")) == "gs stopped with code 1: Bad PDF")
        #expect(CardPresentation.message(for: CancellationError()) == "Stopped before it finished.")
    }

    @Test func dropZoneWording() {
        let state = DropZoneState(fileCount: 1)
        #expect(state.title == "Drop to optimise")
        #expect(state.detail == "1 file. Hold ⌘ for harder")
        state.harder = true
        state.fileCount = 3
        #expect(state.title == "Drop to optimise harder")
        #expect(state.detail == "3 files with the aggressive settings")
    }
}
