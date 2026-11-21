// SPDX-License-Identifier: GPL-3.0-or-later
//
// What the options popover does to its file (DESIGN.md › Options popover). Every change that
// alters the file runs the same engine operations as the hover buttons, from the original.

import AppKit
import EsclopCore
import EsclopIPC
import EsclopOptimisers
import EsclopPipelines
import Foundation
import Quartz
import UniformTypeIdentifiers

extension AppModel {
    // MARK: Optimise

    /// Runs the file again with `choice` (a suggestion, a format tile, the compression...).
    public func apply(_ choice: OptimiseChoice, to card: ResultCard) {
        reprocess(card, choice: choice)
    }

    /// ⌥ on a format tile: a converted copy next to the file, keeping both. It reads the
    /// original (the backup while a result stands) and lands beside the file the person sees,
    /// under the original's name, never in the backups folder.
    public func convertKeepingBoth(_ card: ResultCard, to format: OutputFormat) {
        guard let original = originalFile(of: card) else { return }
        let name = (card.result?.source ?? original).lastPathComponent
        let beside = card.shownFile.deletingLastPathComponent().appendingPathComponent(name)
        let target = OutputLocation.sameFolder.destination(
            for: beside, extension: format.fileExtension,
            sameFolderTemplate: EsclopSettings.sameFolderNameTemplate.value(in: settings)
        )
        // ponytail: `.path` expands %f, %e and %d, so a folder or name holding one of them lands
        // wrong; add an exact-file location case if someone hits it.
        var job = factory.job(for: original, origin: .app, location: .path(target.path))
        // Asked for on a card on screen: the copy shows, whatever "Show floating results" says.
        job.request.showResultUI = true
        var choice = card.choice
        choice.format = format
        choice.apply(to: &job.request)
        // The steps the card keeps, as its own re-runs make them.
        job.request.crop = card.crop
        job.request.downscale = card.downscale < 1 ? card.downscale : nil
        if let fit = card.fit { job.operation = .fit(underBytes: fit) }
        Task { await run(job) }
    }

    // MARK: Size

    /// Scales from the original, keeping the crop and the fit; 1 is the original itself, with no
    /// crop, scale or fit left over.
    public func downscale(_ card: ResultCard, to factor: Double) {
        guard factor < 1 else {
            return reprocess(card) { $0.request.downscale = nil; $0.request.crop = nil; $0.operation = .optimise }
        }
        reprocess(card) { $0.request.downscale = factor }
    }

    public func fit(_ card: ResultCard, under bytes: Int) {
        reprocess(card) { $0.operation = .fit(underBytes: bytes) }
    }

    /// The chosen Fit chip again: the fit comes off, the crop and the scale stay.
    public func removeFit(_ card: ResultCard) {
        reprocess(card) { $0.operation = .optimise }
    }

    public func crop(_ card: ResultCard, to size: CropSize) {
        reprocess(card) { $0.request.crop = size }
    }

    /// The Crop tab's Reset on a cropped file: the whole picture again, the scale kept.
    public func removeCrop(_ card: ResultCard) {
        reprocess(card) { $0.request.crop = nil }
    }

    /// PDFs crop by setting each page's crop box to the aspect ratio.
    /// ponytail: a PDF's crop box is not kept on the card, so another choice runs it uncropped.
    /// Trigger: someone re-running a cropped PDF with another compression.
    public func cropPDF(_ card: ResultCard, aspect ratio: Double) {
        reprocess(card) { $0.operation = .cropPDF(PDFCropSpec(aspectRatio: ratio)) }
    }

    // MARK: Rules

    /// The rule checkbox: ticking stores the card's choice for its origin and input format,
    /// unticking deletes it. Only the rule changes; the file stays as it is.
    public func setRule(_ on: Bool, for card: ResultCard) {
        guard let origin = card.fileOrigin, let inputType = card.inputType else { return }
        do {
            if on {
                let rule = ClipboardRule(origin: origin, inputType: inputType, choice: card.choice)
                try rules.save(rule)
                card.appliedRule = rule
            } else {
                try rules.delete(origin: origin, inputType: inputType)
                card.appliedRule = nil
            }
        } catch {
            notice(Strings.text("Could not save the rule"), CardPresentation.message(for: error))
        }
    }

    /// The stored rule for the card's origin and input format.
    public func storedRule(for card: ResultCard) -> ClipboardRule? {
        guard let origin = card.fileOrigin, let inputType = card.inputType else { return nil }
        return rules.rule(origin: origin, inputType: inputType)
    }

    // MARK: Origin

    /// Classifies a card's file when the popover first opens, if the copy did not already.
    public func classify(_ card: ResultCard) async {
        guard card.fileOrigin == nil, let original = originalFile(of: card) else { return }
        let signals = await OriginSignals.read(original)
        card.inputType = signals.inputType
        card.fileOrigin = OriginClassifier.classify(signals)
    }

    /// The untouched original: the backup while a result stands, else the file itself.
    public func originalFile(of card: ResultCard) -> URL? {
        switch card.phase {
        case let .done(result): return result.backup ?? result.source
        case let .restored(result): return result.source
        case .unchanged, .failed: return card.source
        case .working, .notice: return nil
        }
    }

