// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EsclopCore
import EsclopIPC
import EsclopOptimisers
@testable import EsclopAppKit
import Foundation
import Testing

@MainActor
@Suite struct AppModelTests {
    @Test func aJobShowsACardThatEndsWithTheSaving() async throws {
        let harness = Harness()
        let file = harness.temp.file("shot.png", bytes: 100_000)
        let events = EventLog()
        let report = await harness.model.run(harness.job(file), events: { events.add($0) })
        #expect(report.results.count == 1)
        #expect(report.failures.isEmpty)
        let card = try #require(harness.model.cards.first)
        let result = try #require(card.result)
        #expect(result.bytesBefore == 100_000)
        #expect(result.bytesAfter == 40_000)
        #expect(card.presentation.capsule == .result(before: 100_000, after: 40_000))
        #expect(harness.announcements.texts.count == 1, "VoiceOver hears each result once")
        #expect(harness.model.recent.first?.id == result.id)
        #expect(harness.model.service.results.recent(limit: 5).map(\.id) == [result.id], "the CLI and MCP see it in the shared log")
        #expect(events.kinds == ["result"])
        #expect(harness.model.activeFiles == 0)
    }

    @Test func nothingSmallerAndFailuresGetTheirOwnCards() async throws {
        let unchanged = Harness(failure: .alreadySmaller)
        _ = await unchanged.model.run(unchanged.job(unchanged.temp.file("a.png", bytes: 5000)))
        #expect(unchanged.model.cards.first?.presentation.headline == "Already optimised")

        let failing = Harness(failure: .toolMissing("ffmpeg"))
        let events = EventLog()
        let report = await failing.model.run(failing.job(failing.temp.file("b.mov")), events: { events.add($0) })
        #expect(report.failures.first?.error == .toolMissing("ffmpeg"))
        #expect(events.kinds == ["failure"])
        let card = try #require(failing.model.cards.first)
        #expect(card.presentation.capsule == .error(title: "Not optimised", message: "ffmpeg is missing. Reinstall L’Esclop or run Scripts/build-tools.sh."))
        #expect(failing.model.recent.isEmpty)
    }

    @Test func jobsWithoutResultUIShowNoCard() async {
        let harness = Harness()
        let report = await harness.model.run(harness.job(harness.temp.file("a.png"), showUI: false))
        #expect(report.results.count == 1)
        #expect(harness.model.cards.isEmpty)
    }

    @Test func cardsHideOnTheirOwnUnlessHovered() async throws {
        let harness = Harness()
        harness.model.hideDelayOverride = .milliseconds(50)
        _ = await harness.model.run(harness.job(harness.temp.file("a.png")))
        _ = await harness.model.run(harness.job(harness.temp.file("b.png")))
        let hovered = try #require(harness.model.cards.last)
        harness.model.interact(hovered, .pointerEntered)
        #expect(await eventually { harness.model.cards.count == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.model.cards.first?.id == hovered.id, "the hovered card stays")
        harness.model.interact(hovered, .pointerExited)
        // Leaving a card whose time ran out hides it two seconds later.
        #expect(await eventually { harness.model.cards.isEmpty })
    }

