// SPDX-License-Identifier: GPL-3.0-or-later
//
// Watches the folders `WatchPlan` lists and hands new files to the app model: files of one kind
// that appear in one folder within a second form a burst, a burst larger than the kind's count
// is left alone with a notice (Clop's rule) that can optimise them anyway, and every other file
// goes on as soon as it stops changing: it is optimised or its folder's pipeline runs. Pause
// stops the stream; the settings, the pipelines, the pause and a watched folder that appears,
// moves or goes away all restart it.

import AppKit
import EsclopCore
import EsclopIPC
import EsclopPipelines
import Foundation
import Observation
import UniformTypeIdentifiers

/// Whether L'Esclop can watch a folder, as the settings and the menu say it.
public enum FolderStatus: Equatable, Sendable {
    case watching
    /// The folder is not there (an unmounted disk, a deleted folder): skipped until it is back.
    case missing
    /// macOS keeps L'Esclop out (Files and Folders privacy): the person has to allow it.
    case unreadable
    /// FSEvents refused the stream, so nothing is watched until the next restart.
    case notWatching

    /// Whether the folder is there, without reading inside it. Reading a protected folder
    /// (Desktop, Documents, Downloads) makes macOS ask for access, so the watcher only looks at
    /// the folder itself and leaves the question for the first new file, as Clop does.
    public static func presence(_ folder: URL) -> FolderStatus {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return .missing }
        return .watching
    }

    /// Whether L'Esclop can read the folder: lists it, so macOS may ask for access. For the
    /// Settings row the person is looking at.
    public static func check(_ folder: URL) -> FolderStatus {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return .missing }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            return .watching
        } catch {
            return .unreadable
        }
    }
}

@MainActor @Observable
public final class WatchedFolders {
    public private(set) var targets: [WatchTarget] = []
    public private(set) var statuses: [URL: FolderStatus] = [:]
    /// The stream runs (not paused, at least one folder to watch).
    public private(set) var isWatching = false

    @ObservationIgnored let model: AppModel
    @ObservationIgnored let pipelines: () -> [Pipeline]
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var bursts: [BurstKey: [URL]] = [:]
    @ObservationIgnored private var burstTasks: [BurstKey: Task<Void, Never>] = [:]
    /// Files picked up and not finished yet, held until their job is done: one file runs once,
    /// however many events it brings while it settles and is optimised.
    @ObservationIgnored private(set) var inFlight = Set<String>()
    /// Folders macOS kept L'Esclop out of.
    @ObservationIgnored private(set) var denied = Set<URL>()
    /// How long files of one kind gather into a burst.
    @ObservationIgnored var burstWindow: Duration = .seconds(1)
    /// Files picked up that arrived whole (`FileSettle.arrivedWhole`), by path, until their job is done.
    @ObservationIgnored private var arrivedWhole = Set<String>()
    /// Waits for a file; the flag says it arrived whole, so the still checks alone settle it.
    @ObservationIgnored var settle: @Sendable (URL, Bool) async -> FileSettle.Outcome = { await FileSettle.wait(for: $0, quiet: $1 ? 0 : FileSettle.quiet) }

    /// Files of one kind that arrive in one folder: a burst in Downloads leaves a Desktop
    /// screenshot alone.
    private struct BurstKey: Hashable {
        let folder: URL
        let kind: MediaKind
    }

    /// The batch a burst's files share, opened by its first file that is optimised: a burst
    /// that goes to a pipeline or is skipped opens no window.
    private final class BurstBatch {
        var batch: Batch?
    }

    public init(model: AppModel, pipelines: @escaping () -> [Pipeline]) {
        self.model = model
        self.pipelines = pipelines
    }

    /// Folders being watched now: existing and readable.
    public var watchedCount: Int { isWatching ? statuses.values.filter { $0 == .watching }.count : 0 }

