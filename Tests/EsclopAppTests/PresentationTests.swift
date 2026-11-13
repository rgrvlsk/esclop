// SPDX-License-Identifier: GPL-3.0-or-later

import EsclopCore
@testable import EsclopAppKit
import Foundation
import ImageIO
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
        #expect(Figures.change(before: 2_400_000, after: 612_000, locale: en) == "2.4\(nbsp)MB → 612\(nbsp)kB")
        #expect(Figures.duration(37) == "0:37")
        #expect(Figures.duration(3725) == "1:02:05")
        #expect(Figures.timeLeft(11.2) == "12\(nbsp)s left")
        #expect(Figures.timeLeft(130) == "3\(nbsp)min left")
    }

    @Test func anUploadedResultSaysSoToVoiceOverAsOnScreen() {
        // `esclop upload` and automatic uploads hand back a result that carries its link.
        let card = ResultCard(jobID: UUID(), source: URL(fileURLWithPath: "/tmp/shot.png"), origin: .clipboard, bytesBefore: 542_000)
        var output = result(before: 542_000, after: 542_000, backup: false)
        output.link = URL(string: "https://files.example.com/2026/11/shot.png")
        card.phase = .done(output)
        let info = CardPresentation(card: card, locale: en)
        #expect(info.capsule == .status(symbol: "link", text: "Uploaded · link copied"))
        #expect(info.accessibilityLabel == "shot.png, uploaded, the link is on the clipboard")
        #expect(info.actions.first == .copyLink)
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
        #expect(info.tools == [.copy, .undo, .more], "a copied screenshot goes back to the clipboard")
        #expect(info.change == "2.4\(nbsp)MB → 600\(nbsp)kB")
        #expect(info.formats == "PNG", "one format when it did not change")
        #expect(info.dimensions == "2940 × 1912")
        // 1 + 2 + "…": a copied screenshot goes back to the clipboard; there is no folder to show.
        #expect(info.primary == .copy)
        #expect(info.primaryDetail == "Put it back on the clipboard")
        #expect(info.secondary == [.undo])
        #expect(info.menu == [.convert(.webp), .downscale, .crop, .compare, .more])
        #expect(info.actions == [.openDetail, .copy, .undo, .more, .reveal, .dismiss])
        #expect(info.accessibilityLabel == "shot.png, Optimised, 600\(nbsp)kB, 75\(nbsp)% smaller")
        #expect(CardPresentation.announcement(for: output, locale: en) == "Optimised, 600\(nbsp)kB, 75\(nbsp)% smaller")
    }

    /// The "Removed" strip compares the original with the result, so it holds whatever path the
    /// engine took; a copied image never shows it.
    @Test func theRemovedStripListsWhatTheResultLost() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func jpeg(_ name: String, _ properties: [CFString: Any]) throws -> URL {
            let url = folder.appendingPathComponent(name)
            let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            let image = try #require(context.makeImage())
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            #expect(CGImageDestinationFinalize(destination))
            return url
        }
        let original = try jpeg("original.jpg", [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 41.38, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Camera"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:06:09 09:41:00"],
        ])
        let stripped = try jpeg("stripped.jpg", [:])
        let keptCamera = try jpeg("camera.jpg", [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Camera"]])
        #expect(RemovedMetadata.between(original: original, output: stripped) == [.location, .camera, .date])
        #expect(RemovedMetadata.between(original: original, output: keptCamera) == [.location, .date])
        #expect(RemovedMetadata.between(original: stripped, output: stripped).isEmpty)

        let card = ResultCard(jobID: UUID(), source: URL(fileURLWithPath: "/tmp/Beach.jpg"), origin: .dropZone, bytesBefore: 2_400_000)
        card.phase = .done(result(before: 2_400_000, after: 600_000))
        card.removedMetadata = [.location, .camera, .date]
        let info = CardPresentation(card: card, locale: en)
        #expect(info.removedSummary == "Location, camera, date")
        #expect(FloatingResultView.actions(info, level: .detail).contains(.keepMetadata), "VoiceOver can restore it")
        let copied = ResultCard(jobID: UUID(), source: URL(fileURLWithPath: "/tmp/shot.png"), origin: .clipboard, bytesBefore: 2_400_000)
        copied.phase = .done(result(before: 2_400_000, after: 600_000))
        copied.removedMetadata = [.date]
        #expect(CardPresentation(card: copied, locale: en).removedMetadata.isEmpty, "a copied image has nothing of the person's")
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
        #expect(pdf.presentation.tools == [.reveal, .more], "convert, downscale and crop live behind \"…\"")
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
        #expect(card.presentation.actions == [.stop], "Stop, for the button and for VoiceOver")
        #expect(card.presentation.primary == .stop, "a detail left open while it runs again can stop it")
        #expect(CardPresentation(card: card, locale: en).headline == "Optimising…")
        card.phase = .working(fraction: -1)
        #expect(card.presentation.progress == nil)
        card.phase = .unchanged(bytes: 412_000)
        #expect(CardPresentation(card: card, locale: en).capsule == .status(symbol: nil, text: "Already optimised · 412\(nbsp)kB"))
        #expect(CardPresentation(card: card, locale: en).headline == "Already optimised")
        #expect(card.presentation.primary == .reveal)
        #expect(card.presentation.secondary == [.copy], "no Undo: nothing changed")
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
        #expect(CardPresentation.message(for: EsclopError.toolFailed(tool: "ffmpeg", exitCode: 1, stderr: "x\nBad file")) == "ffmpeg stopped with code 1: Bad file")
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
