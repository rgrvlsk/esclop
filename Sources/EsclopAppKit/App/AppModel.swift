// SPDX-License-Identifier: GPL-3.0-or-later
//
// The app's single store: the cards on screen, recent results, the pause state. Every job,
// whether it comes from the clipboard, the drop zone, a hotkey or the CLI and MCP server over
// IPC, runs through `run(_:)`: one queue, one kind of card.

import AppKit
import EsclopCore
import EsclopIPC
import EsclopMCP
import EsclopOptimisers
import EsclopPipelines
import Foundation
import Observation

@MainActor @Observable
public final class AppModel {
    public private(set) var cards: [ResultCard] = [] {
        didSet { onCardsChange?() }
    }
    /// The files of the latest job too large for floating results, shown in the batch window.
    public private(set) var batch: Batch?
    /// Files L'Esclop wrote, and when: a watched folder leaves them alone for a while (Clop's
    /// three-second protection), so a result written in place is never optimised again.
    @ObservationIgnored var recentlyWritten: [String: Date] = [:]
    static let writeProtection: TimeInterval = 3
    /// Every pasteboard read and write for results, and what the clipboard holds.
    @ObservationIgnored let clipboard: ClipboardKeeper
    /// Fetches a copied web address (`WebDownload.fetch`); a fake in tests.
    @ObservationIgnored var download: @Sendable (URL, WebDownload.Terms) async throws -> URL = { try await WebDownload.fetch($0, terms: $1) }
    /// Copied addresses offered this session: each is offered once.
    @ObservationIgnored var offeredAddresses: Set<URL> = []
    /// Shows the batch window when a batch starts.
    @ObservationIgnored var onBatch: ((Batch) -> Void)?

    /// Opens the batch window on the latest batch again (the menu).
    public func showBatch() {
        if let batch { onBatch?(batch) }
    }

    /// Newest first: this session's results, after the last ones from the shared log.
    public private(set) var recent: [OptimisationResult] = []
    /// Files being optimised right now.
    public private(set) var activeFiles = 0
    /// Mirrors the `pauseAutomaticOptimisations` setting, which the CLI can change too.
    public private(set) var paused: Bool

    public let settings: SettingsStore
    public let service: EsclopService
    public let factory: RequestFactory
    @ObservationIgnored let pasteboard: NSPasteboard
    @ObservationIgnored let reveal: ([URL]) -> Void
    @ObservationIgnored let gate: WorkGate
    /// Uploads to the person's targets, with the keys from the Keychain (tests use memory).
    @ObservationIgnored public var uploader: any FileUploading
    @ObservationIgnored var restoredIDs = Set<UUID>()
    /// Results whose original is being put back now (`putBack`).
    @ObservationIgnored var restoringIDs = Set<UUID>()
    /// Reads Recent from the log at launch; Clear stops it, so cleared names never come back.
    @ObservationIgnored private var loadingRecent: Task<Void, Never>?
    /// An ⌥-drop's copies a pipeline runs on, by path, with the original each stands for.
    @ObservationIgnored var dropCopies: [String: URL] = [:]
    @ObservationIgnored var onCardsChange: (() -> Void)?
    /// Replaces the auto-hide delays from the settings (tests).
    @ObservationIgnored public var hideDelayOverride: Duration?
    @ObservationIgnored public var loadsThumbnails = true
    /// The clock the floating results run on (tests move it by hand).
    @ObservationIgnored public var now: () -> Date = Date.init
    /// Where Save puts a copied image (tests point it elsewhere).
    @ObservationIgnored public var downloads: () -> URL = { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
    /// Puts a result's original back; tests report an edit set aside without the real Trash.
    @ObservationIgnored var restoreBackup: @Sendable (EsclopService, OptimisationResult) async throws -> RestoreOutcome = {
        try await $0.restoreBackup(of: $1, deleteBackup: false)
    }
    /// Announces results to VoiceOver; tests record them instead.
    @ObservationIgnored public var announce: (String) -> Void = AppModel.postAnnouncement
    /// Size estimates for the options popover, cached per file.
    @ObservationIgnored public lazy var estimator = SizeEstimator(executor: executor(for: .app))

    public init(
        settings: SettingsStore, service: EsclopService, pasteboard: NSPasteboard = .general,
        gate: WorkGate = WorkGate(), reveal: @escaping ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    ) {
        self.settings = settings
        self.service = service
        self.pasteboard = pasteboard
        clipboard = ClipboardKeeper(pasteboard: pasteboard)
        self.gate = gate
        self.reveal = reveal
        uploader = AppUploader(settings: settings)
        factory = RequestFactory(settings: settings)
        paused = EsclopSettings.pauseAutomaticOptimisations.value(in: settings)
        // The log can hold tens of thousands of lines (every result of the last eight days): read
        // off the main actor, so the launch does not wait for it.
        let log = service.results, limit = Self.recentLimit
        loadingRecent = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { log.recent(limit: limit) }.value
            guard !Task.isCancelled else { return }
            self?.loaded(recent: loaded)
        }
    }

    /// The log's results joined to those recorded since launch. ponytail: a result a re-run
    /// replaced before the log was read may come back here until the next launch (restored
    /// ones never do); remember `forget`'s ids too if that is ever seen.
    private func loaded(recent loaded: [OptimisationResult]) {
        let known = Set(recent.map(\.id)).union(restoredIDs)
        recent = Array((recent + loaded.filter { !known.contains($0.id) }).sorted { $0.finishedAt > $1.finishedAt }.prefix(Self.recentLimit))
    }

    static let recentLimit = 30
    /// The floating results on screen at once; older ones live on in Recent Results.
    static let visibleLimit = 3