    @Test func autoHideCanBeTurnedOff() async throws {
        let harness = Harness()
        try EsclopSettings.autoHideFloatingResults.set(false, in: harness.settings.store)
        harness.model.hideDelayOverride = .milliseconds(20)
        _ = await harness.model.run(harness.job(harness.temp.file("a.png")))
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.model.cards.count == 1)
    }

    @Test func dismissingAWorkingCardStopsItsFile() async throws {
        let harness = Harness(delay: .seconds(30))
        let job = harness.job(harness.temp.file("a.png"))
        let run = Task { await harness.model.run(job) }
        #expect(await eventually { !harness.model.cards.isEmpty })
        harness.model.dismiss(try #require(harness.model.cards.first))
        let report = await run.value
        #expect(report.failures.first?.error == .cancelled)
        #expect(harness.model.cards.isEmpty)
    }

    @Test func restoreFromTheCardPutsTheOriginalBack() async throws {
        let harness = Harness()
        let file = harness.temp.file("a.png", bytes: 100_000)
        _ = await harness.model.run(harness.job(file))
        let card = try #require(harness.model.cards.first)
        #expect(harness.model.restorable.count == 1)
        harness.model.perform(.undo, on: card)
        #expect(await eventually { if case .restored = card.phase { return true } else { return false } })
        #expect(AppModel.size(of: file) == 100_000)
        #expect(harness.model.restorable.isEmpty)
    }

    /// A re-run of a card replaces its result, and Undo withdraws it: the saving counts the file
    /// once, then not at all, and Recent never lists it twice.
    @Test func aRerunCountsOnceAndUndoCountsNothing() async throws {
        for location in [OutputLocation.inPlace, .sameFolder] {
            let harness = Harness()
            let file = harness.temp.file("a.png", bytes: 100_000)
            // A drop: a copied file is optimised as a temporary copy and has no Undo.
            _ = await harness.model.run(harness.job(file, origin: .dropZone, location: location))
            let card = try #require(harness.model.cards.first)
            #expect(harness.model.recent.first?.origin == .dropZone, "the log says where it came from")
            let first = try #require(card.result)
            harness.model.perform(.downscale, on: card)
            #expect(await eventually { harness.requests.requests.count == 2 && card.result != nil && card.result?.id != first.id })
            let log = harness.model.service.results
            #expect(log.savings().count == 1, "\(location): one file, counted once")
            #expect(log.recent(limit: 10).map(\.id) == [card.result?.id], "\(location): one row in the shared log")
            #expect(harness.model.recent.map(\.id) == [card.result?.id], "\(location): one row in Recent")
            guard location == .inPlace else { continue }
            harness.model.perform(.undo, on: card)
            #expect(await eventually { if case .restored = card.phase { return true } else { return false } })
            #expect(log.savings().isEmpty, "undone: nothing saved")
            #expect(log.recent(limit: 10).isEmpty && harness.model.recent.isEmpty)
        }
    }

    /// Each card restores its own original, not the newest one for the same path.
    @Test func restoreUsesTheResultsOwnBackup() async throws {
        let harness = Harness()
        let file = harness.temp.file("Beach.jpg", bytes: 100_000)
        let first = try #require(await harness.model.run(harness.job(file)).results.first)
        let second = try #require(await harness.model.run(harness.job(file)).results.first)
        #expect(await harness.model.restore(second))
        #expect(AppModel.size(of: file) == 40_000)
        #expect(await harness.model.restore(first))
        #expect(AppModel.size(of: file) == 100_000, "the first card's original")
    }

    /// Recent › Clear redacts the shared log; a card still on screen can still be undone.
    @Test func undoWorksAfterRecentIsCleared() async throws {
        let harness = Harness()
        let file = harness.temp.file("a.png", bytes: 100_000)
        _ = await harness.model.run(harness.job(file))
        let card = try #require(harness.model.cards.first)
        harness.model.clearRecent()
        harness.model.perform(.undo, on: card)
        #expect(await eventually { if case .restored = card.phase { return true } else { return false } })
        #expect(AppModel.size(of: file) == 100_000)
    }

    /// A restore that fails stops a re-run: it would encode the optimised file again.
    @Test func aFailedRestoreStopsTheRerun() async throws {
        let harness = Harness()
        let file = harness.temp.file("a.png", bytes: 100_000)
        _ = await harness.model.run(harness.job(file))
        let card = try #require(harness.model.cards.first)
        try FileManager.default.removeItem(at: try #require(card.result?.backup))
        harness.model.perform(.keepMetadata, on: card)
        #expect(await eventually { harness.model.cards.contains { $0.presentation.capsule == .notice(title: "Could not restore a.png", detail: "The original’s backup is no longer there.") } })
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.requests.requests.count == 1, "nothing runs again")
        #expect(card.result != nil, "the card keeps its result: no Retry that compresses it again")
        #expect(CardPresentation.message(for: EsclopError.backupRemoved(file: file.path, afterDays: 7)) == "The original was removed after 7 days.")
        #expect(CardPresentation.message(for: EsclopError.other(BackupStore.untrashableEdit)) == BackupStore.untrashableEdit)
        #expect(Strings.text(BackupStore.untrashableEdit, locale: Locale(identifier: "ca")).hasPrefix("El fitxer ha canviat"), "the card can say it in Catalan")
    }

    /// Y3: a folder or disk that refuses the write is one plain sentence, in English and Catalan,
    /// not the raw error with its temporary paths. Other errors keep their text.
    @Test func aRefusedWriteIsOnePlainSentence() {
        let posix = { (code: Int32) in NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        let noPermission = CocoaError(.fileWriteNoPermission, userInfo: [NSUnderlyingErrorKey: posix(EACCES), NSFilePathErrorKey: "/var/folders/x/T/esclop/work/optimised.png"])
        #expect(EsclopError.wrap(noPermission) == .other(EsclopError.noWritePermission))
        #expect(EsclopError.wrap(CocoaError(.fileWriteNoPermission, userInfo: [NSUnderlyingErrorKey: posix(EROFS)])) == .other(EsclopError.readOnlyDisk))
        #expect(EsclopError.wrap(CocoaError(.fileWriteVolumeReadOnly)) == .other(EsclopError.readOnlyDisk))
        #expect(EsclopError.wrap(CocoaError(.fileReadNoPermission)) != .other(EsclopError.noWritePermission), "a read is not a write")
        #expect(CardPresentation.message(for: noPermission) == "L’Esclop has no permission to write in that folder.")
        let ca = Locale(identifier: "ca")
        #expect(Strings.text(EsclopError.noWritePermission, locale: ca) == "L’Esclop no té permís per escriure en aquesta carpeta.")
        #expect(Strings.text(EsclopError.readOnlyDisk, locale: ca) == "Aquest disc és només de lectura.")
    }

    @Test func revealAndCopyUseTheResult() async throws {
        let harness = Harness()
        let file = harness.temp.file("a.png")
        _ = await harness.model.run(harness.job(file))
        let card = try #require(harness.model.cards.first)
        harness.model.perform(.reveal, on: card)
        #expect(harness.revealed.urls == [file])
        harness.model.perform(.copy, on: card)
        await harness.clipboardSettles()
        #expect(Clipboard.isOwnWrite(harness.pasteboard))
        #expect(Clipboard.read(harness.pasteboard) == .files([file.standardizedFileURL]))
        harness.model.perform(.dismiss, on: card)
        #expect(harness.model.cards.isEmpty)
    }

    @Test func copiedImagesAreOptimisedAndPutBack() async throws {
        let harness = Harness()
        let data = pngData() + Data(count: 60_000)
        harness.model.handleClipboard(harness.copy(image: data))
        #expect(await eventually { harness.model.cards.first?.result != nil })
        let card = try #require(harness.model.cards.first)
        #expect(card.presentation.fileName == "Copied image")
        #expect(card.origin == .clipboard)
        #expect(await eventually { Clipboard.isOwnWrite(harness.pasteboard) })
    }

    @Test func droppedFoldersAreExpandedToMedia() async throws {
        let harness = Harness()
        let folder = harness.temp.url.appendingPathComponent("drop", isDirectory: true)
        _ = harness.temp.file("drop/a.png")
        _ = harness.temp.file("drop/notes.txt")
        harness.model.optimiseDropped([folder], harder: true)
        #expect(await eventually { harness.model.cards.first?.result != nil })
        #expect(harness.model.cards.count == 1)
        #expect(harness.model.cards.first?.aggressive == true)
        harness.model.optimiseDropped([harness.temp.file("notes2.txt")], harder: false)
        #expect(harness.model.cards.last?.presentation.capsule == .notice(title: "Nothing to optimise", detail: "Drop images, videos, PDFs or audio files."))
    }

    @Test func saveCopiesACopiedImageToDownloadsUnderAFreeName() async throws {
        let harness = Harness()
        let downloads = harness.temp.url.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        harness.model.downloads = { downloads }
        _ = await harness.model.run(harness.job(harness.temp.file("Clipboard.png", bytes: 100_000), origin: .clipboard), displayName: "Copied image")
        let card = try #require(harness.model.cards.first)
        harness.model.perform(.save, on: card)
        let saved = try #require(card.savedCopy)
        #expect(saved.deletingLastPathComponent().standardizedFileURL == downloads.standardizedFileURL)
        #expect(saved.lastPathComponent.hasPrefix("Copied image 20") && saved.pathExtension == "png", "\(saved.lastPathComponent)")
        #expect(FileManager.default.contentsEqual(atPath: saved.path, andPath: card.shownFile.path))
        #expect(harness.announcements.texts.last == "Saved to Downloads")
        harness.model.perform(.save, on: card)
        #expect(card.savedCopy?.deletingPathExtension().lastPathComponent == saved.deletingPathExtension().lastPathComponent + " 2", "never over the first")
        harness.model.perform(.reveal, on: card)
        #expect(harness.revealed.urls.last == card.savedCopy)
    }

    @Test func shareFromVoiceOverOpensTheShareTab() async throws {
        let harness = Harness()
        _ = await harness.model.run(harness.job(harness.temp.file("a.png", bytes: 100_000)))
        let card = try #require(harness.model.cards.first)
        harness.model.perform(.openDetail, on: card)
        harness.model.perform(.share, on: card)
        #expect(card.optionsTab == .share)
        #expect(card.machine.menuOpen && card.machine.level == .thumbnail)
    }

    @Test func restoreRunsAgainKeepingTheMetadata() async throws {
        let harness = Harness()
        let file = harness.temp.file("a.png", bytes: 100_000)
        _ = await harness.model.run(harness.job(file))
        let card = try #require(harness.model.cards.first)
        harness.model.perform(.keepMetadata, on: card)
        #expect(await eventually { harness.requests.requests.count == 2 && card.result != nil })
        let again = try #require(harness.requests.requests.last)
        #expect(again.stripMetadata == false, "kept, whatever the setting says")
        #expect(again.sources == [file], "from the original")
    }

    /// Restore is offered after a downscale and a fit: its re-run makes both again, with the
    /// metadata kept.
    @Test func restoreAfterADownscaleAndAFitKeepsThem() async throws {
        let harness = Harness()
        _ = await harness.model.run(harness.job(harness.temp.file("a.jpg", bytes: 100_000)))
        let card = try #require(harness.model.cards.first)
        harness.model.perform(.downscale, on: card)
        #expect(await eventually { harness.requests.requests.count == 2 && card.result != nil })
        harness.model.fit(card, under: 20_000)
        #expect(await eventually { harness.requests.requests.count == 3 && card.result != nil })
        card.removedMetadata = [.location]
        #expect(card.presentation.restorable)
        #expect(FloatingResultView.actions(card.presentation, level: .detail).contains(.keepMetadata), "and for VoiceOver")
        harness.model.perform(.keepMetadata, on: card)
        #expect(await eventually { harness.requests.requests.count == 4 && card.result != nil })
        let again = try #require(harness.requests.requests.last)
        #expect(again.stripMetadata == false)
        #expect(again.downscale == 0.5 && again.targetBytes == 20_000, "the scale and the fit made again")
    }

    @Test func convertAndDownscaleRunAgainFromTheOriginal() async throws {
        let harness = Harness()
        let file = harness.temp.file("a.png", bytes: 100_000)
        _ = await harness.model.run(harness.job(file))
        let first = try #require(harness.model.cards.first)
        harness.model.perform(.convert(.webp), on: first)
        #expect(await eventually { harness.requests.requests.count == 2 && first.result != nil })
        #expect(harness.model.cards.count == 1, "the new result shows on the same card")
        #expect(first.choice.format == .webp)
        let converted = try #require(harness.requests.requests.last)
        #expect(converted.format == .webp)
        #expect(converted.sources == [file])
        #expect(harness.model.cards.first?.result?.bytesBefore == 100_000, "it started from the restored original")

        let second = try #require(harness.model.cards.first)
        harness.model.perform(.downscale, on: second)
        #expect(await eventually { harness.requests.requests.count == 3 && second.result != nil })
        #expect(harness.requests.requests.last?.downscale == 0.5)
        #expect(harness.requests.requests.last?.format == .webp, "the card's choice stays; downscale adds to it")
    }

    @Test func retryOnAnErrorRunsTheFileAgain() async throws {
        // The delay holds the engine between logging the request and failing, the window a busy
        // CI runner opens by chance.
        let harness = Harness(failure: .toolMissing("ffmpeg"), delay: .milliseconds(300))
        _ = await harness.model.run(harness.job(harness.temp.file("a.mov")))
        let card = try #require(harness.model.cards.first)
        harness.model.perform(.retry, on: card)
        // The engine logs the request before it throws; the card turns to an error only after
        // the job has settled, so wait for that, not for the request.
        #expect(await eventually {
            harness.requests.requests.count == 2 && harness.model.cards.first.map { $0.id != card.id && !$0.isWorking } == true
        })
        #expect(harness.model.cards.count == 1)
        #expect(harness.model.cards.first?.presentation.tone == .error, "the fake engine still fails")
    }

    @Test func onlyOneDetailIsOpenAndOnlyTheNewestThreeShow() async throws {
        let harness = Harness()
        for name in ["a", "b", "c", "d"] {
            _ = await harness.model.run(harness.job(harness.temp.file("\(name).png")))
        }
        #expect(harness.model.cards.count == 4)
        #expect(harness.model.visibleCards.map(\.id) == harness.model.cards.suffix(3).map(\.id), "older ones live on in Recent Results")
        let (first, second) = (harness.model.cards[1], harness.model.cards[2])
        harness.model.interact(first, .openDetail)
        #expect(first.machine.level == .detail)
        harness.model.interact(second, .openDetail)
        #expect(second.machine.level == .detail)
        #expect(first.machine.level == .thumbnail, "details never stack")
    }

    /// With VoiceOver on, a result never hides on a timer: VoiceOver reaches it at its own pace.
    @Test func noAutoHideUnderVoiceOver() async throws {
        let harness = Harness()
        var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
        harness.model.now = { clock }
        harness.model.voiceOverRunning = { true }
        _ = await harness.model.run(harness.job(harness.temp.file("a.png")))
        let card = try #require(harness.model.cards.first)
        #expect(card.machine.hideDeadline == nil)
        clock += 3600
        harness.model.advance(card)
        #expect(harness.model.cards.count == 1)
        // A card with the keyboard focus waits too, VoiceOver or not.
        harness.model.voiceOverRunning = { false }
        _ = await harness.model.run(harness.job(harness.temp.file("b.png")))
        let focused = try #require(harness.model.cards.last)
        harness.model.interact(focused, .focus(true))
        clock += 3600
        harness.model.advance(focused)
        #expect(harness.model.cards.contains { $0 === focused })
    }

    @Test func anOpenDetailHidesOnTheModelsClockOnceClosed() async throws {
        let harness = Harness()
        var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
        harness.model.now = { clock }
        _ = await harness.model.run(harness.job(harness.temp.file("a.png")))
        let card = try #require(harness.model.cards.first)
        harness.model.interact(card, .pointerEntered)
        clock += 5
        harness.model.advance(card)
        #expect(card.machine.level == .thumbnail, "a resting pointer never opens the detail")
        harness.model.interact(card, .openDetail)
        clock += 3600
        harness.model.advance(card)
        #expect(harness.model.cards.count == 1, "an open detail stays")
        harness.model.interact(card, .closeDetail)
        harness.model.interact(card, .pointerExited)
        clock += 3600
        harness.model.advance(card)
        #expect(harness.model.cards.count == 1, "the time ran out while it was open: two more seconds")
        clock += 2
        harness.model.advance(card)
        #expect(harness.model.cards.isEmpty)
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [JobEvent] = []

    func add(_ event: JobEvent) { lock.withLock { events.append(event) } }

    var kinds: [String] {
        lock.withLock {
            events.compactMap {
                switch $0 {
                case .progress: return nil
                case .result: return "result"
                case .failure: return "failure"
                }
            }
        }
    }
}
