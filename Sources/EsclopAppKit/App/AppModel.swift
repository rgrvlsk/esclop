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
    @ObservationIgnored var restoredIDs = Set<UUID>()
    @ObservationIgnored var onCardsChange: (() -> Void)?
    /// Replaces the auto-hide delays from the settings (tests).
    @ObservationIgnored public var hideDelayOverride: Duration?
    @ObservationIgnored public var loadsThumbnails = true

    public init(
        settings: SettingsStore, service: EsclopService, pasteboard: NSPasteboard = .general,
        gate: WorkGate = WorkGate(), reveal: @escaping ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    ) {
        self.settings = settings
        self.service = service
        self.pasteboard = pasteboard
        self.gate = gate
        self.reveal = reveal
        factory = RequestFactory(settings: settings)
        paused = EsclopSettings.pauseAutomaticOptimisations.value(in: settings)
        recent = service.results.recent(limit: Self.recentLimit)
    }

    static let recentLimit = 30

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
    public var followCursorScreen: Bool { EsclopSettings.followCursorScreen.value(in: settings) }

    public func setPaused(_ value: Bool) {
        try? EsclopSettings.pauseAutomaticOptimisations.set(value, in: settings)
        pauseChanged(value)
    }

    /// Called when the setting changed, here or in another process.
    public func pauseChanged(_ value: Bool) {
        paused = value
        if value { skipNextCopy = false }
    }

    public var status: String {
        if activeFiles > 0 { return activeFiles == 1 ? "Optimising 1 file" : "Optimising \(activeFiles) files" }
        if paused { return "Paused" }
        if skipNextCopy { return "Skipping the next copy" }
        return EsclopSettings.enableClipboardOptimiser.value(in: settings) ? "Watching the clipboard" : "Ready"
    }

    /// Results whose original can still be put back.
    public var restorable: [OptimisationResult] {
        recent.filter { result in
            guard let backup = result.backup, !restoredIDs.contains(result.id) else { return false }
            return FileManager.default.fileExists(atPath: backup.path)
        }
    }

    // MARK: Running jobs

    /// Runs a job, one card per file when it asks for result UI. `events` reports each file as
    /// it finishes (the IPC reply stream). Cancelling the calling task stops every file.
    @discardableResult
    public func run(
        _ job: OptimisationJob, displayName: String? = nil,
        events: @escaping @Sendable (JobEvent) -> Void = { _ in },
        onResult: ((OptimisationResult) -> Void)? = nil
    ) async -> JobReport {
        let executor = executor(for: job.request.origin)
        var tasks: [(URL, Task<Result<OptimisationResult, EsclopError>, Never>)] = []
        for source in job.request.sources {
            let card = job.request.showResultUI ? addCard(for: source, job: job, displayName: displayName) : nil
            let task = Task { await self.process(source, job: job, executor: executor, card: card, events: events, onResult: onResult) }
            card?.cancelWork = { task.cancel() }
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

    /// The executor for a request's origin: agents get the pipeline permissions the person set.
    func executor(for origin: RequestOrigin) -> JobExecutor {
        let context = service.context
        let policy = AgentPolicy(origin: origin, permissions: context.settings)
        let runner = StorePipelineRunner(
            store: context.pipelines, allowRunScripts: policy.allowed(.allowRunScripts),
            allowDelete: policy.allowed(.allowOverwriteOriginals), temporaryDirectory: Paths.temporary
        )
        return JobExecutor(engine: context.engine, pipelineRunner: runner, backups: context.locations.backups)
    }

    private func process(
        _ source: URL, job: OptimisationJob, executor: JobExecutor, card: ResultCard?,
        events: @escaping @Sendable (JobEvent) -> Void, onResult: ((OptimisationResult) -> Void)?
    ) async -> Result<OptimisationResult, EsclopError> {
        activeFiles += 1
        defer { activeFiles -= 1 }
        await gate.acquire()
        let outcome: Result<OptimisationResult, EsclopError>
        if Task.isCancelled {
            outcome = .failure(.cancelled)
        } else {
            let cardID = card?.id
            do {
                let result = try await executor.process(source, job: job) { [weak self] progress in
                    guard let cardID else { return }
                    Task { @MainActor in self?.progress(progress.fraction, cardID: cardID) }
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
            record(result)
            card?.phase = .done(result)
            if let card { loadThumbnail(card, url: result.output) }
            onResult?(result)
        case let .failure(error):
            events(.failure(FileFailure(source: source, error: error)))
            if error == .alreadySmaller {
                card?.phase = .unchanged(bytes: Self.size(of: source))
            } else {
                card?.phase = .failed(CardPresentation.message(for: error))
            }
        }
        if let card { scheduleHide(card) }
        return outcome
    }

    private func progress(_ fraction: Double, cardID: UUID) {
        guard let card = cards.first(where: { $0.id == cardID }), case let .working(current) = card.phase else { return }
        if fraction > current { card.phase = .working(fraction: fraction) }
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
    func addCard(for source: URL, job: OptimisationJob, displayName: String? = nil) -> ResultCard {
        let card = ResultCard(
            jobID: job.id, source: source, origin: job.request.origin,
            aggressive: job.request.quality.tier == .aggressive, bytesBefore: Self.size(of: source)
        )
        card.displayName = displayName
        add(card)
        loadThumbnail(card, url: source)
        return card
    }

    func add(_ card: ResultCard) {
        card.onHoverChange = { [weak self, weak card] hovering in
            guard let self, let card, !hovering, let deadline = card.hideDeadline, deadline <= Date() else { return }
            // The time ran out while the pointer was on the card: go shortly after it leaves.
            self.scheduleHide(card, after: .seconds(2))
        }
        cards.append(card)
    }

    public func dismiss(_ card: ResultCard) {
        card.hideTask?.cancel()
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
        add(card)
        scheduleHide(card, after: hideDelayOverride ?? .seconds(3))
    }

    func scheduleHide(_ card: ResultCard, after delay: Duration? = nil) {
        if case .notice = card.phase, delay == nil { return }
        let delay = delay ?? hideDelay(for: card)
        guard let delay else { return }
        card.hideTask?.cancel()
        card.hideDeadline = Date().addingTimeInterval(TimeInterval(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18)
        card.hideTask = Task { [weak self, weak card] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let card, !card.isHovered else { return }
            self.dismiss(card)
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

    private func loadThumbnail(_ card: ResultCard, url: URL) {
        guard loadsThumbnails else { return }
        Task { [weak card] in
            guard let image = await Thumbnails.load(url) else { return }
            card?.thumbnail = NSImage(cgImage: image, size: NSSize(width: Metrics.thumbnail, height: Metrics.thumbnail))
        }
    }

    // MARK: Card actions

    public func perform(_ action: CardPresentation.Action, on card: ResultCard) {
        switch action {
        case .restore:
            guard let result = card.result else { return }
            Task { await restore(result) }
        case .reveal:
            reveal([fileShown(by: card)])
        case .copy:
            Clipboard.write(files: [fileShown(by: card)], to: pasteboard)
        case .dismiss:
            dismiss(card)
        }
    }

    private func fileShown(by card: ResultCard) -> URL {
        if case let .done(result) = card.phase { return result.output }
        if case let .restored(result) = card.phase { return result.source }
        return card.source
    }

    /// Puts the original back, from a card or the backups menu.
    public func restore(_ result: OptimisationResult) async {
        let card = cards.first { $0.result?.id == result.id }
        do {
            _ = try await service.restoreBackup(for: result.output, deleteBackup: false)
            restoredIDs.insert(result.id)
            if let card {
                card.phase = .restored(result)
                scheduleHide(card)
            } else {
                let card = ResultCard(jobID: result.id, source: result.source, origin: .app, bytesBefore: result.bytesBefore, phase: .restored(result))
                add(card)
                loadThumbnail(card, url: result.source)
                scheduleHide(card)
            }
            if pasteboardHolds(result.output) {
                // The optimised copy was on the clipboard: the original replaces it there too.
                Clipboard.write(files: [result.source], to: pasteboard)
            }
        } catch {
            if let card { card.phase = .failed(CardPresentation.message(for: error)) } else {
                notice("Could not restore \(result.source.lastPathComponent)", CardPresentation.message(for: error))
            }
        }
    }

    private func pasteboardHolds(_ url: URL) -> Bool {
        guard Clipboard.isOwnWrite(pasteboard), case let .files(urls) = Clipboard.read(pasteboard) else { return false }
        return urls.contains { $0.standardizedFileURL.path == url.standardizedFileURL.path }
    }

    /// Shows a recent result's card again.
    public func show(_ result: OptimisationResult) {
        if cards.contains(where: { $0.result?.id == result.id }) { return }
        let card = ResultCard(jobID: result.id, source: result.source, origin: .app, bytesBefore: result.bytesBefore, phase: .done(result))
        card.hasPlayedArrival = true
        add(card)
        loadThumbnail(card, url: result.output)
        scheduleHide(card)
    }

    nonisolated static func size(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }
}
