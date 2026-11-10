// SPDX-License-Identifier: GPL-3.0-or-later
//
// The contract every module builds against. Optimisers implement `OptimisationEngine`;
// pipelines, the CLI, the MCP server and the app consume it. Keep this file small and stable:
// adding cases or fields is compatible; renaming them requires updating every consumer.

import Foundation
import UniformTypeIdentifiers

// MARK: - Media kinds and formats

public enum MediaKind: String, Codable, CaseIterable, Sendable {
    case image, video, pdf, audio

    public static func of(_ url: URL) -> MediaKind? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        return of(type)
    }

    public static func of(_ type: UTType) -> MediaKind? {
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return nil
    }
}

/// Formats esclop can write. Raw values are the file extensions used on disk.
public enum OutputFormat: String, Codable, CaseIterable, Sendable {
    // images
    case jpeg, png, webp, avif, heic, jxl, gif, tiff, bmp
    // video
    case mp4, mov, webm, mkv, hevc, av1, gifVideo = "gif-video"
    // audio
    case mp3, aac, m4a, flac, wav, opus
    // documents
    case pdf

    public var kind: MediaKind {
        switch self {
        case .jpeg, .png, .webp, .avif, .heic, .jxl, .gif, .tiff, .bmp: return .image
        case .mp4, .mov, .webm, .mkv, .hevc, .av1, .gifVideo: return .video
        case .mp3, .aac, .m4a, .flac, .wav, .opus: return .audio
        case .pdf: return .pdf
        }
    }

    /// The extension written on disk. Codec-named cases live in a container: `hevc` and `av1` in
    /// MP4, `aac` in M4A, and `gifVideo` (a video turned into an animated GIF) in GIF.
    public var fileExtension: String {
        switch self {
        case .hevc, .av1: return "mp4"
        case .aac: return "m4a"
        case .gifVideo: return "gif"
        default: return rawValue
        }
    }

    public var utType: UTType? { UTType(filenameExtension: fileExtension) }

    /// Accepts raw values and common aliases (`jpg`, `tif`, `h265`, `x265`, `ogg`, `aif`...).
    public init?(name: String) {
        let lowered = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if let format = OutputFormat(rawValue: lowered) {
            self = format
            return
        }
        switch lowered {
        case "jpg", "jpe": self = .jpeg
        case "tif": self = .tiff
        case "heif": self = .heic
        case "h265", "x265", "hvc1": self = .hevc
        case "m4v", "h264", "avc": self = .mp4
        case "qt": self = .mov
        case "ogg", "oga": self = .opus
        case "wave": self = .wav
        case "gifvideo": self = .gifVideo
        default: return nil
        }
    }
}

// MARK: - Quality

/// How hard to compress. `normal` keeps changes visually lossless; `aggressive` trades visible
/// quality for size. `factor` is 0...100 where higher means smaller files, mirroring the slider.
public struct CompressionQuality: Codable, Hashable, Sendable {
    public enum Tier: String, Codable, CaseIterable, Sendable { case normal, aggressive, custom }

    public var tier: Tier
    public var factor: Int

    public init(tier: Tier, factor: Int) {
        self.tier = tier
        self.factor = max(0, min(100, factor))
    }

    public static let normal = CompressionQuality(tier: .normal, factor: 30)
    public static let aggressive = CompressionQuality(tier: .aggressive, factor: 64)
}

public enum VideoEncoder: String, Codable, CaseIterable, Sendable {
    case h264Software = "libx264"
    case h264VideoToolbox = "h264_videotoolbox"
    case hevcVideoToolbox = "hevc_videotoolbox"
    case hevcSoftware = "libx265"
    case av1 = "libsvtav1"
    case vp9 = "libvpx-vp9"
}

// MARK: - Geometry

public struct CropSize: Codable, Hashable, Sendable {
    public var width: Int?
    public var height: Int?
    public var longEdge: Int?
    /// "16:9", "1:1", "4:5"...
    public var aspectRatio: String?
    public var smart: Bool
    /// A free crop: the region to keep, in pixels of the upright image. `width`, `height` or
    /// `longEdge` then scale that region; `aspectRatio` and `smart` are ignored.
    public var rect: CropRect?

