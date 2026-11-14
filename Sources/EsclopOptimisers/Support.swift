// SPDX-License-Identifier: GPL-3.0-or-later
//
// What every kind engine shares: the environment (settings, tools, backups, the image engine
// client), the resolved plan for one file, the produced temporary file, and placing that file
// where the request says (backup, extended attribute, dates, "already smaller").

import EsclopCore
import Foundation
import UniformTypeIdentifiers

struct EngineEnvironment: Sendable {
    let settings: SettingsStore
    let tools: ToolLocator
    let backups: BackupStore
    let images: EngineClient
    let workRoot: URL

    func value<V>(_ setting: Setting<V>) -> V { setting.value(in: settings) }
}

/// Which public entry point started the work; decides whether a larger result is acceptable.
enum Operation: String, Sendable {
    case optimise, convert, downscale, crop, fit, strip
}

/// A request resolved against the settings for one source file.
struct Plan: Sendable {
    var operation: Operation
    var request: OptimisationRequest
    /// Explicit target format (from the request or the operation).
    var format: OutputFormat?
    var downscale: Double?
    var crop: CropSize?
    var strip: Bool
    var keepHDR: Bool
    /// Applies the "convert automatically" format lists (clipboard, folders, drop zone).
    var automatic: Bool
    /// Speed changes: keep every frame (true) or keep the frame rate (false). nil follows the setting.
    var keepFrames: Bool?
    var watermark: Watermark?

    init(operation: Operation, request: OptimisationRequest, env: EngineEnvironment) {
        self.operation = operation
        self.request = request
        format = request.format
        downscale = request.downscale.flatMap { $0 > 0 && $0 < 1 ? $0 : nil }
        crop = request.crop
        let setting = env.value(EsclopSettings.stripMetadata)
        // An agent may ask for more stripping, never less: false from MCP keeps the setting.
        strip = request.origin == .mcp ? (request.stripMetadata == true || setting) : request.stripMetadata ?? setting
        keepHDR = request.keepHDR ?? env.value(EsclopSettings.keepHDR)
        automatic = [.app, .clipboard, .dropZone, .watchedFolder, .hotkey].contains(request.origin)
    }

    var isAggressive: Bool { request.quality.tier == .aggressive }

    /// Pure compression may not grow the file; a conversion or crop is the person's intent.
    func allowsLarger(formatChanged: Bool) -> Bool {
        if formatChanged || crop != nil { return true }
        return false
    }

    /// The compression factor for `kind`: custom tiers carry their own, normal and aggressive
    /// come from the settings (with the per-format "always aggressive" switches).
    func factor(for kind: MediaKind, format: OutputFormat?, env: EngineEnvironment) -> Int {
        switch request.quality.tier {
        case .custom:
            return request.quality.factor
        case .aggressive:
            return aggressiveFactor(kind, env)
        case .normal:
            let always: Bool
            switch format {
            case .jpeg?: always = env.value(EsclopSettings.useAggressiveOptimisationJPEG)
            case .png?: always = env.value(EsclopSettings.useAggressiveOptimisationPNG)
            case .gif?: always = env.value(EsclopSettings.useAggressiveOptimisationGIF)
            case .pdf?: always = env.value(EsclopSettings.useAggressiveOptimisationPDF)
            default: always = kind == .video && env.value(EsclopSettings.useAggressiveOptimisationMP4)
            }
            if always { return aggressiveFactor(kind, env) }
            switch kind {
            case .image: return env.value(EsclopSettings.imageCompression)
            case .video: return env.value(EsclopSettings.videoCompression)
            case .audio: return env.value(EsclopSettings.audioCompression)
            case .pdf: return env.value(EsclopSettings.imageCompression)
            }
        }
    }

    private func aggressiveFactor(_ kind: MediaKind, _ env: EngineEnvironment) -> Int {
        switch kind {
        case .image, .pdf: return env.value(EsclopSettings.imageAggressiveCompression)
        case .video: return env.value(EsclopSettings.videoAggressiveCompression)
        case .audio: return env.value(EsclopSettings.audioAggressiveCompression)
        }
    }
}