    /// The newest three results, oldest first (the newest sits at the bottom). Grouped failures
    /// take one of the three places (`failureGroup`).
    public var visibleCards: [ResultCard] {
        guard groupsFailures else { return Self.newest(cards, Self.visibleLimit) }
        let grouped = Set(failedCards.map(\.id))
        return Self.newest(cards.filter { !grouped.contains($0.id) }, Self.visibleLimit - 1)
    }

    /// The newest `limit` cards, oldest first, the files at work before the finished ones, so a
    /// file at work keeps its Stop while newer results arrive. ponytail: past `limit` files at
    /// work at once the oldest ones hide, and the menu's working rows have no Stop. Trigger: Stop
    /// on those rows, if several clipboard and drop jobs at once turn out to be common.
    static func newest(_ list: [ResultCard], _ limit: Int) -> [ResultCard] {
        let working = Set(list.filter(\.isWorking).suffix(limit).map(\.id))
        var room = limit - working.count
        var kept = working
        for card in list.reversed() where !card.isWorking && room > 0 {
            room -= 1
            kept.insert(card.id)
        }
        return list.filter { kept.contains($0.id) }
    }

    /// The failed results the group holds, oldest first. One the person is using (open,
    /// hovered, focused) stays its own card until they leave it, so nothing changes under the
    /// pointer.
    public var failedCards: [ResultCard] { cards.filter { $0.failure != nil && !$0.machine.isDismissalPaused } }

    /// Two or more failures share one place in the stack, an amber pill that opens into their
    /// list (docs/design/targets: pr2-failures), so they never push the results off the screen.
    /// An open list stays while one is left, so nothing changes under the pointer.
    public var groupsFailures: Bool {
        let count = failedCards.count
        return count >= 2 || (failuresExpanded && count >= 1)
    }

    /// The grouped failures show their list.
    public var failuresExpanded = false

    /// Runs again every failure another try can help, and closes the list.
    public func retryFailures() {
        for card in failedCards {
            if let action = FailureGroup.retry(for: card) { perform(action, on: card) }
        }
        failuresExpanded = false
    }

    /// Removes every failure: the originals are untouched, only the notices go.
    public func dismissFailures() {
        failedCards.forEach(dismiss)
        failuresExpanded = false
    }

    /// The service the app runs jobs with: in-process, never routed back to itself.
    public static func makeService(settings: SettingsStore, locations: EsclopLocations = .current()) -> EsclopService {
        EsclopService(ServiceContext(
            origin: .app,
            engine: EsclopEngine(settings: settings),
            engineName: "EsclopEngine",
            settings: RegistrySettingsProvider(store: settings),
            pipelines: PipelineStore(directory: locations.pipelines, useTrash: true),
            locations: locations,
            useApp: false
        ))
    }

    // MARK: Settings the views read

    public var corner: ScreenCorner { EsclopSettings.floatingResultsCorner.value(in: settings) }
    public var rules: ClipboardRules { ClipboardRules(settings: settings) }
    public var followCursorScreen: Bool { EsclopSettings.followCursorScreen.value(in: settings) }

    public func setPaused(_ value: Bool) {
        try? EsclopSettings.pauseAutomaticOptimisations.set(value, in: settings)
        pauseChanged(value)
    }

    /// Called when the setting changed, here or in another process.
    public func pauseChanged(_ value: Bool) {
        paused = value
        onPauseChange?()
    }

    /// Folders being watched now, for the menu.
    public internal(set) var watchedFolderCount = 0
    /// The watched folders follow the pause.
    @ObservationIgnored var onPauseChange: (() -> Void)?
    /// Opens the compare window on a result.
    @ObservationIgnored public var onCompare: ((OptimisationResult) -> Void)?
    /// Gives the floating panel's keys back to the app in front (`returnKeys(from:)`).
    @ObservationIgnored var onReturnKeys: (() -> Void)?
    /// Opens the pipeline editor, on a pipeline when one is named.

    @ObservationIgnored public var onOpenPipelines: ((String?) -> Void)?
    /// The menu's "Check for Updates…"; nil when the app cannot update itself (no bundle key).
    @ObservationIgnored public var onCheckForUpdates: (() -> Void)?

    /// Results whose original can still be put back.
    public var restorable: [OptimisationResult] {
        recent.filter { result in
            guard let backup = result.backup, !restoredIDs.contains(result.id) else { return false }
            return FileManager.default.fileExists(atPath: backup.path)
        }
    }

    // MARK: Running jobs