    // MARK: File

    /// Renames the shown file; the clipboard follows when it held it.
    @discardableResult
    public func rename(_ card: ResultCard, to name: String) -> Bool {
        guard case let .done(result) = card.phase else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !trimmed.isEmpty, trimmed != result.output.deletingPathExtension().lastPathComponent else { return false }
        let target = result.output.deletingLastPathComponent().appendingPathComponent(trimmed).appendingPathExtension(result.output.pathExtension)
        guard !FileManager.default.fileExists(atPath: target.path) else { return false }
        do {
            try FileManager.default.moveItem(at: result.output, to: target)
        } catch {
            return false
        }
        var renamed = result
        renamed.output = target
        if result.source == result.output { renamed.source = target }
        card.phase = .done(renamed)
        card.displayName = nil
        record(renamed)
        Task { await putBackOnClipboard([(result.output, target)]) }
        return true
    }

    // MARK: Share

    public func saveAs(_ card: ResultCard) {
        let file = card.shownFile
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.lastPathComponent
        if let type = UTType(filenameExtension: file.pathExtension) { panel.allowedContentTypes = [type] }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            try Self.saveCopy(of: file, to: target)
        } catch {
            failed(Strings.format("Could not save %@", target.lastPathComponent), error)
        }
    }

    /// Copies `file` to `target`, replacing what is there only once the copy is whole: the copy
    /// goes beside the target first. Saving a file onto itself leaves it as it is.
    static func saveCopy(of file: URL, to target: URL) throws {
        guard target.standardizedFileURL.resolvingSymlinksInPath() != file.standardizedFileURL.resolvingSymlinksInPath() else { return }
        let fm = FileManager.default
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).esclop-\(UUID().uuidString.prefix(8))")
        try fm.copyItem(at: file, to: staging)
        do {
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: target)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Moves an optimised file to the Trash and removes its card. Its backup stays, as for any
    /// result; Finder's Put Back brings the file back.
    func trash(_ card: ResultCard) {
        guard case .done = card.phase, !card.actsAsCopiedImage else { return }
        do {
            try FileManager.default.trashItem(at: card.shownFile, resultingItemURL: nil)
            dismiss(card)
            announce(Strings.text("Moved to the Trash"))
        } catch {
            failed(Strings.format("Could not move %@ to the Trash", card.shownFile.lastPathComponent), error)
        }
    }

    // MARK: Beside the file

    /// A PDF's pages as optimised images in a new folder beside it, named as `esclop pdf pages`
    /// names it ("Dossier pages", else "Dossier pages 2"), on a card of its own that stands for
    /// the folder. The folder holds only this export, so the card's Trash, and Stop or a failure
    /// (which remove it), never touch anything else.
    func exportPages(_ card: ResultCard) {
        let pdf = card.shownFile
        let folder = OutputLocation.unique(pdf.deletingLastPathComponent()
            .appendingPathComponent(pdf.deletingPathExtension().lastPathComponent + " pages", isDirectory: true))
        let pagesCard = ResultCard(jobID: UUID(), source: pdf, origin: .app, bytesBefore: Self.size(of: pdf))
        pagesCard.displayName = folder.lastPathComponent
        add(pagesCard)
        let engine = EsclopEngine(settings: settings)
        let started = now()
        let task = Task { [weak self, weak pagesCard] in
            do {
                let pages = try await engine.extractPDFPages(pdf, format: nil, to: folder)
                try Task.checkCancellation()
                guard let self, let pagesCard else { return }
                noteWritten(pages + [folder])
                pagesCard.pages = pages.count
                pagesCard.phase = .done(OptimisationResult(
                    source: pdf, output: folder, kind: .image, bytesBefore: pagesCard.bytesBefore,
                    bytesAfter: pages.reduce(0) { $0 + Self.size(of: $1) }, startedAt: started, finishedAt: now()
                ))
                if let first = pages.first { loadThumbnail(pagesCard, url: first) }
                settle(pagesCard)
                announce(pages.count == 1
                    ? Strings.format("Saved 1 page in %@", folder.lastPathComponent)
                    : Strings.format("Saved %d pages in %@", pages.count, folder.lastPathComponent))
            } catch {
                try? FileManager.default.removeItem(at: folder)
                guard let self else { return }
                if let pagesCard { dismiss(pagesCard) }
                if !Task.isCancelled { failed(Strings.format("Could not save the pages of %@", pdf.lastPathComponent), error) }
            }
        }
        pagesCard.cancelWork = { task.cancel() }
    }

    /// An audio file's cover art, saved beside it and optimised as a result of its own. It comes
    /// from the original while that is kept: optimising may have made the cover smaller.
    func extractCover(_ card: ResultCard) {
        let audio = card.shownFile
        let source = originalFile(of: card) ?? audio
        let engine = EsclopEngine(settings: settings)
        Task {
            do {
                let cover = try await engine.extractCover(
                    source, to: audio.deletingLastPathComponent(), name: audio.deletingPathExtension().lastPathComponent
                )
                noteWritten([cover])
                optimise([cover], origin: .app)
            } catch {
                failed(Strings.format("Could not extract the cover of %@", audio.lastPathComponent), error)
            }
        }
    }

    /// Extract Cover is offered only for audio whose original carries cover art. Like the
    /// pictures, it is read only when the app loads them (not in most tests).
    func lookForCover(_ card: ResultCard) {
        guard loadsThumbnails, MediaKind.of(card.shownFile) == .audio, let file = originalFile(of: card) else { return }
        let engine = EsclopEngine(settings: settings)
        Task { [weak card] in
            let found = await engine.hasCoverArt(file)
            card?.hasCoverArt = found
        }
    }

    /// Saves a copied image to Downloads in one click, named for what it is and when it was made:
    /// "Copied image 2026-11-14 09.41.12.png". A copied image otherwise lives in a temporary folder.
    /// ponytail: always Downloads. The specific-folder setting resolves into that temporary folder
    /// for a copied image; honour it here once someone sets an absolute folder and asks.
    func save(_ card: ResultCard) {
        guard let result = card.result else { return }
        let file = card.shownFile
        let stamp = Self.saveStamp.string(from: result.finishedAt)
        let base = (card.displayName ?? file.deletingPathExtension().lastPathComponent) + " " + stamp
        let target = Self.unused(base, extension: file.pathExtension, in: downloads())
        do {
            try FileManager.default.copyItem(at: file, to: target)
            card.savedCopy = target
            announce(Strings.text("Saved to Downloads"))
        } catch {
            failed(Strings.format("Could not save %@", target.lastPathComponent), error)
        }
    }

    /// Seen and heard: a notice says why a file action failed, VoiceOver reads it.
    private func failed(_ title: String, _ error: any Error) {
        notice(title, CardPresentation.message(for: error))
        announce(title)
    }

    private static let saveStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    /// "name.png", else "name 2.png", "name 3.png"…
    static func unused(_ base: String, extension ext: String, in folder: URL) -> URL {
        var number = 1
        while true {
            let name = number == 1 ? base : "\(base) \(number)"
            let url = folder.appendingPathComponent(name).appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            number += 1
        }
    }

    public func quickLook(_ card: ResultCard) {
        QuickLookPresenter.shared.show(card.shownFile)
    }

    public func open(_ card: ResultCard, with app: URL) {
        NSWorkspace.shared.open([card.shownFile], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Apps that open the file, the default first.
    public func apps(toOpen card: ResultCard) -> [URL] {
        let file = card.shownFile
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: file)
        if let preferred = NSWorkspace.shared.urlForApplication(toOpen: file) {
            apps.removeAll { $0 == preferred }
            apps.insert(preferred, at: 0)
        }
        return Array(apps.prefix(12))
    }

    /// Shelf and upload apps L'Esclop hands files to, when installed.
    public static let shelfApps = AppPipelineHost.shelves.flatMap(\.bundleIDs)
    public static let uploadApps = AppPipelineHost.uploadApps.flatMap(\.bundleIDs)

    public static func installed(_ bundleIDs: [String]) -> [URL] {
        bundleIDs.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    public func runShortcut(_ name: String, on card: ResultCard) {
        let file = card.shownFile
        Task.detached {
            _ = try? await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/shortcuts"), arguments: ["run", name, "--input-path", file.path])
        }
    }

    /// The person's Shortcuts, by name.
    public static func shortcutNames() async -> [String] {
        guard let result = try? await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/shortcuts"), arguments: ["list"]) else { return [] }
        return String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }.sorted()
    }

    /// The saved pipelines that do something for `kind`.
    public func pipelineNames(for kind: MediaKind?) -> [String] {
        let pipelines = (try? service.context.pipelines.list()) ?? []
        return pipelines.filter { pipeline in kind.map { pipeline.kinds.contains($0) } ?? true }.map(\.name)
    }

    /// Runs a saved pipeline on files the person chose (the pipeline editor's Run), as Finder's
    /// "Run a Pipeline…" does: floating results, or one batch window from `batchWindowFrom` files.
    /// A pipeline that cannot be read fails on each file's card, saying why.
    public func runPipeline(_ name: String, on files: [URL]) {
        let pipeline = try? service.context.pipelines.resolve(name)
        optimise(files, origin: .app, copy: nil, adjust: { $0.operation = .pipeline(name) }, pipeline: { _ in pipeline })
    }

    public func runPipeline(_ name: String, on card: ResultCard) {
        var job = factory.job(for: card.shownFile, origin: .app)
        job.operation = .pipeline(name)
        // Asked for on a card on screen: its result shows, whatever "Show floating results" says.
        job.request.showResultUI = true
        Task { await run(job) }
    }
}

/// Quick Look for one file from a panel that never activates the app.
@MainActor
final class QuickLookPresenter: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookPresenter()
    private var file: URL?

    func show(_ url: URL) {
        file = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Space on a card: shows the file, or closes Quick Look when it shows it already.
    func toggle(_ url: URL) {
        if file == url, QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            show(url)
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { file == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        file as NSURL?
    }
}
