// SPDX-License-Identifier: GPL-3.0-or-later
//
// Where work comes from inside the app: the clipboard watcher, the drop zone and the hotkeys.

import AppKit
import EsclopCore
import EsclopIPC
import EsclopOptimisers
import Foundation
import UniformTypeIdentifiers

extension AppModel {
    // MARK: Clipboard

    /// What the clipboard watcher decided. Runs on the main actor, after the pasteboard reads.
    public func handleClipboard(_ action: ClipboardAction) {
        if case .ignore = action { return }
        // Our own write, back again without its marker (a clipboard manager or another app copied
        // it on): it is a result already, not a new copy.
        switch action {
        case let .optimiseImage(data, _) where ownWrites.contains(ClipboardFingerprint(data: data)):
            return
        case let .optimiseFiles(urls) where urls.allSatisfy({ ClipboardFingerprint(file: $0).map(ownWrites.contains) ?? false }):
            return
        default:
            break
        }
        if skipNextCopy {
            skipNextCopy = false
            return
        }
        // The app in front and the pasteboard types are origin signals; read them now, while the
        // copy is fresh.
        let copy = CopyMoment(app: frontmostApp(), types: Set((pasteboard.types ?? []).map(\.rawValue)))
        switch action {
        case .ignore:
            return
        case let .optimiseImage(data, type):
            optimiseImageData(data, type: type, aggressive: false, copy: copy)
        case let .optimiseFiles(urls):
            optimise(urls, origin: .clipboard, copy: copy)
        }
    }

    /// The app in front and the pasteboard types at the moment of a copy.
    struct CopyMoment {
        var app: String?
        var types: Set<String>
    }

    /// Origin, format and rule for a copied file, read before it is optimised (stripping
    /// metadata removes the screenshot mark). A rule replaces the default choice.
    func clipboardContext(for file: URL, copy: CopyMoment, aggressive: Bool) async -> CardContext {
        let signals = await OriginSignals.read(file, sourceApp: copy.app, pasteboardTypes: copy.types)
        let origin = OriginClassifier.classify(signals)
        if !aggressive, let rule = rules.rule(origin: origin, inputType: signals.inputType) {
            return CardContext(origin: origin, inputType: signals.inputType, choice: rule.choice, rule: rule)
        }
        return CardContext(origin: origin, inputType: signals.inputType, choice: OptimiseChoice(compression: aggressive ? .aggressive : .adaptive))
    }

    /// Optimises files; results go back on the clipboard when they came from it and the setting
    /// says so.
    public func optimise(_ urls: [URL], origin: RequestOrigin, aggressive: Bool = false) {
        optimise(urls, origin: origin, aggressive: aggressive, copy: nil)
    }

    func optimise(_ urls: [URL], origin: RequestOrigin, aggressive: Bool = false, copy: CopyMoment?) {
        let copyBack = origin == .clipboard && EsclopSettings.autoCopyToClipboard.value(in: settings)
        // Too many for floating results: one batch window for all of them.
        let batch = urls.count >= batchThreshold ? openBatch(origin: origin) : nil
        // Every file shows in the window at once, waiting, before its job starts.
        for url in urls { batch?.add(url, bytes: Self.size(of: url)) }
        for url in urls {
            let base = factory.job(for: url, origin: origin, aggressive: aggressive)
            Task {
                var job = base
                var context: CardContext?
                if origin == .clipboard {
                    let found = await clipboardContext(for: url, copy: copy ?? CopyMoment(app: nil, types: []), aggressive: aggressive)
                    if found.rule != nil { found.choice.apply(to: &job.request) }
                    context = found
                }
                await run(job, context: context, batch: batch, onResult: { result in
                    guard copyBack else { return }
                    // A batch puts every finished file back, not only the last one.
                    let files = batch.map { $0.rows.compactMap { $0.result?.output } } ?? [result.output]
                    self.writeClipboard(files: files)
                })
            }
        }
    }

    /// Copied pixels: saved to a temporary file, optimised in place (the backup is the original),
    /// then put back on the clipboard.
    func optimiseImageData(_ data: Data, type: UTType, aggressive: Bool, copy: CopyMoment? = nil) {
        let file: URL
        do {
            guard let url = try Clipboard.materialise(.image(data, type)).first else { return }
            file = url
        } catch {
            notice(Strings.text("Could not read the copied image"), CardPresentation.message(for: error))
            return
        }
        let copyBack = EsclopSettings.autoCopyToClipboard.value(in: settings)
        let base = factory.job(for: file, origin: .clipboard, aggressive: aggressive, location: .inPlace)
        Task {
            var job = base
            let context = await clipboardContext(for: file, copy: copy ?? CopyMoment(app: nil, types: []), aggressive: aggressive)
            if context.rule != nil { context.choice.apply(to: &job.request) }
            await run(job, displayName: Strings.text("Copied image"), context: context, onResult: { result in
                guard copyBack else { return }
                self.writeClipboard(files: [result.output])
            })
        }
    }