    /// Runs a job, one card per file when it asks for result UI, or one row per file in the batch
    /// window when it brings `batchWindowFrom` files or more. `events` reports each file as it
    /// finishes (the IPC reply stream). Cancelling the calling task stops every file. `copy` is
    /// the clipboard copy the files came from: its app for a pipeline's `if(copiedBy:)`, its change
    /// count for the links the job makes later.
    @discardableResult
    public func run(
        _ job: OptimisationJob, displayName: String? = nil, context: CardContext? = nil, reusing existing: ResultCard? = nil,
        batch: Batch? = nil, copy: ClipboardCopy? = nil,
        events: @escaping @Sendable (JobEvent) -> Void = { _ in },
        onResult: ((OptimisationResult) -> Void)? = nil
    ) async -> JobReport {
        let batch = batch ?? (existing == nil && job.request.showResultUI && job.request.sources.count >= batchThreshold
            ? openBatch(origin: job.request.origin) : nil)
        // A fork shows as a result of its own beside a single floating result, not in a batch.
        let single = job.request.showResultUI && batch == nil && job.request.sources.count == 1 ? job.request.sources.first : nil
        let desktop = AppDesktop(model: self, original: single.map { ($0, Self.size(of: $0)) })
        // The clipboard as the job starts: a link it makes later goes on it only if nothing was
        // copied after (an automatic upload's, a pipeline's upload step's).
        let linksSince = linkBaseline(for: job, copy: copy)
        let executor = executor(
            for: job.request.origin, desktop: job.request.origin == .mcp ? nil : desktop, sourceApp: copy?.app
        ) { [weak self] link in await self?.pipelineLink(link, since: await linksSince?.value, batch: batch) }
        var tasks: [(URL, Task<Result<OptimisationResult, PipelineStepFailure>, Never>)] = []
        for source in job.request.sources {
            if let batch {
                let row = batch.row(for: source, bytes: Self.size(of: source))
                tasks.append((source, startRow(row, in: batch, job: job, executor: executor, linksSince: linksSince, events: events, onResult: onResult)))
                continue
            }
            let card: ResultCard?
            if let existing, cards.contains(where: { $0.id == existing.id }) {
                restart(existing, context: context)
                card = existing
            } else {
                card = job.request.showResultUI ? addCard(for: source, job: job, displayName: displayName, context: context) : nil
            }
            let task = Task { await self.process(source, job: job, executor: executor, card: card, linksSince: linksSince, events: events, onResult: onResult) }
            card?.cancelWork = { task.cancel() }
            card?.retry = { [weak self, weak card] in
                guard let self else { return }
                if let card { self.dismiss(card) }
                var again = job
                again.request.id = UUID()
                again.request.sources = [source]
                Task { await self.run(again, displayName: displayName, context: context, copy: copy, onResult: onResult) }
            }
            tasks.append((source, task))
        }
        let running = tasks.map(\.1)
        return await withTaskCancellationHandler {
            var report = JobReport(route: "app")
            for (source, task) in tasks {
                switch await task.value {
                case let .success(result): report.results.append(result)
                case let .failure(failure):
                    // A pipeline that failed late: what its earlier steps made, and the step, as CLI and MCP report.
                    if let partial = failure.partial { report.results.append(partial) }
                    report.failures.append(FileFailure(source: source, error: failure.error, step: failure.step))
                }
            }
            return report
        } onCancel: {
            running.forEach { $0.cancel() }
        }
    }

    // MARK: Batches

    /// Files from this many on go to the batch window.
    public var batchThreshold: Int { max(2, EsclopSettings.batchWindowFrom.value(in: settings)) }

    /// The batch new files join: the running one, else a new one shown in the batch window.
    func openBatch(origin: RequestOrigin) -> Batch {
        if let batch, batch.isRunning { return batch }
        let fresh = Batch(origin: origin, startedAt: now())
        batch = fresh
        onBatch?(fresh)
        return fresh
    }

    /// Runs one file of a batch; its row can stop it and run it again.
    private func startRow(
        _ row: BatchRow, in batch: Batch, job: OptimisationJob, executor: JobExecutor, linksSince: Task<Int, Never>?,
        events: @escaping @Sendable (JobEvent) -> Void, onResult: ((OptimisationResult) -> Void)?
    ) -> Task<Result<OptimisationResult, PipelineStepFailure>, Never> {
        let source = row.source
        var single = job
        single.request.sources = [source]
        let task = Task {
            await self.process(source, job: single, executor: executor, card: nil, row: row, batch: batch, linksSince: linksSince, events: events, onResult: onResult)
        }
        row.cancel = { task.cancel() }
        row.retry = { [weak self, weak row, weak batch] in
            guard let self, let row, let batch, row.isFinished else { return }
            row.state = .waiting
            row.upload = nil
            var again = single
            again.request.id = UUID()
            _ = self.startRow(row, in: batch, job: again, executor: executor, linksSince: linksSince, events: { _ in }, onResult: onResult)
        }
        return task
    }

    /// Puts one batch file's original back, without a floating result. When that fails the row
    /// keeps its result and its saving and shows why.
    public func restore(_ row: BatchRow) async {
        guard let result = row.result, row.canRestore else { return }
        row.restoreError = nil
        do {
            row.editInTrash = try await putBack(result)
            row.state = .restored(result)
        } catch is RestoreUnderWay {
            return
        } catch {
            row.restoreError = CardPresentation.message(for: error)
        }
    }

    /// Stops what is still to go first, so no file is optimised after its neighbours came back.
    public func restoreAll(_ batch: Batch) async {
        // ponytail: polls like `waitWhilePaused`; rows end within an engine's cancel time. Cancels
        // each pass: files dropped meanwhile join this batch, and rows added ahead of their job
        // get their cancel only when it starts.
        while batch.isRunning {
            batch.cancelAll()
            try? await Task.sleep(for: .milliseconds(50))
        }
        for row in batch.restorable { await restore(row) }
    }

    /// The one restore every window uses: by the result itself, never by its path (an older
    /// result for the same file would get the newer original), with the copying off the main actor.
    /// One at a time per result, whichever window asks (a double click in Recent, the card's Undo,
    /// Compare's Restore Original): a second would put the original back twice and send it to the
    /// Trash as an edit, so it throws `RestoreUnderWay`. True when a version edited after
    /// optimising went to the Trash on the way.
    @discardableResult
    private func putBack(_ result: OptimisationResult) async throws -> Bool {
        guard restoringIDs.insert(result.id).inserted else { throw RestoreUnderWay() }
        defer { restoringIDs.remove(result.id) }
        let (service, restoreBackup) = (service, restoreBackup)
        let outcome = try await Task.detached { try await restoreBackup(service, result) }.value
        restoredIDs.insert(result.id)
        forget(result)
        noteWritten([result.source, result.output])
        return Self.editWentToTrash(trashed: outcome.movedToTrash?.count ?? 0, restoring: result)
    }

    /// Why a result with no backup has no original to put back.
    static func noBackupMessage(for result: OptimisationResult) -> String {
        result.output.standardizedFileURL != result.source.standardizedFileURL
            ? Strings.text("The original was never changed. It is still where it was.")
            : Strings.text("L’Esclop kept no copy of this original.")
    }

