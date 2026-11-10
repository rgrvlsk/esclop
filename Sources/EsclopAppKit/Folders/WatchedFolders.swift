// SPDX-License-Identifier: GPL-3.0-or-later
//
// Watches the folders `WatchPlan` lists and hands new files to the app model: files of one kind
// that appear within a second form a burst, a burst larger than the kind's count is left alone
// with a notice (Clop's rule), and every other file waits until it stops changing before it is
// optimised or its folder's pipeline runs. Pause stops the stream; the settings, the pipelines
// and the pause all restart it.

import AppKit
import EsclopCore
import EsclopIPC
import EsclopPipelines
import Foundation
import Observation

/// Whether L'Esclop can watch a folder, as the settings and the menu say it.
public enum FolderStatus: Equatable, Sendable {
    case watching
    /// The folder is not there (an unmounted disk, a deleted folder): skipped until it is back.
    case missing
    /// macOS keeps L'Esclop out (Files and Folders privacy): the person has to allow it.
    case unreadable

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
    @ObservationIgnored private var bursts: [MediaKind: [URL]] = [:]
    @ObservationIgnored private var burstTasks: [MediaKind: Task<Void, Never>] = [:]
    /// Files picked up and not finished yet: one event per file is enough.
    @ObservationIgnored private var inFlight = Set<String>()
    /// Folders macOS kept L'Esclop out of.
    @ObservationIgnored private(set) var denied = Set<URL>()
    /// How long files of one kind gather into a burst.
    @ObservationIgnored var burstWindow: Duration = .seconds(1)
    @ObservationIgnored var settle: @Sendable (URL) async -> Bool = { await FileSettle.wait(for: $0) }

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
        let folders = targets.map(\.folder).filter { statuses[$0] == .watching }
        watcher?.stop()
        defer { model.watchedFolderCount = watchedCount }
        guard !model.paused, !folders.isEmpty else {
            isWatching = false
            return
        }
        let watcher = watcher ?? FolderWatcher { [weak self] files in
            Task { @MainActor in self?.received(files) }
        }
        watcher.start(folders)
        self.watcher = watcher
        isWatching = true
    }

    public func stop() {
        watcher?.stop()
        isWatching = false
        model.watchedFolderCount = 0
    }

    /// The settings that change what is watched.
    public static let settingKeys: [String] = WatchPlan.lists.flatMap { [$0.1.key, $0.2.key] } + [EsclopSettings.pauseAutomaticOptimisations.key]

    // MARK: Events

    /// Files the stream reported. Decided at once (a stat and an xattr read each), so files that
    /// arrive together join the same burst.
    func received(_ files: [URL]) {
        guard isWatching, !model.paused else { return }
        for file in files where !inFlight.contains(file.path) {
            let folder = WatchPlan.canonical(file.deletingLastPathComponent().path)
            guard !denied.contains(folder) else { continue }
            let size: Int
            do {
                size = ((try FileManager.default.attributesOfItem(atPath: file.path))[.size] as? NSNumber)?.intValue ?? 0
            } catch {
                if Self.isDenied(error) { deny(folder) }
                continue
            }
            let decision = WatchPlan.decide(
                file, targets: targets, size: size, isMarked: OptimisedMark.isMarked(file),
                justWritten: model.wasJustWritten(file), limits: { self.model.factory.sizeLimits(for: $0) }
            )
            guard let kind = decision.kind else { continue }
            inFlight.insert(file.path)
            add(file, kind: kind)
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

    private func add(_ file: URL, kind: MediaKind) {
        bursts[kind, default: []].append(file)
        guard burstTasks[kind] == nil else { return }
        burstTasks[kind] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: burstWindow)
            await close(kind)
        }
    }

    /// The burst of `kind` is complete: too many files are left alone, the rest go on once they
    /// stop changing.
    private func close(_ kind: MediaKind) async {
        let burst = Burst(kind: kind, files: bursts[kind] ?? [], limit: WatchPlan.countLimit(kind, settings: model.settings))
        bursts[kind] = nil
        burstTasks[kind] = nil
        if burst.isTooLarge {
            let folder = burst.files.first.map { PathInput.abbreviate($0.deletingLastPathComponent()) } ?? ""
            model.notice(Self.tooManyTitle(kind, count: burst.limit), Strings.format("They appeared together in %@, so L’Esclop left them alone.", folder))
            burst.files.forEach { inFlight.remove($0.path) }
            return
        }
        var plain: [URL] = []
        for file in burst.files {
            defer { inFlight.remove(file.path) }
            guard await settle(file), !model.paused else { continue }
            // Decided again: the file may have been optimised or replaced while it settled.
            let decision = WatchPlan.decide(
                file, targets: targets, size: Self.size(of: file), isMarked: OptimisedMark.isMarked(file),
                justWritten: model.wasJustWritten(file), limits: { self.model.factory.sizeLimits(for: $0) }
            )
            switch decision {
            case .optimise: plain.append(file)
            case let .pipeline(name, _): model.runPipeline(name, onWatched: file)
            case .skip: continue
            }
        }
        if !plain.isEmpty { model.optimise(plain, origin: .watchedFolder) }
    }

    static func tooManyTitle(_ kind: MediaKind, count: Int) -> String {
        switch kind {
        case .image: return Strings.format("More than %d new images at once", count)
        case .video: return count == 1 ? Strings.text("More than one new video at once") : Strings.format("More than %d new videos at once", count)
        case .pdf: return Strings.format("More than %d new PDFs at once", count)
        case .audio: return Strings.format("More than %d new audio files at once", count)
        }
    }

    nonisolated static func size(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }
}