    /// The hotkey and menu command: whatever is on the clipboard now, whatever the automatic
    /// rules say. Harder re-runs the last optimised copy from its original, as Clop does.
    public func optimiseClipboardNow(aggressive: Bool) {
        let content = Clipboard.read(pasteboard)
        if aggressive, Clipboard.isOwnWrite(pasteboard), case let .files(urls) = content,
           let result = recent.first(where: { r in urls.contains { $0.standardizedFileURL == r.output.standardizedFileURL } }),
           result.backup != nil
        {
            Task {
                await restore(result)
                if let card = cards.first(where: { $0.result?.id == result.id || $0.jobID == result.id }) { dismiss(card) }
                optimiseAgain(result.source, wasClipboardImage: result.source.path.hasPrefix(Paths.temporary.path))
            }
            return
        }
        // The clipboard already holds one of L'Esclop's results: show that result again instead
        // of optimising it a second time (which made a twin card with no saving).
        if !aggressive, let shown = ownResult(on: content) {
            shown()
            return
        }
        switch content {
        case let .files(urls):
            let media = urls.filter { MediaKind.of($0) != nil }
            guard !media.isEmpty else { return notice(Strings.text("Nothing to optimise"), Strings.text("The copied files are not images, videos, PDFs or audio.")) }
            optimise(media, origin: .clipboard, aggressive: aggressive)
        case let .path(url):
            optimise([url], origin: .clipboard, aggressive: aggressive)
        case let .image(data, type), let .base64Image(data, type):
            optimiseImageData(data, type: type, aggressive: aggressive)
        case .empty:
            notice(Strings.text("Nothing to optimise"), Strings.text("Copy an image or a file first."))
        }
    }

    /// What to do when the clipboard holds a result L'Esclop wrote: refresh its card, or bring
    /// it back from Recent Results. nil when the clipboard holds something else.
    private func ownResult(on content: ClipboardContent) -> (() -> Void)? {
        guard isOwnClipboardContent(content) else { return nil }
        guard case let .files(urls) = content else { return {} }
        let paths = Set(urls.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        func holds(_ url: URL) -> Bool { paths.contains(url.standardizedFileURL.resolvingSymlinksInPath().path) }
        if let card = cards.first(where: { holds($0.shownFile) }) {
            return { [weak self] in self?.settle(card) }
        }
        if let result = recent.first(where: { holds($0.output) }) {
            return { [weak self] in self?.show(result) }
        }
        return {}
    }

    private func optimiseAgain(_ source: URL, wasClipboardImage: Bool) {
        let location: OutputLocation? = wasClipboardImage ? .inPlace : nil
        let job = factory.job(for: source, origin: .clipboard, aggressive: true, location: location)
        let copyBack = EsclopSettings.autoCopyToClipboard.value(in: settings)
        Task {
            await run(job, displayName: wasClipboardImage ? Strings.text("Copied image") : nil, onResult: { result in
                guard copyBack else { return }
                self.writeClipboard(files: [result.output])
            })
        }
    }

    // MARK: Menu

    /// "Optimise Files…": files or folders chosen in an open panel. Many go to the batch window.
    public func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = Strings.text("Optimise")
        panel.message = Strings.text("Choose images, videos, PDFs, audio or folders to optimise.")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        optimiseChosen(panel.urls)
    }

    /// Files and folders (searched recursively) to optimise as if dropped.
    public func optimiseChosen(_ urls: [URL]) {
        let files = PathInput.expand(urls, recursive: true).filter { MediaKind.of($0) != nil }
        guard !files.isEmpty else { return notice(Strings.text("Nothing to optimise"), Strings.text("Choose images, videos, PDFs or audio files.")) }
        optimise(files, origin: .app)
    }

    // MARK: Drop zone

    public func optimiseDropped(_ urls: [URL], harder: Bool) {
        let files = PathInput.expand(urls, recursive: true).filter { MediaKind.of($0) != nil }
        guard !files.isEmpty else { return notice(Strings.text("Nothing to optimise"), Strings.text("Drop images, videos, PDFs or audio files.")) }
        optimise(files, origin: .dropZone, aggressive: harder)
    }

    // MARK: Pause

    /// The pause hotkey cycles like Clop's: running, then skip the next copy, then paused.
    public func cyclePause() {
        if paused {
            setPaused(false)
            notice(Strings.text("Running"), Strings.text("Watching the clipboard again."))
        } else if skipNextCopy {
            skipNextCopy = false
            setPaused(true)
            notice(Strings.text("Paused"), Strings.text("Automatic optimisation is off until you resume it."))
        } else {
            skipNextCopy = true
            notice(Strings.text("Skipping the next copy"), Strings.text("Press again to pause everything."))
        }
    }
}