    /// The result's original is being put back already.
    struct RestoreUnderWay: Error {}

    /// Whether a restore that moved `trashed` files to the Trash took an edited version with them.
    /// ponytail: the Trash also takes a converted output, so an edit counts only beyond it. A
    /// converted output that was gone or stayed put beside an edit, or an edit made to the
    /// converted output itself, hides the line (never a false one). Trigger: RestoreOutcome
    /// naming the edit apart.
    nonisolated static func editWentToTrash(trashed: Int, restoring result: OptimisationResult) -> Bool {
        let converted = result.output.standardizedFileURL != result.source.standardizedFileURL
        return trashed > (converted ? 1 : 0)
    }

    /// The executor for a request's origin: agents get the pipeline permissions the person set.
    /// `desktop` lets pipeline steps reach the clipboard, apps and the floating results; agents
    /// get none.
    /// `sourceApp` is the app a copy came from, for a pipeline's `if(copiedBy:)`. `copyLink` takes
    /// an upload step's link (`run` respects a newer copy); without it the link goes on the
    /// clipboard whatever it holds.
    func executor(
        for origin: RequestOrigin, desktop: (any PipelineDesktop)? = nil, sourceApp: String? = nil,
        copyLink: (@Sendable (URL) async -> Void)? = nil
    ) -> JobExecutor {
        let context = service.context
        let policy = AgentPolicy(origin: origin, permissions: context.settings)
        // Agents upload only when the person allows it; the policy refuses before this, and an
        // executor without an uploader cannot upload anyway.
        let uploader: (any FileUploading)? = policy.allowed(.allowUploads) ? uploader : nil
        let host: AppPipelineHost? = uploader == nil && desktop == nil ? nil
            : AppPipelineHost(uploader: uploader, desktop: desktop, copyLink: copyLink ?? { [weak self] link in await self?.copyToClipboard(links: [link]) })
        let runner = StorePipelineRunner(
            store: context.pipelines, allowRunScripts: policy.allowed(.allowRunScripts),
            allowDelete: policy.allowed(.allowOverwriteOriginals), temporaryDirectory: Paths.temporary, host: host,
            sourceApp: sourceApp
        )
        return JobExecutor(engine: context.engine, pipelineRunner: runner, uploader: uploader, backups: context.locations.backups)
    }

    private func process(
        _ source: URL, job: OptimisationJob, executor: JobExecutor, card: ResultCard?, row: BatchRow? = nil, batch: Batch? = nil,
        linksSince: Task<Int, Never>? = nil, events: @escaping @Sendable (JobEvent) -> Void, onResult: ((OptimisationResult) -> Void)?
    ) async -> Result<OptimisationResult, PipelineStepFailure> {
        activeFiles += 1
        defer { activeFiles -= 1 }
        // A batch's links go on the clipboard against the clipboard as its first job started.
        if let batch, let linksSince, batch.linksSince == nil { batch.linksSince = await linksSince.value }
        if let batch {
            // A file queued at the gate when the batch is paused gives its turn back and waits.
            while true {
                await batch.waitWhilePaused()
                await gate.acquire()
                if !batch.paused || Task.isCancelled { break }
                await gate.release()
            }
        } else {
            await gate.acquire()
        }
        card?.startedAt = now()
        if let row, !Task.isCancelled { row.state = .working(0) }
        let outcome: Result<OptimisationResult, EsclopError>
        var failedStep: String?
        var partial: OptimisationResult?
        // Taken for every outcome: a stale entry must never settle a later file at that path.
        let dropOriginal = dropCopies.removeValue(forKey: source.standardizedFileURL.path)
        if Task.isCancelled {
            outcome = .failure(.cancelled)
        } else {
            let cardID = card?.id
            do {
                var result = try await executor.process(source, job: job) { [weak self, weak row] progress in
                    Task { @MainActor in
                        if let cardID { self?.progress(progress.fraction, cardID: cardID) }
                        if let row, case let .working(current) = row.state, progress.fraction > current { row.state = .working(progress.fraction) }
                    }
                }
                result.origin = job.request.origin
                if let dropOriginal { result = Self.dropCopySettled(result, workingCopy: source, of: dropOriginal) }
                outcome = .success(result)
            } catch let failed as PipelineStepFailure {
                // Earlier steps changed the file: keep that in Recent, where its backup restores.
                partial = failed.partial
                partial?.origin = job.request.origin
                if let partial {
                    events(.result(partial))
                    noteWritten([partial.output, partial.source] + [partial.backup].compactMap { $0 })
                    record(partial)
                }
                failedStep = failed.step
                outcome = .failure(Task.isCancelled ? .cancelled : failed.error)
            } catch {
                outcome = .failure(Task.isCancelled ? .cancelled : .wrap(error))
            }
        }
        await gate.release()

        switch outcome {
        case let .success(result):
            events(.result(result))
            noteWritten([result.output, result.source] + [result.backup].compactMap { $0 })
            record(result)
            card?.phase = .done(result)
            if let card {
                loadThumbnail(card, url: result.output)
                if let backup = result.backup { loadThumbnail(card, url: backup, original: true) }
            }
            row?.state = .done(result)
            // A batch is announced once, when it ends, not file by file.
            if row == nil { announce(CardPresentation.announcement(for: result)) }
            if let link = result.link {
                await copyToClipboard(links: [link])
            } else if uploadsAutomatically(job) {
                // Every result, also a batch row's or one shown nowhere (a quiet pipeline). The
                // setting turned on during the job: the clipboard as it is now.
                var since = await linksSince?.value
                if since == nil { since = await clipboard.run { $0.changeCount() } }
                if let card { upload(card, since: since) } else { upload(result.output, to: nil, on: row, batch: batch, since: since) }
            }
            onResult?(result)
        case let .failure(error):
            events(.failure(FileFailure(source: source, error: error, step: failedStep)))
            if error == .alreadySmaller {
                card?.phase = .unchanged(bytes: Self.size(of: source))
                row?.state = .unchanged
            } else {
                card?.phase = .failed(CardPresentation.message(for: error))
                row?.state = error == .cancelled ? .cancelled : .failed(CardPresentation.message(for: error))
            }
        }
        if let card { settle(card) }
        if let batch, !batch.isRunning {
            announce(BatchPresentation(batch: batch).announcement)
            copyLinks(of: batch)
        }
        return outcome.mapError { PipelineStepFailure(step: failedStep, error: $0, partial: partial) }
    }

