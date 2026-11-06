// SPDX-License-Identifier: GPL-3.0-or-later
//
// One way to optimise a file, as the options popover shows it and a clipboard rule stores it:
// the output format, how hard to compress and the kind-specific extras. It turns into the
// fields of an `OptimisationRequest`, so a choice made in the popover, a suggestion and a rule
// all run through the same engine operations.

import EsclopCore
import Foundation
import UniformTypeIdentifiers

public struct OptimiseChoice: Codable, Hashable, Sendable {
    public enum Compression: String, Codable, CaseIterable, Sendable {
        case adaptive, lossless, aggressive

        var quality: CompressionQuality {
            switch self {
            case .adaptive: return .normal
            case .lossless: return CompressionQuality(tier: .custom, factor: 0)
            case .aggressive: return .aggressive
            }
        }
    }

    /// nil keeps the file's format.
    public var format: OutputFormat?
    public var compression: Compression
    /// The quality slider, 0...100 (higher keeps more). nil follows the compression.
    public var quality: Int?
    /// nil follows the setting.
    public var stripMetadata: Bool?
    /// HDR to SDR. nil follows the setting.
    public var keepHDR: Bool?
    public var fps: Double?
    public var videoEncoder: VideoEncoder?
    public var removeAudio: Bool
    public var playbackSpeed: Double?
    public var pdfDPI: Int?
    public var audioBitrate: Int?
    public var loudness: Double?

    public init(
        format: OutputFormat? = nil, compression: Compression = .adaptive, quality: Int? = nil, stripMetadata: Bool? = nil,
        keepHDR: Bool? = nil, fps: Double? = nil, videoEncoder: VideoEncoder? = nil, removeAudio: Bool = false,
        playbackSpeed: Double? = nil, pdfDPI: Int? = nil, audioBitrate: Int? = nil, loudness: Double? = nil
    ) {
        self.format = format
        self.compression = compression
        self.quality = quality
        self.stripMetadata = stripMetadata
        self.keepHDR = keepHDR
        self.fps = fps
        self.videoEncoder = videoEncoder
        self.removeAudio = removeAudio
        self.playbackSpeed = playbackSpeed
        self.pdfDPI = pdfDPI
        self.audioBitrate = audioBitrate
        self.loudness = loudness
    }

    /// The default: keep the format, adaptive, everything else from the settings.
    public static let standard = OptimiseChoice()

    /// The slider's value for a compression: the engine factor runs the other way (higher is smaller).
    public static func quality(for compression: Compression) -> Int { 100 - compression.quality.factor }

    public var effectiveQuality: Int { quality ?? Self.quality(for: compression) }

    public func apply(to request: inout OptimisationRequest) {
        request.format = format
        if let quality {
            request.quality = CompressionQuality(tier: compression == .aggressive ? .aggressive : .custom, factor: 100 - quality)
        } else {
            request.quality = compression.quality
        }
        if let stripMetadata { request.stripMetadata = stripMetadata }
        if let keepHDR { request.keepHDR = keepHDR }
        if let fps { request.fpsCap = fps }
        if let videoEncoder { request.videoEncoder = videoEncoder }
        request.removeAudio = removeAudio
        request.playbackSpeed = playbackSpeed
        if let pdfDPI { request.pdfDPI = pdfDPI }
        if let audioBitrate { request.audioBitrateKbps = audioBitrate }
        if let loudness { request.loudnessLUFS = loudness }
    }

