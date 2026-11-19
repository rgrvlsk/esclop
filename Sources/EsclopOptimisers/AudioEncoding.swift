// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Audio.swift
//  Clop
//
//  Created by Alin Panaitiu on 19.03.2026.
//
// (Shared/AudioFormat.swift, the other source of this file, has no header comment of its own.)
//
// Derived from Clop (github.com/FuzzyIdeas/Clop, commit 4be5106), GPL-3.0, Copyright Alin Panaitiu.
// Modified 2026-11-03 for L'Esclop: kept the per-codec bitrate ranges, the factor-to-bitrate
// curve, the allowed bitrate steps, the LAME VBR mapping and the ffmpeg encoding arguments;
// mapped the formats onto L'Esclop's `OutputFormat`, added a fallback from AudioToolbox AAC to
// ffmpeg's own AAC encoder, and dropped the settings and UI plumbing.
// Modified 2026-11-19: lossless output keeps the source's sample rate and bit depth, and the
// codec in the file (not only its extension) decides whether the format stays the same.

import EsclopCore
import Foundation

enum AudioCodec: String, CaseIterable, Sendable {
    case aac, mp3, opus, wav, flac, aiff

    init?(format: OutputFormat) {
        switch format {
        case .aac, .m4a: self = .aac
        case .mp3: self = .mp3
        case .opus: self = .opus
        case .wav: self = .wav
        case .flac: self = .flac
        case .aiff: self = .aiff
        default: return nil
        }
    }

    /// The codec a file's extension implies, used when the format stays the same.
    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "m4a", "aac", "mp4", "m4b": self = .aac
        case "mp3": self = .mp3
        case "opus", "ogg", "oga": self = .opus
        case "wav", "wave": self = .wav
        case "flac": self = .flac
        case "aif", "aiff", "aifc": self = .aiff
        default: return nil
        }
    }

    var fileExtension: String {
        switch self {
        case .aac: return "m4a"
        case .mp3: return "mp3"
        case .opus: return "opus"
        case .wav: return "wav"
        case .flac: return "flac"
        case .aiff: return "aiff"
        }
    }

    var isLossless: Bool { self == .wav || self == .flac || self == .aiff }

    /// Whether a stream ffprobe calls `codec` is already this codec (an .m4a can hold Apple
    /// Lossless, an .ogg Vorbis).
    func carries(_ codec: String) -> Bool {
        switch self {
        case .aac, .mp3, .opus, .flac: return codec == rawValue
        case .wav: return codec.hasPrefix("pcm_") || codec.hasPrefix("adpcm_")
        case .aiff: return codec.hasPrefix("pcm_")
        }
    }

    var label: String {
        switch self {
        case .aac: return "AAC"
        case .mp3: return "MP3"
        case .opus: return "Opus"
        case .wav: return "WAV"
        case .flac: return "FLAC"
        case .aiff: return "AIFF"
        }
    }

    /// A name for a codec ffprobe reports, for step lines.
    static func label(probed codec: String) -> String {
        switch codec {
        case "alac": return "Apple Lossless"
        case "vorbis": return "Vorbis"
        default: return AudioCodec.allCases.first { $0.carries(codec) }?.label ?? codec.uppercased()
        }
    }

    /// Containers ffmpeg can write an attached picture into.
    var supportsCoverArt: Bool { self == .aac || self == .mp3 || self == .flac }

    var allowedBitrates: [Int] {
        switch self {
        case .aac: return [56, 64, 80, 96, 128, 160, 192, 256]
        case .mp3: return [56, 64, 80, 96, 128, 160, 192, 256, 320]
        case .opus: return [32, 48, 64, 80, 96, 128]
        case .wav, .flac, .aiff: return []
        }
    }

    var defaultBitrate: Int {
        switch self {
        case .aac, .mp3: return 192
        case .opus: return 128
        case .wav, .flac, .aiff: return 0
        }
    }

    /// kbit/s from the best-quality end (`high`) to the smallest-file end (`low`). Opus needs the
    /// fewest bits for the same perceived quality, then AAC, then MP3.
    var bitrateRange: (low: Int, high: Int)? {
        switch self {
        case .mp3: return (64, 320)
        case .aac: return (48, 256)
        case .opus: return (32, 160)
        case .wav, .flac, .aiff: return nil
        }
    }

    /// Bitrate for a compression factor: 5 is the top of the range, 100 the bottom, rounded to
    /// multiples of 16 so familiar values (96, 128, 160, 192) come up.
    func bitrate(forFactor factor: Int) -> Int? {
        guard let (low, high) = bitrateRange, high > low else { return nil }
        let t = Double(min(100, max(5, factor)) - 5) / 95
        let raw = Double(high) - t * Double(high - low)
        let rounded = max(8, Int((raw / 16).rounded()) * 16)
        return min(high, max(low, rounded))
    }

    /// Caps a target at the input's bitrate (never upsample) and snaps it to an allowed step.
    func resolveBitrate(_ target: Int, inputBitrate: Int?) -> Int {
        var capped = target
        if let input = inputBitrate, input > 0 { capped = min(target, input) }
        guard !allowedBitrates.isEmpty else { return capped }
        return allowedBitrates.last { $0 <= capped } ?? allowedBitrates.first ?? capped
    }

    /// One allowed step below the input, so an aggressive pass always shrinks a lossy file.
    func stepBelow(_ inputBitrate: Int?) -> Int {
        let input = inputBitrate ?? defaultBitrate
        guard !allowedBitrates.isEmpty else { return input }
        let index = allowedBitrates.lastIndex { $0 <= input } ?? (allowedBitrates.count - 1)
        return allowedBitrates[max(0, index - 1)]
    }

    /// LAME VBR quality (0 best, 9 worst) for a target bitrate.
    static func lameVBRQuality(forBitrate bitrate: Int) -> Int {
        switch bitrate {
        case ...64: return 9
        case ...80: return 8
        case ...96: return 7
        case ...128: return 5
        case ...160: return 4
        case ...192: return 2
        default: return 0
        }
    }

    /// ffmpeg encoder arguments. `appleAAC` picks AudioToolbox's encoder (better at low
    /// bitrates); without it ffmpeg's native AAC encoder is used. Lossless output keeps the
    /// source's sample rate, and 24 bits for anything deeper than 16 (`aiff24Bit`: this ffmpeg
    /// has `pcm_s24be`). The bundled ffmpeg has no 32-bit PCM encoders, so 32-bit becomes 24.
    func encodingArgs(bitrate: Int, aggressive: Bool, inputBits: Int?, aiff24Bit: Bool = false, appleAAC: Bool = true) -> [String] {
        let deep = (inputBits ?? 16) > 16
        switch self {
        case .aac:
            return appleAAC
                ? ["-c:a", "aac_at", "-b:a", "\(bitrate)k", "-aac_at_mode", "cvbr"]
                : ["-c:a", "aac", "-b:a", "\(bitrate)k"]
        case .mp3:
            return ["-c:a", "libmp3lame", "-q:a", "\(Self.lameVBRQuality(forBitrate: bitrate))"]
        case .opus:
            return ["-c:a", "libopus", "-b:a", "\(bitrate)k", "-vbr", "on"]
        case .wav:
            if aggressive { return ["-c:a", "adpcm_ima_wav"] }
            return ["-c:a", deep ? "pcm_s24le" : "pcm_s16le"]
        case .flac:
            return ["-c:a", "flac", "-compression_level", aggressive ? "12" : "8"]
        case .aiff:
            return ["-c:a", deep && aiff24Bit ? "pcm_s24be" : "pcm_s16be"]
        }
    }
}
