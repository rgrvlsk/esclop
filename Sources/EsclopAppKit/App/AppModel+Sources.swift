// SPDX-License-Identifier: GPL-3.0-or-later
//
// Where work comes from inside the app: the clipboard watcher, the drop zone and the hotkeys. A
// saved pipeline with the `clipboard` or `dropZone` trigger runs instead of the plain optimisation
// for the kinds of file it has steps for.

import AppKit
import EsclopCore
import EsclopIPC
import EsclopOptimisers
import EsclopPipelines
import Foundation
import UniformTypeIdentifiers

extension AppModel {
    // MARK: Clipboard

    /// What the clipboard watcher decided, with the copy it decided on.
    public func handleClipboard(_ action: ClipboardAction) {
        switch action {
        case .ignore:
            return
        case let .optimiseImage(data, type, copy):
            Task {
                // Our own write, back again without its marker: a result already, not a new copy.
                guard await !clipboard.run({ $0.isOwnBytes(.image(data, type)) }) else { return }
                optimiseImageData(data, type: type, aggressive: false, copy: copy, pipeline: { self.pipeline(for: .clipboard, file: $0) })
            }
        case let .optimiseFiles(urls, copied, copy):
            Task {
                guard await !clipboard.run({ $0.isOwnBytes(.files(urls)) }) else { return }
                optimise(urls, origin: .clipboard, copy: copy, copied: copied, pipeline: { self.pipeline(for: .clipboard, file: $0) })
            }
        }
    }

    /// Origin, format and rule for a copied file, read before it is optimised (stripping
    /// metadata removes the screenshot mark). A rule replaces the default choice.
    /// A pipeline that runs instead takes the rule's place.
    func clipboardContext(for file: URL, copy: ClipboardCopy, aggressive: Bool, pipeline: Pipeline? = nil) async -> CardContext {
        let signals = await OriginSignals.read(file, sourceApp: copy.app, pasteboardTypes: copy.types)
        let origin = OriginClassifier.classify(signals)
        if !aggressive, pipeline == nil, let rule = rules.rule(origin: origin, inputType: signals.inputType) {
            return CardContext(origin: origin, inputType: signals.inputType, choice: rule.choice, rule: rule)
        }
        return CardContext(origin: origin, inputType: signals.inputType, choice: OptimiseChoice(compression: aggressive ? .aggressive : .adaptive))
    }

    /// Optimises files; results go back on the clipboard when they came from it and the setting
    /// says so.
    public func optimise(_ urls: [URL], origin: RequestOrigin, aggressive: Bool = false) {
        optimise(urls, origin: origin, aggressive: aggressive, copy: nil)
    }

    /// `copied` is everything the copy put on the clipboard, in order (`urls` when nil). When the
    /// last file is done, the results go back in the places of their originals, once. `pipeline`
    /// is the pipeline that runs on a file instead of the plain optimisation, if any; `adjust` changes
    /// each job (Finder's Convert to WebP).
    func optimise(
        _ urls: [URL], origin: RequestOrigin, aggressive: Bool = false, copy: ClipboardCopy?, copied: [URL]? = nil,
        adjust: @escaping (inout OptimisationJob) -> Void = { _ in }, pipeline: (URL) -> Pipeline? = { _ in nil }
    ) {
        let copyBack = origin == .clipboard && EsclopSettings.autoCopyToClipboard.value(in: settings)
        if copyBack, let copy { holdOnClipboard(copied ?? urls, at: copy.changeCount) }
        let putBack = PutBack()
        let pipelines = urls.map(pipeline)
        // A pipeline that hides its result keeps its files out of the batch window too.
        let shown = zip(urls, pipelines).filter { !($0.1?.hideResult ?? false) }.map(\.0)
        // Too many for floating results: one batch window for all of them.
        let batch = shown.count >= batchThreshold ? openBatch(origin: origin) : nil
        // Every file shows in the window at once, waiting, before its job starts.
        for url in shown { batch?.add(url, bytes: Self.size(of: url)) }
        // Every result, a retried file's too; one retried after the rest went back goes on its own.
        let onResult: ((OptimisationResult) -> Void)? = copyBack ? { result in
            putBack.results.append((result.source, result.output))
            if putBack.done { Task { await self.putBackOnClipboard([(result.source, result.output)]) } }
        } : nil
        var runs: [Task<Void, Never>] = []
        for (url, triggered) in zip(urls, pipelines) {
            var base = factory.job(for: url, origin: origin, aggressive: aggressive)
            if let triggered { Self.use(triggered, in: &base) }
            runs.append(Task {
                var job = base
                adjust(&job)
                var context: CardContext?
                if origin == .clipboard {
                    context = await clipboardContext(for: url, copy: copy ?? ClipboardCopy(changeCount: 0), aggressive: aggressive, pipeline: triggered)
                    if let context, context.rule != nil { context.choice.apply(to: &job.request) }
                }
                await run(job, context: context, batch: job.request.showResultUI ? batch : nil, onResult: onResult)
            })
        }
        guard copyBack else { return }
        Task {
            for run in runs { await run.value }
            putBack.done = true
            await putBackOnClipboard(putBack.results)
        }
    }

