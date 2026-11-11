// SPDX-License-Identifier: GPL-3.0-or-later
//
// The steps a pipeline can run. The vocabulary, argument names and defaults follow Clop's
// pipeline language so pipelines written for Clop run unchanged; see docs/pipelines.md.

import EsclopCore
import Foundation

// MARK: - Argument types

/// The `encoder` argument of `optimise`. Images, PDFs and audio use the first three; video uses
/// the last three (Clop's names for its encoder presets).
public enum EncoderPreset: String, Codable, CaseIterable, Hashable, Sendable {
    case medium, aggressive, lossless
    case fast, slowHighQuality, visuallyLossless

    public var isVideo: Bool { self == .fast || self == .slowHighQuality || self == .visuallyLossless }
}

/// The `compression` argument of `optimise`: `adaptive`, `auto` (follow the app's setting) or a
/// factor from 5 (best quality) to 100 (smallest file).
public enum CompressionSetting: Hashable, Codable, Sendable {
    case adaptive
    case auto
    case factor(Int)

    public static let factorRange = 5 ... 100

    public init?(text: String) {
        switch text.lowercased() {
        case "adaptive": self = .adaptive
        case "auto": self = .auto
        default:
            guard let n = Int(text), Self.factorRange.contains(n) else { return nil }
            self = .factor(n)
        }
    }

    public var text: String {
        switch self {
        case .adaptive: "adaptive"
        case .auto: "auto"
        case let .factor(n): String(n)
        }
    }
}

/// What `copyToClipboard` puts on the clipboard.
public enum ClipboardFormat: String, Codable, CaseIterable, Hashable, Sendable {
    case path, imageData, markdown
}

/// What happens to video frames when `changeSpeed` speeds a video up.
public enum FrameBehaviour: String, Codable, CaseIterable, Hashable, Sendable {
    /// Every frame is kept, so the frame rate rises with the speed.
    case keep
    /// Frames are dropped back to the source frame rate, for a smaller file.
    case drop

    public init?(text: String) {
        switch text.lowercased() {
        case "keep", "keepframes": self = .keep
        case "drop", "dropframes": self = .drop
        default: return nil
        }
    }
}

public enum WatermarkPosition: String, Codable, CaseIterable, Hashable, Sendable {
    case bottomRight, bottomLeft, topRight, topLeft, center
}

public enum PageImageFormat: String, Codable, CaseIterable, Hashable, Sendable {
    case jpeg, png
}

/// Render scale for `extractPagesAsImages`: 1x (72 dpi), 2x (144 dpi), 3x (216 dpi).
public enum PageImageQuality: String, Codable, CaseIterable, Hashable, Sendable {
    case low, medium, high

    public var scale: Double {
        switch self {
        case .low: 1
        case .medium: 2
        case .high: 3
        }
    }
}

/// Apps a `shelveWith` step can hand files to.
public let shelfApps = ["yoink", "dockside", "dropover", "atoll"]
/// Apps an `uploadWith` step can hand files to.
public let uploadApps = ["dropshare"]

// MARK: - Filter conditions

/// The condition of an `if(...)` or `ifNot(...)` step. Every key that is set must hold (AND).
/// Keys and units follow Clop; `durationGreaterThan` and `durationLowerThan` are esclop additions.
public struct FilterCondition: Hashable, Codable, Sendable {
    /// Extensions or UTType identifiers, e.g. `["jpeg", "png"]` or `["image"]`.
    public var types: [String]?
    /// Matched against the file name. Smart case; capture groups become `$1`, `$2`...
    public var regex: String?
    public var nameContains: String?
    public var nameIs: String?
    public var fileSizeGreaterThan: Int?
    public var fileSizeLowerThan: Int?
    public var widthGreaterThan: Int?
    public var widthLowerThan: Int?
    public var heightGreaterThan: Int?
    public var heightLowerThan: Int?
    public var dpiGreaterThan: Int?
    public var dpiLowerThan: Int?
    public var minFileSize: Int?
    public var minResolution: Int?
    public var copiedBy: String?
    public var durationGreaterThan: Double?
    public var durationLowerThan: Double?

    public init(
        types: [String]? = nil, regex: String? = nil, nameContains: String? = nil, nameIs: String? = nil,
        fileSizeGreaterThan: Int? = nil, fileSizeLowerThan: Int? = nil,
        widthGreaterThan: Int? = nil, widthLowerThan: Int? = nil,
        heightGreaterThan: Int? = nil, heightLowerThan: Int? = nil,
        dpiGreaterThan: Int? = nil, dpiLowerThan: Int? = nil,
        minFileSize: Int? = nil, minResolution: Int? = nil, copiedBy: String? = nil,
        durationGreaterThan: Double? = nil, durationLowerThan: Double? = nil
    ) {
        self.types = types
        self.regex = regex
        self.nameContains = nameContains
        self.nameIs = nameIs
        self.fileSizeGreaterThan = fileSizeGreaterThan
        self.fileSizeLowerThan = fileSizeLowerThan
        self.widthGreaterThan = widthGreaterThan
        self.widthLowerThan = widthLowerThan
        self.heightGreaterThan = heightGreaterThan
        self.heightLowerThan = heightLowerThan
        self.dpiGreaterThan = dpiGreaterThan
        self.dpiLowerThan = dpiLowerThan
        self.minFileSize = minFileSize
        self.minResolution = minResolution
        self.copiedBy = copiedBy
        self.durationGreaterThan = durationGreaterThan
        self.durationLowerThan = durationLowerThan
    }

