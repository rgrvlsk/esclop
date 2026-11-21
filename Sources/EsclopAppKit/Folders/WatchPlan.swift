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
// within the per-kind size limits, and not part of a burst larger than the per-kind count. Each
// folder can also skip formats and pixel sizes (`watchedFolderRules`) and names its
// `.esclopignore` or `.clopignore` file matches.

import EsclopCore
import EsclopPipelines
import Foundation
import UniformTypeIdentifiers

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
    /// What the folder leaves alone besides the size limits.
    public var rules: FolderRules?

    public init(folder: URL, kinds: Set<MediaKind> = [], pipeline: String? = nil, pipelineKinds: Set<MediaKind> = [], rules: FolderRules? = nil) {
        self.folder = folder
        self.kinds = kinds
        self.pipeline = pipeline
        self.pipelineKinds = pipelineKinds
        self.rules = rules
    }
}

/// One folder's entry in `watchedFolderRules`: formats to skip and, for images and videos, the
/// longer side's smallest and largest size in pixels.
public struct FolderRules: Codable, Equatable, Sendable {
    /// As the folder lists write it (`~/Desktop`).
    public var folder: String
    /// Extensions, without the dot.
    public var skipFormats: [String]?
    public var minPixels: Int?
    public var maxPixels: Int?

    public init(folder: String, skipFormats: [String]? = nil, minPixels: Int? = nil, maxPixels: Int? = nil) {
        self.folder = folder
        self.skipFormats = skipFormats
        self.minPixels = minPixels
        self.maxPixels = maxPixels
    }

    /// Nothing to skip: the entry can go.
    public var isEmpty: Bool { (skipFormats ?? []).isEmpty && minPixels == nil && maxPixels == nil }

    /// By type, so `jpg` skips `.jpeg` too and `tif` skips `.tiff`.
    public func skips(_ file: URL) -> Bool {
        let format = file.pathExtension.lowercased()
        let type = UTType(filenameExtension: format)
        return (skipFormats ?? []).contains { skip in
            let skip = skip.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return skip == format || (type != nil && UTType(filenameExtension: skip) == type)
        }
    }

    /// Outside the pixel limits, by the longer side. Unknown sizes pass.
    public func skip(longerSide: Int?) -> WatchSkip? {
        guard let longerSide else { return nil }
        if let minPixels, longerSide < minPixels { return .tooFewPixels }
        if let maxPixels, longerSide > maxPixels { return .tooManyPixels }
        return nil
    }

    /// The entries of `watchedFolderRules`; one that does not parse is left out.
    public static func all(in settings: SettingsStore) -> [FolderRules] {
        EsclopSettings.watchedFolderRules.value(in: settings).compactMap { try? JSONDecoder().decode(FolderRules.self, from: Data($0.utf8)) }
    }

    /// The setting's list with `rules` in place of the folder's entry (none when it is empty).
    public static func replacing(_ rules: FolderRules, in list: [String]) -> [String] {
        let folder = WatchPlan.canonical(rules.folder)
        var kept = list.filter { entry in
            guard let other = try? JSONDecoder().decode(FolderRules.self, from: Data(entry.utf8)) else { return true }
            return WatchPlan.canonical(other.folder) != folder
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if !rules.isEmpty, let data = try? encoder.encode(rules) { kept.append(String(decoding: data, as: UTF8.self)) }
        return kept
    }
}

/// A watched folder's `.esclopignore`, or Clop's `.clopignore`, and for one kind of file
/// `.esclopignore-image` (or `-video`, `-pdf`, `-audio`) and Clop 3.5's `.clopignore-image` and
/// so on: gitignore-style patterns for names to leave alone, one per line. `#` starts a comment, `!` takes a name back, the last
/// pattern that matches wins, and case does not matter, as on a Mac disk. Only files directly in
/// the folder are watched, so a pattern matches the name; a leading `/` is allowed.
public enum IgnoreFile {
    public static let names = [".esclopignore", ".clopignore"]

    /// The patterns of the files in `folder` that apply to `kind`, in order: the files for every
    /// kind first. Read at each new file: they are small.
    public static func patterns(in folder: URL, for kind: MediaKind? = nil) -> [String] {
        (names + (kind.map { kind in names.map { "\($0)-\(kind.rawValue)" } } ?? [])).flatMap { name -> [String] in
            guard let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else { return [] }
            return text.components(separatedBy: .newlines)
        }
    }

    public static func ignores(_ name: String, patterns: [String]) -> Bool {
        var ignored = false
        for line in patterns {
            var pattern = line.trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty, !pattern.hasPrefix("#"), !pattern.hasSuffix("/") else { continue }
            let negated = pattern.hasPrefix("!")
            if negated { pattern.removeFirst() }
            if pattern.hasPrefix("\\") { pattern.removeFirst() }
            // `**/x` and `/x` both mean x in the folder itself.
            while pattern.hasPrefix("**/") { pattern.removeFirst(3) }
            if pattern.hasPrefix("/") { pattern.removeFirst() }
            if fnmatch(pattern, name, FNM_CASEFOLD) == 0 { ignored = !negated }
        }
        return ignored
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
    /// The folder's rules or ignore file leave it alone.
    case skippedFormat, ignored, tooFewPixels, tooManyPixels
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
        let rules = FolderRules.all(in: settings)
        return order.compactMap { folder in
            byFolder[folder].map { target in
                var target = target
                target.rules = rules.first { canonical($0.folder) == folder }
                return target
            }
        }
    }

    /// What a file gets, from cheap facts about it. `size`, `isMarked` and `ignored` (the
    /// folder's ignore file matches it) are read by the caller.
    public static func decide(
        _ file: URL, targets: [WatchTarget], size: Int, isMarked: Bool, justWritten: Bool, ignored: Bool = false,
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
        if ignored { return .skip(.ignored) }
        if target.rules?.skips(file) == true { return .skip(.skippedFormat) }
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
