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
    /// bitrates); without it ffmpeg's native AAC encoder is used.
    func encodingArgs(bitrate: Int, aggressive: Bool, inputSampleRate: Double?, appleAAC: Bool = true) -> [String] {
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
            // 16-bit PCM, at most 48 kHz.
            var args = ["-c:a", "pcm_s16le"]
            if let rate = inputSampleRate, rate > 48000 { args += ["-ar", "48000"] }
            return args
        case .flac:
            return ["-c:a", "flac", "-compression_level", aggressive ? "12" : "8"]
        case .aiff:
            var args = ["-c:a", "pcm_s16be"]
            if let rate = inputSampleRate, rate > 48000 { args += ["-ar", "48000"] }
            return args
        }
    }
}
