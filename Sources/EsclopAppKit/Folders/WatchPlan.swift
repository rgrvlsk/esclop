// SPDX-License-Identifier: GPL-3.0-or-later
//
// Which folders to watch and what a new file in one of them gets, from the settings and the
// saved pipelines (no second list): the four folder lists of the kinds switched on, plus every
// pipeline's `folder(...)` trigger. A file in a pipeline's folder runs that pipeline; any other
// file in a watched folder is optimised the usual way. Plain values, so the rules are tested
// without a file system.
//
// What counts as a new file follows Clop 3.5: not hidden, a kind L'Esclop handles, not already
// optimised (the `dev.esclop.optimised` mark), not one L'Esclop wrote in the last three seconds,
// within the per-kind size limits, and not part of a burst larger than the per-kind count.

import EsclopCore
import EsclopPipelines
import Foundation

/// One watched folder and what it is watched for.
public struct WatchTarget: Equatable, Sendable {
    /// The folder, `~` expanded and symlinks resolved.
    public var folder: URL
    /// The kinds the folder lists ask for.
    public var kinds: Set<MediaKind>
    /// A pipeline with a `folder(...)` trigger for this folder: it runs instead of the plain
    /// optimisation, for every kind it has steps for.
    public var pipeline: String?
    /// The kinds the pipeline handles.
    public var pipelineKinds: Set<MediaKind>

    public init(folder: URL, kinds: Set<MediaKind> = [], pipeline: String? = nil, pipelineKinds: Set<MediaKind> = []) {
        self.folder = folder
        self.kinds = kinds
        self.pipeline = pipeline
        self.pipelineKinds = pipelineKinds
    }
}

/// What a new file in a watched folder gets.
public enum WatchDecision: Equatable, Sendable {
    case optimise(MediaKind)
    case pipeline(String, MediaKind)
    case skip(WatchSkip)

    public var kind: MediaKind? {
        switch self {
        case let .optimise(kind), let .pipeline(_, kind): return kind
        case .skip: return nil
        }
    }
}

public enum WatchSkip: Equatable, Sendable {
    case hidden, unsupported, notWatched, alreadyOptimised, justWritten, tooSmall, tooLarge, empty, insideBackups
}

public enum WatchPlan {
    /// The folder as the watcher compares it: `~` expanded, standardised, symlinks resolved.
    public static func canonical(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
    }

    static let lists: [(MediaKind, Setting<Bool>, Setting<[String]>)] = [
        (.image, EsclopSettings.enableAutomaticImageOptimisations, EsclopSettings.imageDirs),
        (.video, EsclopSettings.enableAutomaticVideoOptimisations, EsclopSettings.videoDirs),
        (.pdf, EsclopSettings.enableAutomaticPDFOptimisations, EsclopSettings.pdfDirs),
        (.audio, EsclopSettings.enableAutomaticAudioOptimisations, EsclopSettings.audioDirs),
    ]

    /// Every folder to watch, from the settings and the pipelines' folder triggers.
    public static func targets(settings: SettingsStore, pipelines: [Pipeline]) -> [WatchTarget] {
        var byFolder: [URL: WatchTarget] = [:]
        var order: [URL] = []
        func target(_ folder: URL) -> WatchTarget {
            if byFolder[folder] == nil {
                byFolder[folder] = WatchTarget(folder: folder)
                order.append(folder)
            }
            return byFolder[folder]!
        }
        for (kind, enabled, list) in lists where enabled.value(in: settings) {
            for path in list.value(in: settings) {
                let folder = canonical(path)
                var entry = target(folder)
                entry.kinds.insert(kind)
                byFolder[folder] = entry
            }
        }
        // Pipelines in name order, so the same folder always picks the same one.
        for pipeline in pipelines.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            for case let .folder(path) in pipeline.triggers {
                let folder = canonical(path)
                var entry = target(folder)
                guard entry.pipeline == nil else { continue }
                entry.pipeline = pipeline.name
                entry.pipelineKinds = Set(MediaKind.allCases.filter { !pipeline.steps(for: $0).isEmpty })
                byFolder[folder] = entry
            }
        }
        return order.compactMap { byFolder[$0] }
    }

    /// What a file gets, from cheap facts about it. `size` and `isMarked` are read by the caller.
    public static func decide(
        _ file: URL, targets: [WatchTarget], size: Int, isMarked: Bool, justWritten: Bool,
        limits: (MediaKind) -> (min: Int, max: Int)
    ) -> WatchDecision {
        let name = file.lastPathComponent
        if name.hasPrefix(".") || name.hasPrefix("~$") || name.hasSuffix(".download") || name.hasSuffix(".crdownload") || name.hasSuffix(".part") {
            return .skip(.hidden)
        }
        guard let kind = MediaKind.of(file) else { return .skip(.unsupported) }
        let path = file.standardizedFileURL.resolvingSymlinksInPath()
        if path.path.hasPrefix(Paths.backups.standardizedFileURL.resolvingSymlinksInPath().path + "/") { return .skip(.insideBackups) }
        // Only files directly in a watched folder, as Clop does: subfolders are often where
        // results and exports go.
        guard let target = targets.first(where: { $0.folder.path == path.deletingLastPathComponent().path }) else {
            return .skip(.notWatched)
        }
        let byPipeline = target.pipeline != nil && target.pipelineKinds.contains(kind)
        guard byPipeline || target.kinds.contains(kind) else { return .skip(.notWatched) }
        if justWritten { return .skip(.justWritten) }
        if isMarked { return .skip(.alreadyOptimised) }
        if size <= 0 { return .skip(.empty) }
        let limit = limits(kind)
        if !byPipeline {
            if size < limit.min { return .skip(.tooSmall) }
            if size > limit.max { return .skip(.tooLarge) }
        }
        if let pipeline = target.pipeline, byPipeline { return .pipeline(pipeline, kind) }
        return .optimise(kind)
    }

    /// The most new files of a kind that may appear together (Clop's counts).
    public static func countLimit(_ kind: MediaKind, settings: SettingsStore) -> Int {
        switch kind {
        case .image: return EsclopSettings.maxImageFileCount.value(in: settings)
        case .video: return EsclopSettings.maxVideoFileCount.value(in: settings)
        case .pdf: return EsclopSettings.maxPDFFileCount.value(in: settings)
        case .audio: return EsclopSettings.maxAudioFileCount.value(in: settings)
        }
    }
}

/// Files of one kind that appeared close together. Clop leaves a whole burst alone when it is
/// larger than the kind's count: dozens of images at once are a copy or an unzip, not new
/// screenshots.
public struct Burst: Equatable, Sendable {
    public var kind: MediaKind
    public var files: [URL]
    public var limit: Int

    public var isTooLarge: Bool { files.count > limit }
}