    /// The results of one copy, gathered until its last file is done (a retry's result arrives
    /// only through `onResult`, not in the first run's report).
    @MainActor private final class PutBack {
        var results: [(old: URL, new: URL)] = []
        var done = false
    }

    /// Copied pixels: saved to a temporary file, optimised in place (the backup is the original),
    /// then put back on the clipboard.
    func optimiseImageData(_ data: Data, type: UTType, aggressive: Bool, copy: ClipboardCopy, pipeline: (URL) -> Pipeline? = { _ in nil }) {
        let file: URL
        do {
            guard let url = try Clipboard.materialise(.image(data, type)).first else { return }
            file = url
        } catch {
            notice(Strings.text("Could not read the copied image"), CardPresentation.message(for: error))
            return
        }
        let copyBack = EsclopSettings.autoCopyToClipboard.value(in: settings)
        // The file stands for the copied pixels on the clipboard.
        if copyBack { holdOnClipboard([file], at: copy.changeCount) }
        var base = factory.job(for: file, origin: .clipboard, aggressive: aggressive, location: .inPlace)
        let triggered = pipeline(file)
        if let triggered { Self.use(triggered, in: &base) }
        Task {
            var job = base
            let context = await clipboardContext(for: file, copy: copy, aggressive: aggressive, pipeline: triggered)
            if context.rule != nil { context.choice.apply(to: &job.request) }
            await run(job, displayName: Strings.text("Copied image"), context: context, onResult: { result in
                guard copyBack else { return }
                Task { await self.putBackOnClipboard([(result.source, result.output)]) }
            })
        }
    }

    /// The hotkey and menu command: whatever is on the clipboard now, whatever the automatic
    /// rules say. Harder re-runs the last optimised copy from its original, as Clop does.
    public func optimiseClipboardNow(aggressive: Bool) {
        Task { await optimiseClipboard(aggressive: aggressive) }
    }

    /// A pipeline's own hotkey: the pipeline runs on whatever is on the clipboard now, also on a
    /// result L'Esclop put there.
    public func runOnClipboard(_ pipeline: Pipeline) {
        Task { await optimiseClipboard(aggressive: false, pipeline: pipeline) }
    }