    /// Reads the settings and the pipelines again and restarts the stream. A folder macOS kept
    /// L'Esclop out of stays out (no reads, no new question) until `retryDenied`: the folder
    /// lists changed, or the app starts again.
    public func refresh(retryDenied: Bool = false) {
        if retryDenied { denied.removeAll() }
        targets = WatchPlan.targets(settings: model.settings, pipelines: pipelines())
        statuses = Dictionary(targets.map { target in
            (target.folder, denied.contains(target.folder) ? .unreadable : FolderStatus.presence(target.folder))
        }, uniquingKeysWith: { first, _ in first })
        // Missing folders too: the stream reports them when they appear.
        // ponytail: one missing path FSEvents refuses (over 1 KB long) stops the whole stream and
        // every row says not watching; retry with the existing folders only if that is ever seen.
        let folders = targets.map(\.folder).filter { statuses[$0] != .unreadable }
        watcher?.stop()
        defer { model.watchedFolderCount = watchedCount }
        guard !model.paused, !folders.isEmpty else {
            isWatching = false
            return
        }
        let watcher = watcher ?? FolderWatcher(rootChanged: { [weak self] in
            Task { @MainActor in self?.refresh() }
        }) { [weak self] files, renamed in
            Task { @MainActor in self?.received(files, renamed: renamed) }
        }
        self.watcher = watcher
        isWatching = watcher.start(folders)
        if !isWatching {
            for (folder, status) in statuses where status == .watching { statuses[folder] = .notWatching }
        }
    }

    public func stop() {
        watcher?.stop()
        isWatching = false
        model.watchedFolderCount = 0
    }

    /// The settings that change what is watched.
    public static let settingKeys: [String] = WatchPlan.lists.flatMap { [$0.1.key, $0.2.key] }
        + [EsclopSettings.pauseAutomaticOptimisations.key, EsclopSettings.watchedFolderRules.key]

    // MARK: Events

