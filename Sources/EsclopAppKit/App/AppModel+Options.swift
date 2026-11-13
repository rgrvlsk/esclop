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

    /// ⌥ on a format tile: a converted copy next to the file, keeping both.
    public func convertKeepingBoth(_ card: ResultCard, to format: OutputFormat) {
        guard let original = originalFile(of: card) else { return }
        var job = factory.job(for: original, origin: .app, location: .sameFolder)
        var choice = card.choice
        choice.format = format
        choice.apply(to: &job.request)
        Task { await run(job) }
    }

    // MARK: Size

    public func downscale(_ card: ResultCard, to factor: Double) {
        reprocess(card) { $0.request.downscale = factor < 1 ? factor : nil }
    }

    public func fit(_ card: ResultCard, under bytes: Int) {
        reprocess(card) { $0.operation = .fit(underBytes: bytes) }
    }

    public func crop(_ card: ResultCard, to size: CropSize) {
        reprocess(card) { $0.request.crop = size }
    }

    /// PDFs crop by setting each page's crop box to the aspect ratio.
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

    public func ruleExists(for card: ResultCard) -> Bool {
        guard let origin = card.fileOrigin, let inputType = card.inputType else { return false }
        return rules.rule(origin: origin, inputType: inputType) != nil
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
        let heldIt = pasteboardHolds(result.output)
        var renamed = result
        renamed.output = target
        if result.source == result.output { renamed.source = target }
        card.phase = .done(renamed)
        card.displayName = nil
        record(renamed)
        if heldIt { writeClipboard(files: [target]) }
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
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: file, to: target)
    }

    /// Moves an optimised file to the Trash and removes its card. Its backup stays, as for any
    /// result; Finder's Put Back brings the file back.
    func trash(_ card: ResultCard) {
        guard case .done = card.phase, card.origin != .clipboard else { return }
        do {
            try FileManager.default.trashItem(at: card.shownFile, resultingItemURL: nil)
            dismiss(card)
            announce(Strings.text("Moved to the Trash"))
        } catch {
            NSSound.beep()
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
            NSSound.beep()
        }
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

    public func airDrop(_ card: ResultCard) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [card.shownFile])
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
    public static let shelfApps = ["at.EternalStorms.Yoink", "at.EternalStorms.Yoink-setapp", "me.damir.dropover-mac", "com.hachipoo.Dockside"]
    public static let uploadApps = ["net.mkswap.Dropshare5", "net.mkswap.Dropshare5-setapp"]

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

    public var pipelineNames: [String] {
        (try? service.context.pipelines.list().map(\.name)) ?? []
    }

    /// Runs a saved pipeline on files the person chose (the pipeline editor's Run).
    public func runPipeline(_ name: String, on files: [URL]) {
        for file in files {
            var job = factory.job(for: file, origin: .app)
            job.operation = .pipeline(name)
            Task { await run(job) }
        }
    }

    public func runPipeline(_ name: String, on card: ResultCard) {
        var job = factory.job(for: card.shownFile, origin: .app)
        job.operation = .pipeline(name)
        Task { await run(job) }
    }

    // MARK: Popover footer

    /// "Keep visible": how long results from this card's origin stay on screen.
    public func keepVisibleSeconds(for card: ResultCard) -> Int? {
        guard EsclopSettings.autoHideFloatingResults.value(in: settings) else { return nil }
        return card.origin == .clipboard
            ? EsclopSettings.autoHideClipboardResultAfter.value(in: settings)
            : EsclopSettings.autoHideFloatingResultsAfter.value(in: settings)
    }

    public func setKeepVisible(_ seconds: Int?, for card: ResultCard) {
        try? EsclopSettings.autoHideFloatingResults.set(seconds != nil, in: settings)
        guard let seconds else { return }
        if card.origin == .clipboard {
            try? EsclopSettings.autoHideClipboardResultAfter.set(seconds, in: settings)
        } else {
            try? EsclopSettings.autoHideFloatingResultsAfter.set(seconds, in: settings)
        }
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

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { file == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        file as NSURL?
    }
}