/// An image laid over a picture or video.
struct Watermark: Sendable {
    var image: URL
    var position: WatermarkCorner
    /// 0...1
    var opacity: Double
    /// Watermark width as a fraction of the picture's width.
    var scale: Double
}

/// A finished file in the work folder, waiting to be placed.
struct Produced: Sendable {
    var url: URL
    var width: Int?
    var height: Int?
    var duration: TimeInterval?
    var steps: [String]
    /// Format or geometry changed, so a larger file is still a valid answer.
    var allowLarger: Bool
}

/// A scratch folder for one operation, removed when done.
struct WorkFolder: Sendable {
    let url: URL

    init(root: URL) throws {
        url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try Paths.ensure(url)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    func file(stem: String, ext: String) -> URL {
        url.appendingPathComponent(stem).appendingPathExtension(ext)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

func fileSize(_ url: URL) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
}

func fileExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

/// Reports progress for one source.
struct ProgressSink: Sendable {
    let requestID: UUID
    let source: URL
    let report: @Sendable (OptimisationProgress) -> Void

    func callAsFunction(_ fraction: Double, _ message: String? = nil) {
        report(OptimisationProgress(requestID: requestID, source: source, fraction: fraction, message: message))
    }

    /// A sink mapping 0...1 onto `range` of this one, for multi-step work.
    func scaled(_ range: ClosedRange<Double>) -> ProgressSink {
        ProgressSink(requestID: requestID, source: source) { progress in
            var mapped = progress
            if progress.fraction >= 0 {
                mapped.fraction = range.lowerBound + progress.fraction * (range.upperBound - range.lowerBound)
            }
            report(mapped)
        }
    }

    static let none = ProgressSink(requestID: UUID(), source: URL(fileURLWithPath: "/")) { _ in }
}

// MARK: - Placing results

enum ResultWriter {
    /// Moves `produced` where the request says and returns the result. Backs up the original
    /// before anything overwrites it, marks the output, copies the original's dates.
    static func place(
        _ produced: Produced, source: URL, kind: MediaKind, request: OptimisationRequest,
        started: Date, env: EngineEnvironment
    ) throws -> OptimisationResult {
        let fm = FileManager.default
        let bytesBefore = fileSize(source)
        let bytesAfter = fileSize(produced.url)
        guard bytesAfter > 0 else {
            throw EsclopError.other("The optimiser produced an empty file for \(source.lastPathComponent)")
        }
        if !produced.allowLarger, bytesAfter >= bytesBefore {
            throw EsclopError.alreadySmaller
        }

        // Same format, same extension: photo.jpg stays photo.jpg, not photo.jpeg.
        var ext = produced.url.pathExtension.isEmpty ? source.pathExtension : produced.url.pathExtension
        if let producedType = UTType(filenameExtension: ext.lowercased()),
           producedType == UTType(filenameExtension: source.pathExtension.lowercased())
        {
            ext = source.pathExtension
        }
        let destination = request.location.destination(
            for: source, extension: ext,
            sameFolderTemplate: env.value(EsclopSettings.sameFolderNameTemplate),
            temporaryRoot: Paths.temporary
        )
        let sourcePath = source.standardizedFileURL.path
        let replacesSource = destination.standardizedFileURL.path == sourcePath
        // A template can resolve to the source itself; that is an in-place write too.
        let inPlace = request.location == .inPlace || replacesSource
        if inPlace, request.origin == .mcp, !env.value(EsclopSettings.allowOverwriteOriginals) {
            throw EsclopError.notPermitted(Self.agentOverwriteMessage)
        }

        var backup: BackupEntry?
        if inPlace {
            backup = try env.backups.backUp(source, requestID: request.id)
        }
        if !replacesSource, fm.fileExists(atPath: destination.path) {
            // Whatever is about to be overwritten (a sibling with the new extension, a file a
            // template names) is kept too. No backup, no overwrite.
            try env.backups.backUp(destination, requestID: request.id)
        }

        if env.value(EsclopSettings.preserveDates) {
            copyDates(from: source, to: produced.url)
        }

        // Stage next to the destination so the final swap stays on one volume.
        let folder = destination.deletingLastPathComponent()
        try Paths.ensure(folder)
        let staging = folder.appendingPathComponent(".\(destination.lastPathComponent).esclop-\(UUID().uuidString.prefix(8))")
        try fm.moveItem(at: produced.url, to: staging)
        do {
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }

        // In place with a new extension: the converted file replaces the original.
        if request.location == .inPlace, !replacesSource, fm.fileExists(atPath: sourcePath) {
            try fm.removeItem(at: source)
        }

        try? OptimisedMark.set(destination, note: markNote())
        if let entry = backup {
            backup = try? env.backups.setOutput(destination, for: entry)
            BackupPruner.pruneIfDue(env)
        }

        let finished = Date()
        Log.engine.info("\(source.lastPathComponent, privacy: .private): \(bytesBefore) -> \(bytesAfter) bytes in \(String(format: "%.2f", finished.timeIntervalSince(started))) s")
        return OptimisationResult(
            id: request.id, source: source, output: destination, backup: backup?.backup,
            kind: MediaKind.of(destination) ?? kind, bytesBefore: bytesBefore, bytesAfter: bytesAfter,
            width: produced.width, height: produced.height, duration: produced.duration,
            startedAt: started, finishedAt: finished, steps: produced.steps
        )
    }

    static let agentOverwriteMessage =
        "agents may not overwrite originals. Choose another output location, or allow it in Settings → Agents and MCP (esclop://settings/agents/allowOverwriteOriginals)"

    static func markNote() -> String {
        let date = ISO8601DateFormatter().string(from: Date())
        return #"{"by":"esclop","at":"\#(date)"}"#
    }

    static func copyDates(from source: URL, to target: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.path) else { return }
        var dates: [FileAttributeKey: Any] = [:]
        if let created = attributes[.creationDate] { dates[.creationDate] = created }
        if let modified = attributes[.modificationDate] { dates[.modificationDate] = modified }
        try? FileManager.default.setAttributes(dates, ofItemAtPath: target.path)
    }
}

/// Applies `backupRetentionDays` at most once an hour per process, after a new backup.
enum BackupPruner {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var last: [String: Date] = [:]

