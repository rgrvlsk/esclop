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
                let triggered = pipelines(for: .clipboard)
                optimiseImageData(data, type: type, aggressive: false, copy: copy, pipeline: { Self.first(of: triggered, for: $0) })
            }
        case let .optimiseFiles(urls, copied, copy):
            Task {
                guard await !clipboard.run({ $0.isOwnBytes(.files(urls)) }) else { return }
                let triggered = pipelines(for: .clipboard)
                optimise(urls, origin: .clipboard, copy: copy, copied: copied, pipeline: { Self.first(of: triggered, for: $0) })
            }
        case let .optimiseAddress(address, copy):
            let triggered = pipelines(for: .clipboard)
            Task { await optimiseAddress(address, as: .automatic, copy: copy, pipeline: { Self.first(of: triggered, for: $0) }) }
        case let .offerAddress(address, copy):
            offer(address, copy: copy)
        }
    }

    /// How a copied web address came to be downloaded.
    enum AddressRequest {
        /// The hotkey: whatever the clipboard settings say, up to `WebDownload.largest`.
        case asked
        /// A click on the offer: an automatic download (`WebDownload.Terms.automatic`) within the
        /// kind's automatic size limit, whose refusal is a notice.
        case offered
        /// On its own ("Download and optimise"): as offered, a copied file's rules apply to what
        /// arrives, and a refusal is silent: nobody asked, and the watcher sees each copy once.
        case automatic
    }

    /// A copied web address of media, offered on a brief card with its name and host. Nothing is
    /// fetched before the click, which downloads and optimises it as the hotkey does. Each
    /// address is offered once a session; a newer offer takes an older one's place.
    func offer(_ address: URL, copy: ClipboardCopy) {
        guard offeredAddresses.insert(address).inserted else { return }
        cards.filter { $0.noticeAction?.action == .download }.forEach(dismiss)
        notice(address.lastPathComponent, address.host() ?? "", action: (.download, { [weak self] in
            guard let self else { return }
            let triggered = pipelines(for: .clipboard)
            Task { await self.optimiseAddress(address, as: .offered, copy: copy, pipeline: { Self.first(of: triggered, for: $0) }) }
        }), hideAfter: 4)
    }

    /// A copied web address of media: downloaded (`WebDownload.fetch`, with its limits) under a
    /// working card that Stop cancels, then optimised as a copied file, so its result goes back
    /// on the clipboard while the clipboard still holds the address. A refusal on the hotkey or
    /// the offer is a notice, as a refused drop is; see `AddressRequest`.
    func optimiseAddress(_ address: URL, as request: AddressRequest, aggressive: Bool = false, copy: ClipboardCopy, pipeline: @escaping (URL) -> Pipeline?) async {
        let largest = request == .asked ? WebDownload.largest : MediaKind.of(address).map { factory.sizeLimits(for: $0).max } ?? WebDownload.largest
        let card = downloadCard(named: Self.downloadName(address), origin: .clipboard)
        let terms = WebDownload.Terms(largest: largest, automatic: request != .asked, progress: card.downloadProgress)
        let download = download
        let transfer = Task { try await download(address, terms) }
        card.cancelWork = { transfer.cancel() }
        let file: URL
        do {
            file = try await transfer.value
        } catch {
            downloaded(card)
            guard request != .automatic, !transfer.isCancelled else { return }
            notice(Strings.text("Could not download the copied address"), CardPresentation.message(for: error))
            return
        }
        // Stopped just as the file arrived: it goes too.
        guard downloaded(card) else { return Self.discardDownload(file) }
        if request == .automatic, factory.automaticSkip(for: file) != nil { return Self.discardDownload(file) }
        if WebDownload.isInsecure(address) {
            notice(Strings.format("%@ came over insecure http", file.lastPathComponent), Strings.text("It may have been changed on the way."))
        }
        optimise([file], origin: .clipboard, aggressive: aggressive, copy: copy, pipeline: pipeline)
    }

    /// What a download's card calls it: the address's last part, or its host when the address
    /// has no path ("example.com/").
    nonisolated static func downloadName(_ address: URL) -> String {
        let last = address.lastPathComponent
        return last.isEmpty || last == "/" ? address.host() ?? address.absoluteString : last
    }

    /// A working card for a download (a copied address, a drop's promised or web files), shown
    /// from its start; Stop runs `cancelWork`, which stops the transfer.
    // ponytail: the card gives its place to the file's own card when the file arrives, instead
    // of becoming it (a card's source is fixed). Morph them if the swap shows.
    func downloadCard(named name: String, origin: RequestOrigin) -> ResultCard {
        let card = ResultCard(jobID: UUID(), source: URL(fileURLWithPath: "/").appendingPathComponent(name), origin: origin, bytesBefore: 0, phase: .working(fraction: -1))
        card.displayName = name
        card.downloading = true
        add(card)
        return card
    }

    /// The download behind `card` ended: its card goes. False when Stop had already taken it.
    @discardableResult
    func downloaded(_ card: ResultCard) -> Bool {
        guard cards.contains(where: { $0.id == card.id }) else { return false }
        card.cancelWork = nil
        dismiss(card)
        return true
    }

    /// A download or promised file that is not optimised after all goes at once: a download with
    /// its own folder. Only inside L'Esclop's temporary folder; anything else stays.
    nonisolated static func discardDownload(_ file: URL) {
        // Resolved on both sides: a promise may name /private/var for /var.
        let folder = file.deletingLastPathComponent().resolvingSymlinksInPath()
        if folder.deletingLastPathComponent().path == WebDownload.folder.resolvingSymlinksInPath().path {
            try? FileManager.default.removeItem(at: folder)
        } else if folder.path.hasPrefix(Paths.temporary.resolvingSymlinksInPath().path + "/") {
            try? FileManager.default.removeItem(at: file)
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
        // Results of dropped files go on the clipboard, once all are done, when the person asked.
        let copyDropped = origin == .dropZone && EsclopSettings.copyDroppedResults.value(in: settings)
        let putBack = PutBack()
        // Copied files the pipeline runs on a copy of, by the copy's path.
        var originals: [String: URL] = [:]
        let jobs = zip(urls, urls.map(pipeline)).map { url, triggered -> (url: URL, triggered: Pipeline?, job: OptimisationJob) in
            var job = factory.job(for: url, origin: origin, aggressive: aggressive)
            guard let triggered else { return (url, nil, job) }
            if origin == .clipboard {
                // Copying is not a request to change the original: the pipeline runs on a copy, which
                // goes back on the clipboard. Without one, the plain optimisation (a copy too) runs.
                guard let copy = try? Self.workingCopy(of: url) else { return (url, nil, job) }
                job.request.sources = [copy]
                originals[copy.path] = url
            }
            Self.use(triggered, in: &job)
            return (url, triggered, job)
        }
        // A pipeline that hides its result keeps its files out of the batch window too.
        let shown = jobs.filter(\.job.request.showResultUI)
        // Too many for floating results: one batch window for all of them.
        let batch = shown.count >= batchThreshold ? openBatch(origin: origin) : nil
        // Every file shows in the window at once, waiting, before its job starts.
        for item in shown { batch?.add(item.job.request.sources[0], bytes: Self.size(of: item.url)) }
        // Every result, a retried file's too; one retried after the rest went back goes on its own.
        let onResult: ((OptimisationResult) -> Void)? = copyBack || copyDropped ? { [originals] result in
            let replacement = (originals[result.source.path] ?? result.source, result.output)
            putBack.results.append(replacement)
            guard putBack.done else { return }
            // ponytail: a dropped file retried after the rest replaces the clipboard with its own
            // result alone; gather them as `appendClipboardResults` does if someone minds.
            if copyBack { Task { await self.putBackOnClipboard([replacement]) } } else { self.writeClipboard(files: [result.output]) }
        } : nil
        var runs: [Task<Void, Never>] = []
        for (url, triggered, base) in jobs {
            runs.append(Task {
                var job = base
                adjust(&job)
                var context: CardContext?
                if origin == .clipboard {
                    context = await clipboardContext(for: url, copy: copy ?? ClipboardCopy(changeCount: 0), aggressive: aggressive, pipeline: triggered)
                    if let context, context.rule != nil { context.choice.apply(to: &job.request) }
                }
                await run(job, context: context, batch: job.request.showResultUI ? batch : nil, copy: copy, onResult: onResult)
            })
        }
        guard copyBack || copyDropped else { return }
        Task {
            for run in runs { await run.value }
            putBack.done = true
            if copyBack {
                await putBackOnClipboard(putBack.results)
            } else if !putBack.results.isEmpty {
                writeClipboard(files: putBack.results.map(\.new))
            }
        }
    }

    /// A copied file's copy for its clipboard pipeline, where the plain optimisation puts its
    /// results (`OutputLocation.temporary`), swept at launch with them.
    // ponytail: copied on the main actor; APFS clones it at once on the same volume. Copy off the
    // main actor if a large file copied from another volume shows as a hang.
    nonisolated static func workingCopy(of file: URL) throws -> URL {
        let copy = OutputLocation.temporary.destination(for: file, extension: file.pathExtension)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: copy)
        return copy
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
            await run(job, displayName: Strings.text("Copied image"), context: context, copy: copy, onResult: { result in
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
            // Its own card, done or restored: a sibling from the same job keeps its card.
            if let card = cards.first(where: { card in
                if case let .restored(restored) = card.phase { return restored.id == result.id }
                return card.result?.id == result.id
            }) { dismiss(card) }
            optimiseAgain(result)
            return
        }
        // The clipboard already holds one of L'Esclop's results: show that result again instead
        // of optimising it a second time (which made a twin card with no saving).
        if pipeline == nil, !aggressive, now.own {
            ownResult(on: content)
            return
        }
        // The app it came from, for a pipeline's `if(copiedBy:)`, when the watcher saw the copy.
        let copy = ClipboardCopy(changeCount: now.count, app: now.app)
        switch content {
        case let .files(urls):
            // A copied link is its file, as a link given to the CLI is; results go back in its place.
            let files = urls.map(PathInput.resolvingLink)
            let media = files.filter { MediaKind.of($0) != nil }
            guard !media.isEmpty else { return notice(Strings.text("Nothing to optimise"), Strings.text("The copied files are not images, videos, PDFs or audio.")) }
            optimise(media, origin: .clipboard, aggressive: aggressive, copy: copy, copied: files, pipeline: { _ in pipeline })
        case let .path(url):
            optimise([url], origin: .clipboard, aggressive: aggressive, copy: copy, pipeline: { _ in pipeline })
        case let .image(data, type), let .base64Image(data, type):
            optimiseImageData(data, type: type, aggressive: aggressive, copy: copy, pipeline: { _ in pipeline })
        case let .address(address):
            // Asked for: downloaded whatever `optimiseURLClipboard` and the kinds' switches say.
            await optimiseAddress(address, as: .asked, aggressive: aggressive, copy: copy, pipeline: { _ in pipeline })
        case .empty:
            notice(Strings.text("Nothing to optimise"), Strings.text("Copy an image or a file first."))
        }
    }

    /// The clipboard holds a result L'Esclop wrote: refresh its card, or bring it back from
    /// Recent Results.
    private func ownResult(on content: ClipboardContent) {
        // L'Esclop's own link or text: nothing to optimise, and the hotkey says so.
        guard case let .files(urls) = content else {
            notice(Strings.text("Nothing to optimise"), Strings.text("Copy an image or a file first."))
            return
        }
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

    /// Files and folders (searched recursively) to optimise as if dropped. Folders past the
    /// batch threshold ask once, as Finder's Quick Actions do (`FinderServices.confirmed`).
    public func optimiseChosen(_ urls: [URL]) {
        let files = PathInput.expand(urls, recursive: true).filter { MediaKind.of($0) != nil }
        guard !files.isEmpty else { return notice(Strings.text("Nothing to optimise"), Strings.text("Choose images, videos, PDFs or audio files.")) }
        guard foldersConfirmed(files, in: urls) else { return }
        optimise(files, origin: .app)
    }

    /// False when `urls` hold folders, `files` from them are past the batch threshold, and the
    /// person did not confirm: folders are optimised in place, recursively.
    func foldersConfirmed(_ files: [URL], in urls: [URL]) -> Bool {
        guard files.count > batchThreshold, let place = FinderServices.folders(in: urls) else { return true }
        return confirmFolders(Strings.format("Optimise %d files in %@?", files.count, place), Strings.text("Optimise"))
    }

    // MARK: Drop zone

    /// A drop on the zone: on the plain tile (`zone` nil) or on a preset zone. Promised and
    /// downloaded files go ahead as they arrive (the promises are asked for now, during the drop).
    func takeDrop(
        _ intake: DropIntake, harder: Bool, keepOriginals: Bool, zone: String?,
        download: @escaping @Sendable (URL, WebDownload.Terms) async throws -> URL = { try await WebDownload.fetch($0, terms: $1) }
    ) {
        // Promised and web files show a working card until the last one arrives; Stop stops them.
        // A lone address shows its share received.
        let card = intake.remoteCount > 0 ? downloadCard(named: intake.remoteName, origin: .dropZone) : nil
        let progress: @Sendable (Double) -> Void = (intake.remoteCount == 1 ? card?.downloadProgress : nil) ?? { _ in }
        let terms = WebDownload.Terms(progress: progress)
        let stop = intake.resolve(download: { try await download($0, terms) }, waiting: { [weak self] left in
            if left == 0, let card { self?.downloaded(card) }
        }) { [self] files, failures in
            if let failure = failures.first {
                notice(Strings.text("Could not get the dropped file"), CardPresentation.message(for: failure))
                guard !files.isEmpty else { return }
            }
            if let zone {
                runPresetZone(zone, on: files, keepOriginals: keepOriginals)
            } else {
                optimiseDropped(files, harder: harder, keepOriginals: keepOriginals)
            }
        }
        card?.cancelWork = stop
    }

    /// `keepOriginals` (⌥ held at the drop): every original stays as it is.
    public func optimiseDropped(_ urls: [URL], harder: Bool, keepOriginals: Bool = false) {
        let files = PathInput.expand(urls, recursive: true).filter { MediaKind.of($0) != nil }
        guard !files.isEmpty else { return notice(Strings.text("Nothing to optimise"), Strings.text("Drop images, videos, PDFs or audio files.")) }
        // A folder dropped here or on the Dock icon asks as Finder's action does.
        guard foldersConfirmed(files, in: urls) else { return }
        // Harder is a plain optimisation the person asked for; a plain drop runs a drop-zone pipeline.
        let triggered = harder ? [] : pipelines(for: .dropZone)
        optimiseDrop(files, aggressive: harder, keepOriginals: keepOriginals, pipeline: { Self.first(of: triggered, for: $0) })
    }

    /// With `keepOriginals`, a plain optimisation writes beside the original, whatever the "go"
    /// setting says (a folder template can name the original too). A pipeline has its own place
    /// for each step, so it runs on a copy made beside the original; `dropCopySettled` removes that copy
    /// when the pipeline wrote its result elsewhere.
    private func optimiseDrop(_ files: [URL], aggressive: Bool, keepOriginals: Bool, pipeline: @escaping (URL) -> Pipeline?) {
        guard keepOriginals else { return optimise(files, origin: .dropZone, aggressive: aggressive, copy: nil, pipeline: pipeline) }
        Task {
            var sources: [URL] = []
            for file in files {
                guard pipeline(file) != nil else {
                    sources.append(file)
                    continue
                }
                do {
                    // A watched folder must not take the copy for a new file to optimise.
                    let copy = try OutputPlanner.destination(for: file, location: .sameFolder, suffix: "optimised")
                    noteWritten([copy])
                    try await Self.copy(file, to: copy)
                    noteWritten([copy])
                    dropCopies[copy.standardizedFileURL.path] = file
                    sources.append(copy)
                } catch {
                    notice(Strings.format("Could not copy %@", file.lastPathComponent), CardPresentation.message(for: error))
                }
            }
            guard !sources.isEmpty else { return }
            optimise(sources, origin: .dropZone, aggressive: aggressive, copy: nil, adjust: { $0.request.location = .sameFolder }, pipeline: pipeline)
        }
    }

    /// The result of a pipeline that ran on `copy`, an ⌥-drop's copy of `original`. When no step
    /// changed the copy and it is none of the outputs (the pipeline wrote elsewhere), the copy goes
    /// and the result names the original, which it equals: compare and another choice start there.
    /// A failed or cancelled run keeps the copy: what it holds may be what the earlier steps made.
    nonisolated static func dropCopySettled(_ result: OptimisationResult, workingCopy copy: URL, of original: URL) -> OptimisationResult {
        guard result.backup == nil, result.output.standardizedFileURL != copy.standardizedFileURL,
              !result.steps.contains(ResultSummary.alsoWroteStep(copy)), (try? FileManager.default.removeItem(at: copy)) != nil
        else { return result }
        var settled = result
        settled.source = original
        return settled
    }

    /// Copies off the main thread. The copy beside the original is "photo-optimised.jpg",
    /// the default same-folder name, whatever `sameFolderNameTemplate` says.
    nonisolated static func copy(_ file: URL, to copy: URL) async throws {
        try FileManager.default.copyItem(at: file, to: copy)
    }

    /// The saved pipelines with this trigger, by name: read once per copy or drop.
    func pipelines(for trigger: PipelineTrigger) -> [Pipeline] {
        ((try? service.context.pipelines.pipelines(triggeredBy: trigger)) ?? [])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The one that runs on `file` instead of the plain optimisation: the first with steps for its kind.
    nonisolated static func first(of pipelines: [Pipeline], for file: URL) -> Pipeline? {
        guard let kind = MediaKind.of(file) else { return nil }
        return pipelines.first { !$0.steps(for: kind).isEmpty }
    }

    /// Files dropped on a preset zone: the pipeline runs on each, through the usual floating
    /// results, or the batch window from `batchWindowFrom` files, like a plain drop.
    public func runPresetZone(_ name: String, on urls: [URL], keepOriginals: Bool = false) {
        let files = PathInput.expand(urls, recursive: true).filter { MediaKind.of($0) != nil }
        guard !files.isEmpty else { return notice(Strings.text("Nothing to optimise"), Strings.text("Drop images, videos, PDFs or audio files.")) }
        guard foldersConfirmed(files, in: urls) else { return }
        var zone = (try? service.context.pipelines.resolve(name)) ?? Pipeline(name: name, steps: [])
        zone.name = name
        optimiseDrop(files, aggressive: false, keepOriginals: keepOriginals, pipeline: { _ in zone })
    }
}
