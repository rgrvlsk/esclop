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
    /// What L'Esclop last wrote to the clipboard, by bytes (`ClipboardFingerprint`).
    @ObservationIgnored var ownWrites: [ClipboardFingerprint] = []
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
    /// The pause hotkey's middle state: the next copy is left alone.
    public var skipNextCopy = false

    public let settings: SettingsStore
    public let service: EsclopService
    public let factory: RequestFactory
    @ObservationIgnored let pasteboard: NSPasteboard
    @ObservationIgnored let reveal: ([URL]) -> Void
    @ObservationIgnored let gate: WorkGate
    /// Uploads to the person's targets, with the keys from the Keychain (tests use memory).
    @ObservationIgnored public var uploader: any FileUploading
    @ObservationIgnored var restoredIDs = Set<UUID>()
    @ObservationIgnored var onCardsChange: (() -> Void)?
    /// Replaces the auto-hide delays from the settings (tests).
    @ObservationIgnored public var hideDelayOverride: Duration?
    @ObservationIgnored public var loadsThumbnails = true
    /// The clock the floating results run on (tests move it by hand).
    @ObservationIgnored public var now: () -> Date = Date.init
    /// Where Save puts a copied image (tests point it elsewhere).
    @ObservationIgnored public var downloads: () -> URL = { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
    /// Announces results to VoiceOver; tests record them instead.
    @ObservationIgnored public var announce: (String) -> Void = AppModel.postAnnouncement
    /// The app in front when a copy happens: one of the origin signals. Tests set it.
    @ObservationIgnored public var frontmostApp: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    /// Size estimates for the options popover, cached per file.
    @ObservationIgnored public lazy var estimator = SizeEstimator(executor: executor(for: .app))

    public init(
        settings: SettingsStore, service: EsclopService, pasteboard: NSPasteboard = .general,
        gate: WorkGate = WorkGate(), reveal: @escaping ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    ) {
        self.settings = settings
        self.service = service
        self.pasteboard = pasteboard
        self.gate = gate
        self.reveal = reveal
        uploader = AppUploader(settings: settings)
        factory = RequestFactory(settings: settings)
        paused = EsclopSettings.pauseAutomaticOptimisations.value(in: settings)
        recent = service.results.recent(limit: Self.recentLimit)
    }

    static let recentLimit = 30
    /// The floating results on screen at once; older ones live on in Recent Results.
    static let visibleLimit = 3

    /// The newest three results, oldest first (the newest sits at the bottom).
    public var visibleCards: [ResultCard] { Array(cards.suffix(Self.visibleLimit)) }

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
        if value { skipNextCopy = false }
        onPauseChange?()
    }

    /// Folders being watched now, for the menu.
    public internal(set) var watchedFolderCount = 0
    /// The watched folders follow the pause.
    @ObservationIgnored var onPauseChange: (() -> Void)?
    /// Opens the compare window on a result.
    @ObservationIgnored public var onCompare: ((OptimisationResult) -> Void)?
    /// Opens the pipeline editor, on a pipeline when one is named.

    @ObservationIgnored public var onOpenPipelines: ((String?) -> Void)?
    /// The menu's "Check for Updates…"; nil when the app cannot update itself (no bundle key).
    @ObservationIgnored public var onCheckForUpdates: (() -> Void)?

    public var status: String {
        if activeFiles > 0 { return activeFiles == 1 ? Strings.text("Optimising 1 file") : Strings.format("Optimising %d files", activeFiles) }
        if paused { return Strings.text("Paused") }
        if skipNextCopy { return Strings.text("Skipping the next copy") }
        return EsclopSettings.enableClipboardOptimiser.value(in: settings) ? Strings.text("Watching the clipboard") : Strings.text("Ready")
    }

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
    /// finishes (the IPC reply stream). Cancelling the calling task stops every file.
    @discardableResult
    public func run(
        _ job: OptimisationJob, displayName: String? = nil, context: CardContext? = nil, reusing existing: ResultCard? = nil,
        batch: Batch? = nil,
        events: @escaping @Sendable (JobEvent) -> Void = { _ in },
        onResult: ((OptimisationResult) -> Void)? = nil
    ) async -> JobReport {
        let executor = executor(for: job.request.origin)
        let batch = batch ?? (existing == nil && job.request.showResultUI && job.request.sources.count >= batchThreshold
            ? openBatch(origin: job.request.origin) : nil)
        var tasks: [(URL, Task<Result<OptimisationResult, EsclopError>, Never>)] = []
        for source in job.request.sources {
            if let batch {
                let row = batch.row(for: source, bytes: Self.size(of: source))
                tasks.append((source, startRow(row, in: batch, job: job, executor: executor, events: events, onResult: onResult)))
                continue
            }
            let card: ResultCard?
            if let existing, cards.contains(where: { $0.id == existing.id }) {
                restart(existing, context: context)
                card = existing
            } else {
                card = job.request.showResultUI ? addCard(for: source, job: job, displayName: displayName, context: context) : nil
            }
            let task = Task { await self.process(source, job: job, executor: executor, card: card, events: events, onResult: onResult) }
            card?.cancelWork = { task.cancel() }
            card?.retry = { [weak self, weak card] in
                guard let self else { return }
                if let card { self.dismiss(card) }
                var again = job
                again.request.id = UUID()
                again.request.sources = [source]
                Task { await self.run(again, displayName: displayName, context: context, onResult: onResult) }
            }
            tasks.append((source, task))
        }
        let running = tasks.map(\.1)
        return await withTaskCancellationHandler {
            var report = JobReport(route: "app")
            for (source, task) in tasks {
                switch await task.value {
                case let .success(result): report.results.append(result)
                case let .failure(error): report.failures.append(FileFailure(source: source, error: error))
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
        _ row: BatchRow, in batch: Batch, job: OptimisationJob, executor: JobExecutor,
        events: @escaping @Sendable (JobEvent) -> Void, onResult: ((OptimisationResult) -> Void)?
    ) -> Task<Result<OptimisationResult, EsclopError>, Never> {
        let source = row.source
        var single = job
        single.request.sources = [source]
        let task = Task { await self.process(source, job: single, executor: executor, card: nil, row: row, batch: batch, events: events, onResult: onResult) }
        row.cancel = { task.cancel() }
        row.retry = { [weak self, weak row, weak batch] in
            guard let self, let row, let batch, row.isFinished else { return }
            row.state = .waiting
            var again = single
            again.request.id = UUID()
            _ = self.startRow(row, in: batch, job: again, executor: executor, events: { _ in }, onResult: onResult)
        }
        return task
    }

    /// Puts one batch file's original back, without a floating result.
    public func restore(_ row: BatchRow) async {
        guard let result = row.result, result.backup != nil else { return }
        do {
            _ = try service.restoreBackup(of: result, deleteBackup: false)
            restoredIDs.insert(result.id)
            noteWritten([result.source, result.output])
            row.state = .restored(result)
        } catch {
            row.state = .failed(CardPresentation.message(for: error))
        }
    }

    public func restoreAll(_ batch: Batch) async {
        for row in batch.restorable { await restore(row) }
    }

    /// The executor for a request's origin: agents get the pipeline permissions the person set.
    func executor(for origin: RequestOrigin) -> JobExecutor {
        let context = service.context
        let policy = AgentPolicy(origin: origin, permissions: context.settings)
        // Agents upload only when the person allows it; the policy refuses before this, and an
        // executor without an uploader cannot upload anyway.
        let uploader: (any FileUploading)? = policy.allowed(.allowUploads) ? uploader : nil
        let host = uploader.map { uploader in
            AppPipelineHost(uploader: uploader) { [weak self] link in await self?.copyLink(link) }
        }
        let runner = StorePipelineRunner(
            store: context.pipelines, allowRunScripts: policy.allowed(.allowRunScripts),
            allowDelete: policy.allowed(.allowOverwriteOriginals), temporaryDirectory: Paths.temporary, host: host
        )
        return JobExecutor(engine: context.engine, pipelineRunner: runner, uploader: uploader, backups: context.locations.backups)
    }

    private func process(
        _ source: URL, job: OptimisationJob, executor: JobExecutor, card: ResultCard?, row: BatchRow? = nil, batch: Batch? = nil,
        events: @escaping @Sendable (JobEvent) -> Void, onResult: ((OptimisationResult) -> Void)?
    ) async -> Result<OptimisationResult, EsclopError> {
        activeFiles += 1
        defer { activeFiles -= 1 }
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
        if Task.isCancelled {
            outcome = .failure(.cancelled)
        } else {
            let cardID = card?.id
            do {
                let result = try await executor.process(source, job: job) { [weak self, weak row] progress in
                    Task { @MainActor in
                        if let cardID { self?.progress(progress.fraction, cardID: cardID) }
                        if let row, case let .working(current) = row.state, progress.fraction > current { row.state = .working(progress.fraction) }
                    }
                }
                outcome = .success(result)
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
                copyLink(link)
            } else if let card, uploadsAutomatically(job) {
                upload(card)
            }
            onResult?(result)
        case let .failure(error):
            events(.failure(FileFailure(source: source, error: error)))
            if error == .alreadySmaller {
                card?.phase = .unchanged(bytes: Self.size(of: source))
                row?.state = .unchanged
            } else {
                card?.phase = .failed(CardPresentation.message(for: error))
                row?.state = error == .cancelled ? .cancelled : .failed(CardPresentation.message(for: error))
            }
        }
        if let card { settle(card) }
        if let batch, !batch.isRunning { announce(BatchPresentation(batch: batch).announcement) }
        return outcome
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

    /// A new file in a folder a pipeline watches: the pipeline runs on it.
    public func runPipeline(_ name: String, onWatched file: URL) {
        var job = factory.job(for: file, origin: .watchedFolder)
        job.operation = .pipeline(name)
        Task { await run(job) }
    }

    func record(_ result: OptimisationResult) {
        recent.removeAll { $0.id == result.id }
        recent.insert(result, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
        // The CLI and MCP server read the same log (`esclop_recent_results`, restore).
        service.results.append([result])
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
        cards.removeAll { $0.id == card.id }
    }

    /// Removes the cards of jobs the CLI or MCP server stopped with `remove`.
    public func removeCards(ofJobs ids: [UUID]) {
        for card in cards where ids.contains(card.jobID) { dismiss(card) }
    }

    public func notice(_ title: String, _ detail: String) {
        cards.filter { if case .notice = $0.phase { return true } else { return false } }.forEach(dismiss)
        let card = ResultCard(jobID: UUID(), source: URL(fileURLWithPath: "/"), origin: .app, bytesBefore: 0, phase: .notice(title: title, detail: detail))
        card.machine.notice(at: now(), hideAfter: hideDelayOverride.map(Self.seconds) ?? 3)
        add(card)
    }

    // MARK: Floating result state

    /// What the person does to a floating result.
    public enum Interaction: Equatable, Sendable {
        case pointerEntered, pointerExited
        case openDetail, closeDetail
        case focus(Bool), dragging(Bool), menu(Bool)
    }

    public func interact(_ card: ResultCard, _ interaction: Interaction) {
        let time = now()
        switch interaction {
        case .pointerEntered: card.machine.pointerEntered(at: time)
        case .pointerExited: card.machine.pointerExited(at: time)
        case .openDetail:
            // The options popover belongs to the card; the detail opens without it, and without
            // its "…" menu open.
            card.machine.setMenuOpen(false, at: time)
            card.machine.openDetail(at: time)
        case .closeDetail:
            card.machine.setMenuOpen(false, at: time)
            card.machine.closeDetail(at: time)
        case let .focus(value): card.machine.setFocused(value, at: time)
        case let .dragging(value):
            card.machine.setDragging(value, at: time)
            if value { watchDragEnd(card) }
        case let .menu(value):
            card.menuHighlight = nil
            card.machine.setMenuOpen(value, at: time)
        }
        afterChange(card)
    }

    /// The result arrived, failed or changed: its auto-hide starts now.
    func settle(_ card: ResultCard) {
        let time = now()
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
        switch action {
        case .undo:
            guard let result = card.result else { return }
            Task { await restore(result) }
        case let .convert(format):
            var choice = card.choice
            choice.format = format
            reprocess(card, choice: choice)
        case .downscale:
            reprocess(card) { $0.request.downscale = 0.5 }
        case .crop:
            card.optionsTab = .size
            openOptions(card)
        case .more, .convertOptions:
            card.optionsTab = .optimise
            openOptions(card)
        case .compare:
            if let result = card.result { onCompare?(result) }
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
        case .save:
            save(card)
        case .saveAs:
            saveAs(card)
        case .keepMetadata:
            // From the original again, the same choice, the metadata kept.
            var choice = card.choice
            choice.stripMetadata = false
            reprocess(card, choice: choice)
        }
    }

    /// Runs a file again with another choice or one change (convert, downscale, fit, crop),
    /// always from the original so quality is not lost twice. The card stays and shows the new
    /// result, so an open options popover keeps its anchor; a rule stays shown only while its
    /// choice is the one used.
    func reprocess(_ card: ResultCard, choice: OptimiseChoice? = nil, adjust: @escaping (inout OptimisationJob) -> Void = { _ in }) {
        let origin = card.origin, displayName = card.displayName
        let wasClipboardImage = card.source.path.hasPrefix(Paths.temporary.path)
        let choice = choice ?? card.choice
        let rule = card.appliedRule?.choice == choice ? card.appliedRule : nil
        let context = CardContext(origin: card.fileOrigin ?? .unknown, inputType: card.inputType, choice: choice, rule: rule)
        Task {
            var source = card.source
            switch card.phase {
            case let .done(result):
                source = result.source
                if result.backup != nil { await restore(result) }
            case let .restored(result):
                source = result.source
            case .working, .failed, .notice:
                return
            case .unchanged:
                break
            }
            var job = factory.job(for: source, origin: origin, location: wasClipboardImage ? .inPlace : nil)
            choice.apply(to: &job.request)
            adjust(&job)
            let copyBack = origin == .clipboard && EsclopSettings.autoCopyToClipboard.value(in: settings)
            await run(job, displayName: displayName, context: context, reusing: card, onResult: { result in
                guard copyBack else { return }
                self.writeClipboard(files: [result.output])
            })
        }
    }

    /// The options popover hangs from the thumbnail's "…": from an open detail (its "…" button
    /// or the VoiceOver action), the detail closes first so the popover has its anchor.
    func openOptions(_ card: ResultCard) {
        if card.machine.level == .detail { interact(card, .closeDetail) }
        interact(card, .menu(true))
    }

    /// Puts the original back, from a card or the backups menu.
    public func restore(_ result: OptimisationResult) async {
        let card = cards.first { $0.result?.id == result.id }
        do {
            _ = try await service.restoreBackup(for: result.output, deleteBackup: false)
            restoredIDs.insert(result.id)
            noteWritten([result.source, result.output])
            if let card {
                card.phase = .restored(result)
                loadThumbnail(card, url: result.source)
                settle(card)
            } else {
                let card = ResultCard(jobID: result.id, source: result.source, origin: .app, bytesBefore: result.bytesBefore, phase: .restored(result))
                add(card)
                loadThumbnail(card, url: result.source)
                settle(card)
            }
            if pasteboardHolds(result.output) {
                // The optimised copy was on the clipboard: the original replaces it there too.
                writeClipboard(files: [result.source])
            }
        } catch {
            if let card { card.phase = .failed(CardPresentation.message(for: error)) } else {
                notice(Strings.format("Could not restore %@", result.source.lastPathComponent), CardPresentation.message(for: error))

            }
        }
    }

    func pasteboardHolds(_ url: URL) -> Bool {
        guard Clipboard.isOwnWrite(pasteboard), case let .files(urls) = Clipboard.read(pasteboard) else { return false }
        return urls.contains { $0.standardizedFileURL.path == url.standardizedFileURL.path }
    }

    /// The floating result for `result`, shown again when it had gone (the compare window runs
    /// "try another" through it, as the popover does).
    func cardShowing(_ result: OptimisationResult) -> ResultCard {
        if let card = cards.first(where: { $0.result?.id == result.id }) { return card }
        show(result)
        return cards.first { $0.result?.id == result.id }!
    }

    /// Shows a recent result's card again.
    public func show(_ result: OptimisationResult) {

        if cards.contains(where: { $0.result?.id == result.id }) { return }
        let card = ResultCard(jobID: result.id, source: result.source, origin: .app, bytesBefore: result.bytesBefore, phase: .done(result))
        add(card)
        loadThumbnail(card, url: result.output)
        if let backup = result.backup { loadThumbnail(card, url: backup, original: true) }
        settle(card)
    }

    nonisolated static func size(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }
}