    public init(
        width: Int? = nil, height: Int? = nil, longEdge: Int? = nil, aspectRatio: String? = nil, smart: Bool = false,
        rect: CropRect? = nil
    ) {
        self.width = width
        self.height = height
        self.longEdge = longEdge
        self.aspectRatio = aspectRatio
        self.smart = smart
        self.rect = rect
    }
}

/// A region of an image in pixels, origin at the top left.
public struct CropRect: Codable, Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// MARK: - Where the result goes

/// Pipelines and the CLI say where output lands. Templates accept `%f` (file name without
/// extension), `%e` (extension), `%d` (source directory) and `~`.
public enum OutputLocation: Codable, Hashable, Sendable {
    case inPlace          // overwrite, keeping a backup
    case sameFolder       // next to the source with a suffix
    case temporary        // esclop's temp folder
    case path(String)     // template or folder
}

// MARK: - Requests and results

/// Where a request came from. The app decides what each origin may do (an agent, for example,
/// never deletes originals without the setting that allows it).
public enum RequestOrigin: String, Codable, Sendable {
    case app, clipboard, dropZone, watchedFolder, hotkey, finder, cli, mcp, shortcuts
}

public struct OptimisationRequest: Codable, Identifiable, Sendable {
    public var id: UUID
    public var sources: [URL]
    public var origin: RequestOrigin
    public var quality: CompressionQuality
    public var format: OutputFormat?
    public var downscale: Double?          // 0.1...1.0
    public var crop: CropSize?
    public var targetBytes: Int?           // "fit under size"
    public var stripMetadata: Bool
    public var removeAudio: Bool
    public var playbackSpeed: Double?
    public var videoEncoder: VideoEncoder?
    public var pdfDPI: Int?
    public var location: OutputLocation
    public var pipeline: String?           // pipeline name; when set, the other fields are ignored
    public var showResultUI: Bool
    /// Frame rate ceiling for videos; frames above it are dropped. nil follows the settings.
    public var fpsCap: Double?
    /// Target video bitrate in kbit/s ("lower bitrate"). nil lets the quality decide.
    public var videoBitrateKbps: Int?
    /// Target audio bitrate in kbit/s for audio files and video soundtracks.
    public var audioBitrateKbps: Int?
    /// Loudness normalisation target in LUFS (for example -16). nil leaves loudness alone.
    public var loudnessLUFS: Double?
    /// Keep HDR (gain maps, PQ/HLG video) when the output format can carry it. nil follows the settings.
    public var keepHDR: Bool?

    public init(
        id: UUID = UUID(), sources: [URL], origin: RequestOrigin, quality: CompressionQuality = .normal,
        format: OutputFormat? = nil, downscale: Double? = nil, crop: CropSize? = nil, targetBytes: Int? = nil,
        stripMetadata: Bool = false, removeAudio: Bool = false, playbackSpeed: Double? = nil,
        videoEncoder: VideoEncoder? = nil, pdfDPI: Int? = nil, location: OutputLocation = .inPlace,
        pipeline: String? = nil, showResultUI: Bool = true,
        fpsCap: Double? = nil, videoBitrateKbps: Int? = nil, audioBitrateKbps: Int? = nil,
        loudnessLUFS: Double? = nil, keepHDR: Bool? = nil
    ) {
        self.fpsCap = fpsCap
        self.videoBitrateKbps = videoBitrateKbps
        self.audioBitrateKbps = audioBitrateKbps
        self.loudnessLUFS = loudnessLUFS
        self.keepHDR = keepHDR
        self.id = id
        self.sources = sources
        self.origin = origin
        self.quality = quality
        self.format = format
        self.downscale = downscale
        self.crop = crop
        self.targetBytes = targetBytes
        self.stripMetadata = stripMetadata
        self.removeAudio = removeAudio
        self.playbackSpeed = playbackSpeed
        self.videoEncoder = videoEncoder
        self.pdfDPI = pdfDPI
        self.location = location
        self.pipeline = pipeline
        self.showResultUI = showResultUI
    }
}

