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

    let en = Locale(identifier: "en_US")
    let ca = Locale(identifier: "ca_ES")
    let nbsp = "\u{00A0}"

    @Test func figuresAreWrittenTheWayTheDesignShowsThem() {
        #expect(Figures.bytes(612_000, locale: en) == "612\(nbsp)kB")
        #expect(Figures.bytes(2_400_000, locale: en) == "2.4\(nbsp)MB")
        #expect(Figures.bytes(2_400_000, locale: ca) == "2,4\(nbsp)MB", "the locale's decimal separator")
        #expect(Figures.bytes(37_000_000, locale: en) == "37\(nbsp)MB")
        #expect(Figures.bytes(999_700, locale: en) == "1\(nbsp)MB")
        #expect(Figures.bytes(512, locale: en) == "512\(nbsp)B")
        #expect(Figures.percent(before: 2_400_000, after: 620_000, locale: en) == "−74\(nbsp)%")
        #expect(Figures.percent(before: 1000, after: 996, locale: en) == "−0.4\(nbsp)%")
        #expect(Figures.percent(before: 1000, after: 1120, locale: en) == "+12\(nbsp)%")
        #expect(Figures.percent(before: 0, after: 0, locale: en) == "0\(nbsp)%")
        #expect(Figures.percent(before: 2_400_000, after: 600_000, progress: 0.5, locale: en) == "−38\(nbsp)%", "the count-down halfway")
        #expect(Figures.change(before: 2_400_000, after: 612_000, locale: en) == "2.4\(nbsp)MB → 612\(nbsp)kB")
        #expect(Figures.duration(37) == "0:37")
        #expect(Figures.duration(3725) == "1:02:05")
        #expect(Figures.timeLeft(11.2) == "12\(nbsp)s left")
        #expect(Figures.timeLeft(130) == "3\(nbsp)min left")
    }

    @Test func aResultShowsTheSavingInTheCapsuleAndTheDetail() {
        let card = ResultCard(jobID: UUID(), source: URL(fileURLWithPath: "/tmp/shot.png"), origin: .clipboard, bytesBefore: 2_400_000)
        var output = result(before: 2_400_000, after: 600_000)
        output.width = 2940
        output.height = 1912
        card.phase = .done(output)
        let info = CardPresentation(card: card, locale: en)
        #expect(info.capsule == .result(before: 2_400_000, after: 600_000))
        #expect(info.tone == .saving)
        #expect(info.tools == [.undo, .convert(.webp), .downscale, .crop, .more])
        #expect(info.detailTitle == "Optimised")
        #expect(info.change == "2.4\(nbsp)MB → 600\(nbsp)kB")
        #expect(info.percent == "−75\(nbsp)%")
        #expect(info.barEnd == 0.25)
        #expect(info.formats == "PNG → PNG")
        #expect(info.dimensions == "2940 × 1912")
        #expect(info.detailActions == [.undo, .compare, .convert(.webp), .downscale, .crop])
        #expect(info.actions.first == .openDetail)
        #expect(info.actions.suffix(3) == [.reveal, .copy, .dismiss])
        #expect(info.accessibilityLabel == "shot.png, Optimised, 600\(nbsp)kB, 75\(nbsp)% smaller")
        #expect(CardPresentation.announcement(for: output, locale: en) == "Optimised, 600\(nbsp)kB, 75\(nbsp)% smaller")
    }

    @Test func noBackupMeansNoUndoAndAggressiveIsWarm() {
        let card = ResultCard(jobID: UUID(), source: URL(fileURLWithPath: "/tmp/shot.png"), origin: .dropZone, aggressive: true, bytesBefore: 1000)
        #expect(card.presentation.capsule == .working("Optimising harder…"))
        #expect(card.presentation.tone == .warm)
        card.phase = .done(result(before: 1000, after: 500, backup: false))
        #expect(!card.presentation.tools.contains(.undo))
        #expect(card.presentation.tone == .warm)
    }

    @Test func convertingPicksOneFormatPerKind() {
        func target(_ name: String) -> OutputFormat? {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            return CardPresentation.convertTarget(for: url, kind: MediaKind.of(url))
        }
        #expect(target("a.png") == .webp)
        #expect(target("a.heic") == .webp)
        #expect(target("a.webp") == .png)
        #expect(target("a.mov") == .mp4)
        #expect(target("a.mp4") == nil)
        #expect(target("a.wav") == .aac)
        #expect(target("a.pdf") == nil)
        let pdf = ResultCard(jobID: UUID(), source: URL(fileURLWithPath: "/tmp/a.pdf"), origin: .app, bytesBefore: 10)
        pdf.phase = .unchanged(bytes: 10)
        #expect(pdf.presentation.tools == [.more], "no convert, downscale or crop for a PDF")
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
        #expect(card.presentation.isWorking)
        #expect(card.presentation.tools.isEmpty)
        card.phase = .working(fraction: -1)
        #expect(card.presentation.progress == nil)
        card.phase = .unchanged(bytes: 412_000)
        #expect(CardPresentation(card: card, locale: en).capsule == .status(symbol: "checkmark", text: "Already optimised · 412\(nbsp)kB"))
        #expect(card.presentation.detailTitle == "Already optimised")
        card.phase = .restored(result(before: 412_000, after: 100_000))
        #expect(CardPresentation(card: card, locale: en).capsule == .status(symbol: "arrow.uturn.backward", text: "Original restored · 412\(nbsp)kB"))
        #expect(!card.presentation.tools.contains(.undo), "nothing left to undo")
        card.phase = .failed("ffmpeg is missing.")
        #expect(card.presentation.tone == .error)
        #expect(card.presentation.capsule == .error(title: "Couldn’t optimise", message: "ffmpeg is missing."))
        #expect(card.presentation.actions == [.dismiss], "the file is not there, so no retry or Show in Finder")
        card.displayName = "Copied image"
        #expect(card.presentation.fileName == "Copied image")
    }

    @Test func errorMessagesSayWhatToDo() {
        #expect(CardPresentation.message(for: EsclopError.toolMissing("ffmpeg")) == "ffmpeg is missing. Reinstall L’Esclop or run Scripts/build-tools.sh.")
        #expect(CardPresentation.message(for: EsclopError.toolFailed(tool: "gs", exitCode: 1, stderr: "x\nBad PDF")) == "gs stopped with code 1: Bad PDF")
        #expect(CardPresentation.message(for: CancellationError()) == "Stopped before it finished.")
        #expect(
            CardPresentation.message(for: EsclopError.toolFailed(tool: "ffprobe", exitCode: 1, stderr: "moov atom not found\n/tmp/x/broken.mov: Invalid data found when processing input"))
                == "ffprobe stopped with code 1: Invalid data found when processing input",
            "no file paths in what the person reads"
        )
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