    private func progress(_ fraction: Double, cardID: UUID) {
        guard let card = cards.first(where: { $0.id == cardID }), case let .working(current) = card.phase else { return }
        if fraction > current { card.phase = .working(fraction: fraction) }
    }

    /// Remembers files L'Esclop just wrote, for the watched folders.
    func noteWritten(_ urls: [URL]) {
        let time = now()
        for url in urls { recentlyWritten[url.standardizedFileURL.resolvingSymlinksInPath().path] = time }
        recentlyWritten = recentlyWritten.filter { time.timeIntervalSince($0.value) < Self.writeProtection * 10 }
    }

    /// L'Esclop wrote this file in the last three seconds.
    public func wasJustWritten(_ url: URL) -> Bool {
        guard let at = recentlyWritten[url.standardizedFileURL.resolvingSymlinksInPath().path] else { return false }
        return now().timeIntervalSince(at) < Self.writeProtection
    }

    /// A new file in a folder a pipeline watches: the pipeline runs on it. `batch` gives the
    /// batch a burst of new files shares, asked for only when the result shows.
    public func runPipeline(_ name: String, onWatched file: URL, batch: () -> Batch? = { nil }) async {
        var job = factory.job(for: file, origin: .watchedFolder)
        job.operation = .pipeline(name)
        if let pipeline = try? service.context.pipelines.resolve(name) { Self.use(pipeline, in: &job) }
        await run(job, batch: job.request.showResultUI ? batch() : nil)
    }

    /// A pipeline that runs on its own: its operation, and no floating result when it says so.
    static func use(_ pipeline: Pipeline, in job: inout OptimisationJob) {
        job.operation = .pipeline(pipeline.name)
        if pipeline.hideResult { job.request.showResultUI = false }
    }

    /// A `fork` step's file, shown as a result of its own beside the pipeline's, with the
    /// original's size before the run.
    func presentFork(_ file: URL, of original: URL, bytesBefore: Int) {
        let time = now()
        noteWritten([file])
        show(OptimisationResult(
            source: original, output: file, kind: MediaKind.of(file) ?? .image,
            bytesBefore: bytesBefore, bytesAfter: Self.size(of: file), startedAt: time, finishedAt: time, steps: ["fork"]
        ))
    }

    /// Recent's Clear (privacy): the names go from the panel and from the shared log, which the
    /// CLI and MCP server read too; the sizes stay, so the saving still counts them. The files,
    /// their backups and the cards on screen are not touched.
    public func clearRecent() {
        do {
            try service.results.redactAll()
            loadingRecent?.cancel()
            recent = []
        } catch {
            // The names are still on disk: the list stays, so the panel does not claim otherwise.
            NSSound.beep()
        }
    }