public struct OptimisationResult: Codable, Identifiable, Sendable {
    public var id: UUID
    public var source: URL
    public var output: URL
    public var backup: URL?
    public var kind: MediaKind
    public var bytesBefore: Int
    public var bytesAfter: Int
    public var width: Int?
    public var height: Int?
    public var duration: TimeInterval?
    public var startedAt: Date
    public var finishedAt: Date
    public var steps: [String]             // human-readable log of what was applied

    public init(
        id: UUID = UUID(), source: URL, output: URL, backup: URL? = nil, kind: MediaKind,
        bytesBefore: Int, bytesAfter: Int, width: Int? = nil, height: Int? = nil, duration: TimeInterval? = nil,
        startedAt: Date, finishedAt: Date, steps: [String] = []
    ) {
        self.id = id
        self.source = source
        self.output = output
        self.backup = backup
        self.kind = kind
        self.bytesBefore = bytesBefore
        self.bytesAfter = bytesAfter
        self.width = width
        self.height = height
        self.duration = duration
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.steps = steps
    }

    public var savedBytes: Int { bytesBefore - bytesAfter }
    public var savedFraction: Double { bytesBefore > 0 ? Double(savedBytes) / Double(bytesBefore) : 0 }
}

// MARK: - Errors

public enum EsclopError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    case unsupportedFile(String)
    case fileNotFound(String)
    case toolMissing(String)
    case toolFailed(tool: String, exitCode: Int32, stderr: String)
    case alreadySmaller
    case cancelled
    case notPermitted(String)
    case invalidPipeline(String)
    case invalidArgument(String)
    case appNotRunning
    /// A file of a kind L'Esclop handles that cannot be read: damaged, cut short or mislabelled.
    /// The tool's own output goes to the log, not into this message.
    case unreadable(kind: MediaKind)
    case other(String)

    /// "This file isn’t a video L'Esclop can read. It may be damaged."
    public static func unreadableMessage(_ kind: MediaKind) -> String {
        switch kind {
        case .image: return "This file isn’t an image L’Esclop can read. It may be damaged."
        case .video: return "This file isn’t a video L’Esclop can read. It may be damaged."
        case .pdf: return "This file isn’t a PDF L’Esclop can read. It may be damaged."
        case .audio: return "This file isn’t audio L’Esclop can read. It may be damaged."
        }
    }

    public var description: String {
        switch self {
        case let .unsupportedFile(p): return "Unsupported file: \(p)"
        case let .fileNotFound(p): return "File not found: \(p)"
        case let .toolMissing(t): return "Missing tool: \(t)"
        case let .toolFailed(tool, code, stderr): return "\(tool) failed (\(code)): \(stderr)"
        case .alreadySmaller: return "The file is already as small as it gets"
        case .cancelled: return "Cancelled"
        case let .notPermitted(why): return "Not permitted: \(why)"
        case let .invalidPipeline(why): return "Invalid pipeline: \(why)"
        case let .invalidArgument(why): return "Invalid argument: \(why)"
        case .appNotRunning: return "The esclop app is not running"
        case let .unreadable(kind): return Self.unreadableMessage(kind)
        case let .other(msg): return msg
        }
    }
}

// MARK: - Progress

public struct OptimisationProgress: Codable, Sendable {
    public var requestID: UUID
    public var source: URL
    public var fraction: Double        // 0...1, or -1 when indeterminate
    public var message: String?

    public init(requestID: UUID, source: URL, fraction: Double, message: String? = nil) {
        self.requestID = requestID
        self.source = source
        self.fraction = fraction
        self.message = message
    }
}

// MARK: - Engine

/// What an optimiser does with one file. Implementations live in EsclopOptimisers.
/// Every method writes its result where `request.location` says and returns the outcome;
/// it never deletes the source unless the location is `.inPlace`, and then it keeps a backup.
public protocol OptimisationEngine: Sendable {
    func optimise(_ source: URL, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult
    func convert(_ source: URL, to format: OutputFormat, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult
    func downscale(_ source: URL, factor: Double, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult
    func crop(_ source: URL, to size: CropSize, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult
    func fit(_ source: URL, underBytes: Int, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult
    func stripMetadata(_ source: URL, request: OptimisationRequest) async throws -> OptimisationResult
    func supports(_ url: URL) -> Bool
}