    /// Files the stream reported. Decided at once (a stat and an xattr read each), so files that
    /// arrive together join the same burst.
    func received(_ files: [URL], renamed: Set<URL> = []) {
        guard isWatching, !model.paused else { return }
        let firstSeen = Date()
        let screenshots = WatchPlan.canonical(OriginSignals.screenshotFolder()).path
        // One spelling per file (/var or /private/var), whoever reports it.
        // ponytail: a file replaced while its job runs is not looked at again; queue one more pass
        // for files with events during their job if that is ever seen.
        for reported in files {
            let file = reported.resolvingSymlinksInPath()
            guard !inFlight.contains(file.path) else { continue }
            let folder = WatchPlan.canonical(file.deletingLastPathComponent().path)
            guard !denied.contains(folder) else { continue }
            let size: Int
            let modified: Date?
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                size = (attributes[.size] as? NSNumber)?.intValue ?? 0
                modified = attributes[.modificationDate] as? Date
            } catch {
                if Self.isDenied(error) { deny(folder) }
                continue
            }
            let decision = WatchPlan.decide(
                file, targets: targets, size: size, isMarked: OptimisedMark.isMarked(file),
                justWritten: model.wasJustWritten(file), ignored: Self.isIgnored(file),
                limits: { self.model.factory.sizeLimits(for: $0) }
            )
            guard let kind = decision.kind else { continue }
            inFlight.insert(file.path)
            if FileSettle.arrivedWhole(
                renamed: renamed.contains(reported), isScreenshot: Self.isScreenshot(file, kind: kind, folder: folder.path, screenshots: screenshots),
                modified: modified, firstSeen: firstSeen
            ) {
                arrivedWhole.insert(file.path)
            }
            add(file, to: BurstKey(folder: folder, kind: kind))
        }
    }

    /// macOS refused to let L'Esclop read in `folder`: it leaves the stream and its Settings row
    /// says why. Nothing else happens: no notice, no new attempt.
    func deny(_ folder: URL) {
        guard !denied.contains(folder) else { return }
        denied.insert(folder)
        refresh()
    }

    nonisolated static func isDenied(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { return true }
        if error.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(error.code) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error { return isDenied(underlying) }
        return false
    }

    private func add(_ file: URL, to key: BurstKey) {
        bursts[key, default: []].append(file)
        guard burstTasks[key] == nil else { return }
        burstTasks[key] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: burstWindow)
            close(key)
        }
    }

    /// The burst is complete: too many files are left alone, with a notice that can optimise
    /// them anyway; the rest go on.
    private func close(_ key: BurstKey) {
        let burst = Burst(kind: key.kind, files: bursts[key] ?? [], limit: WatchPlan.countLimit(key.kind, settings: model.settings))
        bursts[key] = nil
        burstTasks[key] = nil
        guard burst.isTooLarge else { return start(burst.files) }
        burst.files.forEach { inFlight.remove($0.path); arrivedWhole.remove($0.path) }
        model.notice(
            Self.tooManyTitle(key.kind, count: burst.limit),
            Strings.format("They appeared together in %@, so L’Esclop left them alone.", PathInput.abbreviate(key.folder)),
            action: (.optimiseAnyway, { [weak self] in self?.optimiseAnyway(burst.files) })
        )
    }

    /// The notice's action: the files it left alone, unless they are already on their way.
    func optimiseAnyway(_ files: [URL]) {
        start(files.filter { inFlight.insert($0.path).inserted })
    }

    /// Each file waits for itself alone: one still being written holds no other. A burst the
    /// size of a batch shares one batch window, as dropped files do; rows join as files start.
    private func start(_ files: [URL]) {
        let batch = files.count >= model.batchThreshold ? BurstBatch() : nil
        for file in files {
            Task { [weak self] in await self?.process(file, batch: batch) }
        }
    }

    /// Settles one file, decides it again (it may have been optimised or replaced meanwhile) and
    /// runs its job; the file stays in flight until the job is done.
    private func process(_ file: URL, batch: BurstBatch?) async {
        defer { inFlight.remove(file.path); arrivedWhole.remove(file.path) }
        let settled = await settle(file, arrivedWhole.contains(file.path))
        guard !model.paused else { return }
        if settled == .unreadable {
            return model.notice(
                Strings.format("Could not read %@", file.lastPathComponent),
                Strings.text("L’Esclop is not allowed to open it, so it left it alone.")
            )
        }
        guard settled == .steady else { return }
        var decision = WatchPlan.decide(
            file, targets: targets, size: Self.size(of: file), isMarked: OptimisedMark.isMarked(file),
            justWritten: model.wasJustWritten(file), ignored: Self.isIgnored(file),
            limits: { self.model.factory.sizeLimits(for: $0) }
        )
        // Pixels are read once the file is whole, and only for a folder with pixel limits.
        if let kind = decision.kind, kind == .image || kind == .video,
           let rules = targets.first(where: { $0.folder.path == file.deletingLastPathComponent().path })?.rules,
           rules.minPixels != nil || rules.maxPixels != nil,
           let skip = rules.skip(longerSide: await SystemMediaInspector().pixelSize(file).map { max($0.width, $0.height) }) {
            decision = .skip(skip)
        }
        // The burst's batch, opened by its first file to start.
        func shared() -> Batch? {
            if let batch, batch.batch == nil { batch.batch = model.openBatch(origin: .watchedFolder) }
            return batch?.batch
        }
        switch decision {
        case .optimise:
            let job = model.factory.job(for: file, origin: .watchedFolder)
            await model.run(job, batch: job.request.showResultUI ? shared() : nil)
        case let .pipeline(name, _): await model.runPipeline(name, onWatched: file, batch: shared)
        case .skip: return
        }
    }

    static func tooManyTitle(_ kind: MediaKind, count: Int) -> String {
        switch kind {
        case .image: return Strings.format("More than %d new images at once", count)
        case .video: return count == 1 ? Strings.text("More than one new video at once") : Strings.format("More than %d new videos at once", count)
        case .pdf: return Strings.format("More than %d new PDFs at once", count)
        case .audio: return Strings.format("More than %d new audio files at once", count)
        }
    }

    /// An image in the folder macOS saves screenshots to, under a name it gives them: the sure,
    /// cheap case of a file that arrives whole.
    nonisolated static func isScreenshot(_ file: URL, kind: MediaKind, folder: String, screenshots: String) -> Bool {
        guard kind == .image, folder == screenshots else { return false }
        var signals = OriginSignals(inputType: UTType(filenameExtension: file.pathExtension)?.identifier ?? "public.image")
        signals.fileName = file.lastPathComponent
        signals.folder = folder
        signals.screenshotFolder = screenshots
        return OriginClassifier.classify(signals) == .screenshot
    }

    /// The folder's `.esclopignore` or `.clopignore`, or the one for the file's kind
    /// (`.clopignore-video`), matches the file's name.
    // ponytail: the ignore files (up to four) are read on the main actor for each new file
    // (twice: on arrival and before its job), a few small reads; read them once per burst if a
    // large unzip into a watched folder shows as a hang.
    nonisolated static func isIgnored(_ file: URL) -> Bool {
        IgnoreFile.ignores(file.lastPathComponent, patterns: IgnoreFile.patterns(in: file.deletingLastPathComponent(), for: MediaKind.of(file)))
    }

    nonisolated static func size(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }
}