    func record(_ result: OptimisationResult) {
        recent.removeAll { $0.id == result.id }
        recent.insert(result, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
        // The CLI and MCP server read the same log (`esclop_recent_results`, restore). Written
        // off the main actor, in order with every other read and write of the log.
        service.results.append([result], wait: false)
    }

    /// Results that no longer stand (their original is back, or a re-run replaced them) leave
    /// Recent here; `EsclopService.restoreBackup` withdraws a restored one from the shared log.
    func forget(_ result: OptimisationResult) {
        recent.removeAll { $0.id == result.id }
    }

    // MARK: Cards

    @discardableResult
    func addCard(for source: URL, job: OptimisationJob, displayName: String? = nil, context: CardContext? = nil) -> ResultCard {
        let card = ResultCard(
            jobID: job.id, source: source, origin: job.request.origin,
            aggressive: job.request.quality.tier == .aggressive, bytesBefore: Self.size(of: source)
        )
        card.displayName = displayName
        if let context {
            card.fileOrigin = context.origin
            card.inputType = context.inputType
            card.choice = context.choice
            card.appliedRule = context.rule
        } else if job.request.quality.tier == .aggressive {
            card.choice.compression = .aggressive
        }
        add(card)
        loadThumbnail(card, url: source)
        if MediaKind.of(source) == .video { refineEstimate(card) }
        return card
    }

    /// A card runs again in place: back to working with its new choice.
    private func restart(_ card: ResultCard, context: CardContext?) {
        card.phase = .working(fraction: 0)
        // A copy saved from the last result is not this one: Save is offered again.
        card.savedCopy = nil
        if let context {
            card.choice = context.choice
            card.appliedRule = context.rule
        }
        card.machine.restarted()
        afterChange(card)
    }

    func add(_ card: ResultCard) {
        cards.append(card)
        reschedule(card)
    }

    public func dismiss(_ card: ResultCard) {
        card.timer?.cancel()
        if card.isWorking { card.cancelWork?() }
        card.uploadTask?.cancel()
        cards.removeAll { $0.id == card.id }
    }

    /// Removes the cards of jobs the CLI or MCP server stopped with `remove`.
    public func removeCards(ofJobs ids: [UUID]) {
        for card in cards where ids.contains(card.jobID) { dismiss(card) }
    }

    /// A short message with no file. It replaces the last plain one. With an `action` it offers
    /// that action, stays `hideAfter` seconds (8 by default) so it can be reached, and no later
    /// notice takes its place.
    public func notice(
        _ title: String, _ detail: String, action: (action: CardPresentation.Action, run: () -> Void)? = nil, hideAfter: TimeInterval? = nil
    ) {
        cards.filter { if case .notice = $0.phase { return $0.noticeAction == nil } else { return false } }.forEach(dismiss)
        let card = ResultCard(jobID: UUID(), source: URL(fileURLWithPath: "/"), origin: .app, bytesBefore: 0, phase: .notice(title: title, detail: detail))
        card.noticeAction = action
        card.machine.notice(at: now(), hideAfter: hideDelayOverride.map(Self.seconds) ?? hideAfter ?? (action == nil ? 3 : 8))
        add(card)
    }

    // MARK: Floating result state

    /// What the person does to a floating result.
    public enum Interaction: Equatable, Sendable {
        case pointerEntered, pointerExited
        case openDetail, closeDetail
        case focus(Bool), dragging(Bool), menu(Bool)
        /// Gives the keys the "Go to the newest result" hotkey lent back to the app in front.
        case returnKeys
        /// The detail's name, edited in place: the file takes the new name.
        case rename(String)
    }

    public func interact(_ card: ResultCard, _ interaction: Interaction) {
        let time = now()
        switch interaction {
        case .pointerEntered: card.machine.pointerEntered(at: time)
        case .pointerExited: card.machine.pointerExited(at: time)
        case .openDetail:
            // A download has no file to show yet.
            guard !card.downloading else { return }
            // The options popover belongs to the card; the detail opens without it, and without
            // its "…" menu open.
            card.machine.setMenuOpen(false, at: time)
            card.loupe = nil
            card.machine.openDetail(at: time)
        case .closeDetail:
            card.machine.setMenuOpen(false, at: time)
            card.loupe = nil
            card.machine.closeDetail(at: time)
        case let .focus(value): card.machine.setFocused(value, at: time)
        case let .dragging(value):
            card.machine.setDragging(value, at: time)
            if value { watchDragEnd(card) }
        case let .menu(value):
            card.menuHighlight = nil
            card.machine.setMenuOpen(value, at: time)
        case let .rename(name):
            rename(card, to: name)
        case .returnKeys:
            returnKeys(from: card)
        }
        afterChange(card)
    }

    /// The result arrived, failed or changed: its auto-hide starts now.
    func settle(_ card: ResultCard) {
        let time = now()
        // A result that lands behind newer ones (a file at work keeps its place while others
        // finish) comes to the front, so it never arrives unseen.
        // Grouped failures stay in the pill's list, in their order (oldest first).
        let grouped = groupsFailures && failedCards.contains { $0.id == card.id }
        if !grouped, !visibleCards.contains(where: { $0.id == card.id }), let index = cards.firstIndex(where: { $0.id == card.id }) {
            cards.append(cards.remove(at: index))
        }
        let delay = hideDelay(for: card).map(Self.seconds)
        switch card.phase {
        case .working: return
        case .failed: card.machine.failed(at: time, hideAfter: delay)
        case .notice: card.machine.notice(at: time, hideAfter: delay ?? 3)
        case .done, .unchanged:
            if card.machine.stage == .working { card.machine.finished(at: time, hideAfter: delay) } else {
                card.machine.refreshed(at: time, hideAfter: delay)
            }
        case .restored: card.machine.refreshed(at: time, hideAfter: delay)
        }
        afterChange(card)
    }

    /// Applies the deadlines that passed; the timer calls it, and tests do with their own clock.
    public func advance(_ card: ResultCard) {
        let time = now()
        let effect = card.machine.advance(to: time)
        apply(effect, to: card)
        guard cards.contains(where: { $0.id == card.id }) else { return }
        afterChange(card)
    }

    private func apply(_ effect: FloatingResultMachine.Effect?, to card: ResultCard) {
        switch effect {
        case .dismiss: dismiss(card)
        case nil: break
        }
    }

    func afterChange(_ card: ResultCard) {
        // Never two details open at once.
        if card.machine.level == .detail {
            for other in cards where other.id != card.id && other.machine.level == .detail {
                other.machine.closeDetail(at: now())
                reschedule(other)
            }
        }
        reschedule(card)
    }

    /// Sleeps until the card's next deadline, then advances it.
    private func reschedule(_ card: ResultCard) {
        card.timer?.cancel()
        guard cards.contains(where: { $0.id == card.id }), let deadline = card.machine.nextDeadline else { return }
        let wait = max(0, deadline.timeIntervalSince(now()))
        card.timer = Task { [weak self, weak card] in
            try? await Task.sleep(for: .milliseconds(Int((wait * 1000).rounded(.up)) + 1))
            guard !Task.isCancelled, let self, let card else { return }
            self.advance(card)
        }
    }

    /// A drag session runs outside the app's event loop; poll the mouse button to see it end.
    private func watchDragEnd(_ card: ResultCard) {
        Task { [weak self, weak card] in
            repeat {
                try? await Task.sleep(for: .milliseconds(200))
            } while NSEvent.pressedMouseButtons & 1 != 0 && !Task.isCancelled
            guard let self, let card, card.machine.dragging else { return }
            self.interact(card, .dragging(false))
        }
    }

    private func hideDelay(for card: ResultCard) -> Duration? {
        guard EsclopSettings.autoHideFloatingResults.value(in: settings) else { return nil }
        if let hideDelayOverride { return hideDelayOverride }
        let seconds = card.origin == .clipboard
            ? EsclopSettings.autoHideClipboardResultAfter.value(in: settings)
            : EsclopSettings.autoHideFloatingResultsAfter.value(in: settings)
        return .seconds(max(1, seconds))
    }

    nonisolated static func seconds(_ duration: Duration) -> TimeInterval {
        TimeInterval(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    nonisolated static func postAnnouncement(_ text: String) {
        Task { @MainActor in
            NSAccessibility.post(
                element: NSApp as Any, notification: .announcementRequested,
                userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
            )
        }
    }

    /// Replaces a video's first guess from its bytes with one from its frames.
    private func refineEstimate(_ card: ResultCard) {
        Task { [weak card] in
            guard let card, let seconds = await JobEstimate.videoSeconds(of: card.source, aggressive: card.aggressive) else { return }
            card.expectedDuration = seconds
        }
    }

    /// Loads the picture at its own aspect ratio, big enough for the 320 pt detail.
    func loadThumbnail(_ card: ResultCard, url: URL, original: Bool = false) {
        guard loadsThumbnails else { return }
        Task { [weak card] in
            guard let image = await Thumbnails.load(url, side: Metrics.detailWidth) else { return }
            let picture = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
            if original { card?.originalThumbnail = picture } else { card?.thumbnail = picture }
        }
    }

    // MARK: Card actions

    public func perform(_ action: CardPresentation.Action, on card: ResultCard) {
        // Undo, Copy or Save on a card the "Go to the newest result" hotkey reached gives the keys
        // back to the app in front, by key or by click.
        defer { if card.lentKeys, CardKeys.givesKeysBack(action) { returnKeys(from: card) } }
        switch action {
        case .undo:
            // One restore at a time: a second click while it runs would leave a stray copy.
            guard let result = card.result, !card.restoring else { return }
            card.restoring = true
            Task {
                await restore(result)
                card.restoring = false
                // Undo goes back to the card; the other changes in place keep an open detail.
                if case .restored = card.phase { interact(card, .closeDetail) }
            }
        case let .convert(format):
            var choice = card.choice
            choice.format = format
            reprocess(card, choice: choice)
        case .downscale:
            reprocess(card) { $0.request.downscale = 0.5 }
        case .crop:
            card.optionsTab = .crop
            openOptions(card)
        case .more, .convertOptions:
            card.optionsTab = .optimise
            openOptions(card)
        case .compare:
            // In the detail a picture compares in place, with the loupe; the rest in the window,
            // and everything with VoiceOver, which can read the window and not the lens.
            // With the loupe on, Compare goes on to the window (split, difference, zoom).
            if card.loupe == nil, card.machine.level == .detail, card.presentation.loupe, card.loupeSides != nil, !NSWorkspace.shared.isVoiceOverEnabled {
                card.loupe = LoupeState()
            } else if let result = card.result {
                card.loupe = nil
                onCompare?(result)
            }
        case .openDetail:
            interact(card, .openDetail)
        case .closeDetail:
            interact(card, .closeDetail)
        case .retry:
            card.retry?()
        case .reveal:
            reveal([card.savedCopy ?? card.shownFile])
        case .copy:
            writeClipboard(files: [card.shownFile])
        case .dismiss, .stop:
            dismiss(card)
        case .upload:
            upload(card)
        case .cancelUpload:
            card.uploadTask?.cancel()
        case .retryUpload:
            upload(card, to: card.uploadTarget)
        case .copyLink:
            if let link = card.link { copyLink(link) }
        case .share:
            // VoiceOver's route; the pointer's is Share… in the detail's "…" menu.
            card.optionsTab = .share
            openOptions(card)
        case .trash:
            trash(card)
        case .optimiseAnyway, .download:
            card.noticeAction?.run()
            dismiss(card)
        case .save:
            save(card)
        case .saveAs:
            saveAs(card)
        case .keepMetadata:
            // From the original again, the same choice, the metadata kept; the kept crop, scale
            // and fit are made again.
            var choice = card.choice
            choice.stripMetadata = false
            reprocess(card, choice: choice)
        }
    }

    /// Runs a file again with another choice or one change (convert, downscale, fit, crop),
    /// always from the original so quality is not lost twice. The crop, the scale and the fit the
    /// card keeps are made again on every run, as Clop re-runs its steps, until Original or Reset
    /// (`adjust` clears them). The card stays and shows the new result, so an open options
    /// popover keeps its anchor; a rule stays shown only while its choice is the one used.
    func reprocess(_ card: ResultCard, choice: OptimiseChoice? = nil, adjust: ((inout OptimisationJob) -> Void)? = nil) {
        // One re-run at a time on a card, until its run starts (the card is then working, which
        // refuses another). A restore from another window meanwhile is refused by `putBack`.
        guard !card.restoring else { return }
        card.restoring = true
        let origin = card.origin, displayName = card.displayName
        let wasClipboardImage = Self.isCopiedImage(card.source)
        // Read now: the restore below puts the card back to its original.
        let kept = (crop: card.crop, scale: card.downscale, fit: card.fit)
        let choice = choice ?? card.choice
        let rule = card.appliedRule?.choice == choice ? card.appliedRule : nil
        let context = CardContext(origin: card.fileOrigin ?? .unknown, inputType: card.inputType, choice: choice, rule: rule)
        Task {
            var source = card.source
            // A result kept beside its original: the re-run's result replaces it.
            var replaced: OptimisationResult?
            // The files this card may have on the clipboard, which the new result replaces there.
            var shown = [card.source]
            // A result written beside its original (⌥ at the drop) runs again beside it, not over it.
            var besideOriginal = false
            switch card.phase {
            case let .done(result):
                source = result.source
                shown = [result.output, result.source]
                besideOriginal = result.backup == nil && result.output.standardizedFileURL != result.source.standardizedFileURL
                if result.backup == nil {
                    replaced = result
                } else if !(await restore(result)) {
                    // A failed restore shows a notice and the card keeps its result as it was;
                    // encoding the optimised file again would not start from the original.
                    card.restoring = false
                    return
                } else if card.editInTrash {
                    // The restored card that says so lasts only until the run starts.
                    notice(Strings.text("Your edited version is in the Trash"), Strings.text("It changed after optimising. The new result starts from the original."))
                }
            case let .restored(result):
                source = result.source
                shown = [result.source]
                besideOriginal = result.backup == nil && result.output.standardizedFileURL != result.source.standardizedFileURL
            case .working, .failed, .notice:
                card.restoring = false
                return
            case .unchanged:
                break
            }
            card.loupe = nil
            var job = factory.job(for: source, origin: origin, location: wasClipboardImage ? .inPlace : nil)
            if besideOriginal, job.request.location == .inPlace { job.request.location = .sameFolder }
            choice.apply(to: &job.request)
            job.request.crop = kept.crop
            job.request.downscale = kept.scale < 1 ? kept.scale : nil
            let plain = job.operation
            if let fit = kept.fit { job.operation = .fit(underBytes: fit) }
            adjust?(&job)
            // What this run applies the next one applies again; the Size tab's tile follows it.
            card.crop = job.request.crop
            card.downscale = job.request.downscale ?? 1
            if case let .fit(bytes) = job.operation { card.fit = bytes } else { card.fit = nil }
            card.adjusted = job.request.crop != nil || job.request.downscale != nil || job.operation != plain
            let copyBack = origin == .clipboard && EsclopSettings.autoCopyToClipboard.value(in: settings)
            card.restoring = false
            await run(job, displayName: displayName, context: context, reusing: card, onResult: { result in
                if let replaced {
                    self.forget(replaced)
                    self.service.results.append([], withdrawing: [replaced], wait: false)
                }
                guard copyBack else { return }
                Task { await self.putBackOnClipboard(shown.map { ($0, result.output) }) }
            })
            // A failed card has no "…": the popover closes so the failure and its Retry show,
            // instead of controls that can no longer run anything.
            if case .failed = card.phase, card.machine.menuOpen { interact(card, .menu(false)) }
        }
    }

    /// The options popover hangs from the thumbnail's "…": from an open detail (its "…" button
    /// or the VoiceOver action), the detail closes first so the popover has its anchor.
    func openOptions(_ card: ResultCard) {
        if card.machine.level == .detail { interact(card, .closeDetail) }
        interact(card, .menu(true))
    }

    /// Puts the original back, from a card, Recent or Compare. False when it failed: a notice
    /// says why and a card keeps its result (as "Not optimised" it would offer Retry, which
    /// compresses the optimised file again).
    @discardableResult
    public func restore(_ result: OptimisationResult) async -> Bool {
        guard result.backup != nil else {
            // Nothing was replaced, so there is no original to put back (the service would only
            // say no backup is kept).
            notice(Strings.format("Could not restore %@", result.source.lastPathComponent), Self.noBackupMessage(for: result))
            return false
        }
        let shown = cards.first { $0.result?.id == result.id }
        do {
            let editInTrash = try await putBack(result)
            let card = shown ?? ResultCard(jobID: result.requestID ?? result.id, source: result.source, origin: result.origin ?? .app, bytesBefore: result.bytesBefore, phase: .restored(result))
            if shown == nil { add(card) }
            card.phase = .restored(result)
            card.loupe = nil
            card.editInTrash = editInTrash
            // The original is back as it was: no crop or scale left to make again, and a copy
            // saved from the result is not it (Show in Finder shows the original).
            card.crop = nil
            card.downscale = 1
            card.fit = nil
            card.adjusted = false
            card.savedCopy = nil
            loadThumbnail(card, url: result.source)
            settle(card)
            // The optimised copy was on the clipboard: the original replaces it there too.
            await putBackOnClipboard([(result.output, result.source)])
            return true
        } catch is RestoreUnderWay {
            // Another window's restore of it is under way and says how it went.
            return false
        } catch {
            notice(Strings.format("Could not restore %@", result.source.lastPathComponent), CardPresentation.message(for: error))
            return false
        }
    }

    /// The floating result for `result`, shown again when it had gone (the compare window runs
    /// "try another" through it, as the popover does).
    func cardShowing(_ result: OptimisationResult) -> ResultCard {
        cards.first { $0.result?.id == result.id } ?? show(result)
    }

    /// Shows a recent result's card again, and returns it.
    @discardableResult
    public func show(_ result: OptimisationResult) -> ResultCard {
        // Its card, done or restored, never a twin that offers Undo again.
        if let index = cards.firstIndex(where: { card in
            if case let .restored(restored) = card.phase { return restored.id == result.id }
            return card.result?.id == result.id
        }) {
            // It comes to the front, its time starts again.
            let card = cards.remove(at: index)
            cards.append(card)
            settle(card)
            return card
        }
        // Its actions follow where it came from, as the log recorded it; lines from before 0.2
        // have no origin and go by the path. A copied image lives in L'Esclop's clipboard
        // folder: it has no name of its own. A dropped or downloaded file there keeps its name.
        let copiedImage = Self.isCopiedImage(result.source)
        let origin = result.origin ?? (copiedImage ? .clipboard : .app)
        let card = ResultCard(jobID: result.requestID ?? result.id, source: result.source, origin: origin, bytesBefore: result.bytesBefore, phase: .done(result))
        if copiedImage { card.displayName = Strings.text("Copied image") }
        add(card)
        loadThumbnail(card, url: result.output)
        if let backup = result.backup { loadThumbnail(card, url: backup, original: true) }
        settle(card)
        return card
    }

    nonisolated static func size(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }
}