    /// "PNG · Adaptive · strip metadata": what the choice does, for a file of `input` format.
    /// `note` replaces the metadata phrase ("strip location", "keep transparency").
    public func summary(input: OutputFormat?, note: String? = nil, locale: Locale = Strings.locale) -> String {
        let format = self.format ?? input
        var parts = [format?.displayName].compactMap { $0 }
        switch format?.kind ?? .image {
        case .image:
            parts.append(quality.map { Strings.quality($0, locale: locale) } ?? compression.title(locale: locale))
        case .video:
            if let videoEncoder, format != .hevc, format != .av1 { parts.append(videoEncoder.displayName) }
            if let fps { parts.append("\(Int(fps)) fps") }
            if compression != .adaptive || fps == nil { parts.append(compression.title(locale: locale)) }
            if removeAudio { parts.append(Strings.text("no audio", locale: locale)) }
        case .pdf:
            if let pdfDPI { parts += ["\(pdfDPI) DPI", Strings.text("keep text", locale: locale)] } else { parts.append(compression.title(locale: locale)) }
        case .audio:
            if let audioBitrate { parts.append("\(audioBitrate) kbps") }
            if let loudness { parts.append(Figures.lufs(loudness, locale: locale)) }
            if audioBitrate == nil, loudness == nil { parts.append(compression.title(locale: locale)) }
        }
        if let note { parts.append(note) } else if stripMetadata == true { parts.append(Strings.text("strip metadata", locale: locale)) }
        return parts.joined(separator: " · ")
    }
}

extension OptimiseChoice.Compression {
    public var title: String { title(locale: Strings.locale) }

    public func title(locale: Locale) -> String {
        switch self {
        case .adaptive: return Strings.text("Adaptive", locale: locale)
        case .lossless: return Strings.text("Lossless", locale: locale)
        case .aggressive: return Strings.text("Aggressive", locale: locale)
        }
    }
}

extension OutputFormat {
    /// "PNG", "JPEG XL", "HEVC".
    public var displayName: String {
        switch self {
        case .jxl: return "JPEG XL"
        case .webp: return "WebP"
        case .webm: return "WebM"
        case .opus: return "Opus"
        case .gifVideo: return "GIF"
        case .hevc: return "HEVC"
        case .av1: return "AV1"
        default: return rawValue.uppercased()
        }
    }

    /// The format of a file, from its extension.
    public static func of(_ url: URL) -> OutputFormat? { OutputFormat(name: url.pathExtension) }

    /// The format of a UTType. MPEG-4 audio prefers ".mp4" but arrives as ".m4a".
    public static func of(type identifier: String) -> OutputFormat? {
        if identifier == UTType.mpeg4Audio.identifier { return .m4a }
        return UTType(identifier)?.preferredFilenameExtension.flatMap(OutputFormat.init(name:))
    }
}

extension VideoEncoder {
    public var displayName: String {
        switch self {
        case .h264Software: return "H.264 (x264)"
        case .h264VideoToolbox: return "H.264"
        case .hevcVideoToolbox: return "HEVC"
        case .hevcSoftware: return "HEVC (x265)"
        case .av1: return "AV1"
        case .vp9: return "VP9"
        }
    }
}

/// What the popover suggests first, from the file's origin and format (DESIGN.md › Origin rules).
public enum Suggestion {
    public static func choice(for origin: FileOrigin, input: OutputFormat?) -> OptimiseChoice {
        switch origin {
        case .screenshot:
            return OptimiseChoice(format: input == .png ? .png : nil, stripMetadata: true)
        case .photos:
            return input == .heic ? OptimiseChoice(format: .jpeg, stripMetadata: true) : OptimiseChoice(stripMetadata: true)
        case .browser:
            return OptimiseChoice(format: input == .webp ? .webp : nil)
        case .graphic:
            return OptimiseChoice(format: .png)
        case .animatedGIF:
            return OptimiseChoice(format: .webp)
        case .screenRecording:
            return OptimiseChoice(format: .hevc, stripMetadata: true, fps: 30)
        case .pdfExport:
            return OptimiseChoice(pdfDPI: 150)
        case .voiceMemo:
            return OptimiseChoice(format: .aac, audioBitrate: 96, loudness: -16)
        case .unknown:
            return .standard
        }
    }

    /// The suggestion's one-line note, where the format alone does not say it.
    public static func note(for origin: FileOrigin) -> String? {
        switch origin {
        case .graphic: return Strings.text("keep transparency")
        case .animatedGIF: return Strings.text("keep timing")
        case .photos: return Strings.text("strip location")
        default: return nil
        }
    }
}