    func optimiseClipboard(aggressive: Bool, pipeline: Pipeline? = nil) async {
        let now = await clipboard.run { $0.snapshot() }
        let content = now.content
        if pipeline == nil, aggressive, now.marked, case let .files(urls) = content,
           let result = recent.first(where: { r in urls.contains { $0.standardizedFileURL == r.output.standardizedFileURL } }),
           result.backup != nil || result.output != result.source
        {
            // The result may be on the clipboard from before a relaunch, or from `esclop --copy`.
            holdOnClipboard(urls, at: now.count)
            // In place, the original comes back first; a copy elsewhere left it untouched.
            if result.backup != nil { guard await restore(result) else { return } }
            if let card = cards.first(where: { $0.result?.id == result.id || $0.jobID == result.id }) { dismiss(card) }
            optimiseAgain(result)
            return
        }
        // The clipboard already holds one of L'Esclop's results: show that result again instead
        // of optimising it a second time (which made a twin card with no saving).
        if pipeline == nil, !aggressive, now.own {
            ownResult(on: content)
            return
        }
        let copy = ClipboardCopy(changeCount: now.count)
        switch content {
        case let .files(urls):
            let media = urls.filter { MediaKind.of($0) != nil }
            guard !media.isEmpty else { return notice(Strings.text("Nothing to optimise"), Strings.text("The copied files are not images, videos, PDFs or audio.")) }
            optimise(media, origin: .clipboard, aggressive: aggressive, copy: copy, copied: urls, pipeline: { _ in pipeline })
        case let .path(url):
            optimise([url], origin: .clipboard, aggressive: aggressive, copy: copy, pipeline: { _ in pipeline })
        case let .image(data, type), let .base64Image(data, type):
            optimiseImageData(data, type: type, aggressive: aggressive, copy: copy, pipeline: { _ in pipeline })
        case .empty:
            notice(Strings.text("Nothing to optimise"), Strings.text("Copy an image or a file first."))
        }
    }

    /// The clipboard holds a result L'Esclop wrote: refresh its card, or bring it back from
    /// Recent Results.
    private func ownResult(on content: ClipboardContent) {
        guard case let .files(urls) = content else { return }
        let paths = Set(urls.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        func holds(_ url: URL) -> Bool { paths.contains(url.standardizedFileURL.resolvingSymlinksInPath().path) }
        if let card = cards.first(where: { holds($0.shownFile) }) {
            settle(card)
        } else if let result = recent.first(where: { holds($0.output) }) {
            show(result)
        }
    }

    /// Harder, from the original of `previous`; the new result takes its place on the clipboard.
    private func optimiseAgain(_ previous: OptimisationResult) {
        let wasClipboardImage = Self.isCopiedImage(previous.source)
        let location: OutputLocation? = wasClipboardImage ? .inPlace : nil
        let job = factory.job(for: previous.source, origin: .clipboard, aggressive: true, location: location)
        let copyBack = EsclopSettings.autoCopyToClipboard.value(in: settings)
        Task {
            await run(job, displayName: wasClipboardImage ? Strings.text("Copied image") : nil, onResult: { result in
                guard copyBack else { return }
                Task { await self.putBackOnClipboard([(previous.output, result.output), (previous.source, result.output)]) }
            })
        }
    }

    /// A file L'Esclop saved from copied pixels (it is optimised in place; the backup is the copy).
    nonisolated static func isCopiedImage(_ file: URL) -> Bool {
        file.standardizedFileURL.path.hasPrefix(Clipboard.folder.standardizedFileURL.path + "/")
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
        // Harder is a plain optimisation the person asked for; a plain drop runs a drop-zone pipeline.
        optimise(files, origin: .dropZone, aggressive: harder, copy: nil, pipeline: { harder ? nil : self.pipeline(for: .dropZone, file: $0) })
    }

    /// The saved pipeline that runs instead of the plain optimisation for a file from `trigger`:
    /// the first by name with that trigger and steps for the file's kind.
    func pipeline(for trigger: PipelineTrigger, file: URL) -> Pipeline? {
        guard let kind = MediaKind.of(file) else { return nil }
        return ((try? service.context.pipelines.list()) ?? [])
            .filter { $0.triggers.contains(trigger) && !$0.steps(for: kind).isEmpty }
            .min { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Files dropped on a preset zone: the pipeline runs on each, through the usual floating
    /// results, or the batch window from `batchWindowFrom` files, like a plain drop.
    public func runPresetZone(_ name: String, on urls: [URL]) {
        let files = PathInput.expand(urls, recursive: true).filter { MediaKind.of($0) != nil }
        guard !files.isEmpty else { return notice(Strings.text("Nothing to optimise"), Strings.text("Drop images, videos, PDFs or audio files.")) }
        var zone = (try? service.context.pipelines.resolve(name)) ?? Pipeline(name: name, steps: [])
        zone.name = name
        optimise(files, origin: .dropZone, aggressive: false, copy: nil, pipeline: { _ in zone })
    }
}