    public var isEmpty: Bool { self == FilterCondition() }
}

// MARK: - Steps

/// One step of a pipeline. Arguments and defaults mirror the text language: what you can write in
/// a `.pipeline` file is exactly what this enum can hold, and `PipelineSerializer` writes it back.
public enum PipelineStep: Hashable, Codable, Sendable {
    // Processing
    case optimise(encoder: EncoderPreset = .medium, adaptive: Bool = false, dpi: Int? = nil, location: OutputLocation = .inPlace, compression: CompressionSetting? = nil)
    case downscale(factor: Double, location: OutputLocation = .inPlace)
    case lowerBitrate(kbps: Int, location: OutputLocation = .inPlace)
    case convert(to: String, location: OutputLocation = .sameFolder)
    case crop(width: Int? = nil, height: Int? = nil, longEdge: Int? = nil, aspectRatio: String? = nil, smartCrop: Bool = false, location: OutputLocation = .inPlace)
    case extractPagesAsImages(format: PageImageFormat = .jpeg, quality: PageImageQuality = .medium, location: OutputLocation = .sameFolder)
    case targetSize(bytes: Int, location: OutputLocation = .inPlace)
    case stripExif
    case watermark(image: String, position: WatermarkPosition = .bottomRight, opacity: Double = 1.0, scale: Double = 0.15, location: OutputLocation = .inPlace)

    // File operations (templates allowed)
    case copy(to: String)
    case move(to: String)
    case rename(to: String)
    case delete(path: String)

    // Filters: the file stops here when the condition fails (no error)
    case filterIf(FilterCondition)
    case filterIfNot(FilterCondition)

    // Media-specific
    case removeAudio
    case changeSpeed(factor: Double, frames: FrameBehaviour? = nil)
    case capFps(fps: Int)
    case normalize(lufs: Double = -16)

    // Actions
    case runScript(path: String? = nil, code: String? = nil)
    case runShortcut(name: String)
    case copyToClipboard(format: ClipboardFormat = .path, relativeTo: String? = nil)
    case copyLinkForSending(expiration: TimeInterval? = nil)
    case fork(location: OutputLocation? = nil)
    case shelveWith(app: String)
    case uploadWith(app: String)
    /// Upload the file to one of the person's upload targets (nil: the default) and copy the link.
    case upload(target: String? = nil)
    case openWith(app: String)

    /// The name written in the text language (`if` and `ifNot` for the filters).
    public var name: String {
        switch self {
        case .optimise: "optimise"
        case .downscale: "downscale"
        case .lowerBitrate: "lowerBitrate"
        case .convert: "convert"
        case .crop: "crop"
        case .extractPagesAsImages: "extractPagesAsImages"
        case .targetSize: "targetSize"
        case .stripExif: "stripExif"
        case .watermark: "watermark"
        case .copy: "copy"
        case .move: "move"
        case .rename: "rename"
        case .delete: "delete"
        case .filterIf: "if"
        case .filterIfNot: "ifNot"
        case .removeAudio: "removeAudio"
        case .changeSpeed: "changeSpeed"
        case .capFps: "capFps"
        case .normalize: "normalize"
        case .runScript: "runScript"
        case .runShortcut: "runShortcut"
        case .copyToClipboard: "copyToClipboard"
        case .copyLinkForSending: "copyLinkForSending"
        case .fork: "fork"
        case .shelveWith: "shelveWith"
        case .uploadWith: "uploadWith"
        case .upload: "upload"
        case .openWith: "openWith"
        }
    }

    /// The media kinds the step applies to. A step that does not apply to the file is skipped.
    public var kinds: Set<MediaKind> { PipelineLanguage.spec(named: name)?.kinds ?? Set(MediaKind.allCases) }

    public var category: StepCategory { PipelineLanguage.spec(named: name)?.category ?? .action }

    /// The `location` argument of the steps that write a file, nil for the others.
    public var location: OutputLocation? {
        switch self {
        case let .optimise(_, _, _, location, _): location
        case let .downscale(_, location): location
        case let .lowerBitrate(_, location): location
        case let .convert(_, location): location
        case let .crop(_, _, _, _, _, location): location
        case let .extractPagesAsImages(_, _, location): location
        case let .targetSize(_, location): location
        case let .watermark(_, _, _, _, location): location
        case let .fork(location): location
        default: nil
        }
    }

    public var isFilter: Bool {
        switch self {
        case .filterIf, .filterIfNot: true
        default: false
        }
    }

    /// The step as pipeline text, e.g. `crop(longEdge: 1600)`.
    public var text: String { PipelineSerializer.serialize(self) }
}

public enum StepCategory: String, Codable, CaseIterable, Sendable {
    case processing, fileOperation, filter, mediaSpecific, action
}

// MARK: - Location spelling

extension OutputLocation {
    /// The location as written in the language: `inPlace`, `sameFolder`, `temporaryFolder` or a template.
    public var pipelineText: String {
        switch self {
        case .inPlace: "inPlace"
        case .sameFolder: "sameFolder"
        case .temporary: "temporaryFolder"
        case let .path(template): template
        }
    }

    /// Parses `inPlace`, `sameFolder`, `temporaryFolder` (or `temporary`); anything else is a template.
    public init(pipelineText text: String) {
        switch text {
        case "inPlace": self = .inPlace
        case "sameFolder": self = .sameFolder
        case "temporaryFolder", "temporary": self = .temporary
        default: self = .path(text)
        }
    }
}