    static func pruneIfDue(_ env: EngineEnvironment) {
        let days = env.value(EsclopSettings.backupRetentionDays)
        guard days > 0 else { return }
        let key = env.backups.root.path
        lock.lock()
        let due = last[key].map { Date().timeIntervalSince($0) > 3600 } ?? true
        if due { last[key] = Date() }
        lock.unlock()
        guard due else { return }
        let backups = env.backups
        DispatchQueue.global(qos: .utility).async {
            let removed = backups.prune(olderThan: days)
            if removed > 0 { Log.backups.info("Pruned \(removed) backups older than \(days) days") }
        }
    }
}

// MARK: - Formats

extension OutputFormat {
    /// The format of an existing file, from its type identifier.
    static func of(type: UTType) -> OutputFormat? {
        let table: [(UTType, OutputFormat)] = [
            (.png, .png), (.jpeg, .jpeg), (.gif, .gif), (.webP, .webp), (.heic, .heic), (.heif, .heic),
            (.tiff, .tiff), (.bmp, .bmp), (.pdf, .pdf), (.mpeg4Movie, .mp4), (.quickTimeMovie, .mov),
            (.mp3, .mp3), (.wav, .wav), (.mpeg4Audio, .m4a),
        ]
        for (candidate, format) in table where type.conforms(to: candidate) { return format }
        switch type.identifier {
        case "public.avif", "public.avis": return .avif
        case "public.jpeg-xl": return .jxl
        case "org.webmproject.webm": return .webm
        case "org.matroska.mkv": return .mkv
        case "org.xiph.flac": return .flac
        case "org.xiph.ogg-audio", "org.xiph.opus": return .opus
        case "com.apple.m4a-audio": return .m4a
        default: return nil
        }
    }

    static func of(url: URL) -> OutputFormat? {
        UTType(filenameExtension: url.pathExtension.lowercased()).flatMap { of(type: $0) }
            ?? OutputFormat(name: url.pathExtension)
    }
}
