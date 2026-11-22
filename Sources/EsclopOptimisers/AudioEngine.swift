// SPDX-License-Identifier: GPL-3.0-or-later
//
// Audio through ffmpeg: AAC with AudioToolbox (ffmpeg's own AAC as fallback), MP3 with LAME
// VBR, Opus, FLAC, WAV/AIFF at the source's rate and depth. Lossless sources convert by the
// format lists in the settings (WAV to MP3, AIFF/FLAC to AAC; Apple Lossless only when the AAC
// list names `alac`); everything else is re-encoded in its own format at the bitrate the
// compression factor maps to, never above the source's. Tags stay unless strip is asked for.

import EsclopCore
import Foundation

struct AudioEngine: Sendable {
    let env: EngineEnvironment

    func targetCodec(for source: URL, plan: Plan) throws -> AudioCodec {
        if let format = plan.format {
            guard let codec = AudioCodec(format: format) else {
                throw EsclopError.invalidArgument("Audio converts to audio formats, not \(format.rawValue)")
            }
            return codec
        }
        let ext = source.pathExtension.lowercased()
        if convertsToAAC(ext) { return .aac }
        if env.value(EsclopSettings.formatsToConvertToMP3).map({ $0.lowercased() }).contains(ext) { return .mp3 }
        return AudioCodec(fileExtension: ext) ?? .aac
    }

    /// Whether the Convert to AAC list names `entry`: an extension, or `alac` for Apple Lossless.
    func convertsToAAC(_ entry: String) -> Bool {
        env.value(EsclopSettings.formatsToConvertToAAC).map { $0.lowercased() }.contains(entry)
    }

    func process(_ source: URL, plan: Plan, work: WorkFolder, progress: ProgressSink) async throws -> Produced {
        let info = try await MediaInfo.probe(source, tools: env.tools)
        guard let audio = info.audio else {
            throw EsclopError.unsupportedFile("\(source.lastPathComponent) has no audio")
        }
        let speed = plan.request.playbackSpeed.flatMap { $0 > 0 && abs($0 - 1) > 0.001 ? $0 : nil }
        let loudness = plan.request.loudnessLUFS ?? (env.value(EsclopSettings.normalizeLoudness) ? env.value(EsclopSettings.loudnessTarget) : nil)
        // Apple Lossless stays as it is unless something asks for a change: a format, a
        // bitrate, a size, aggressive optimising, a speed or loudness, or `alac` in the Convert
        // to AAC list.
        if audio.codec == "alac", plan.format == nil, plan.downscale == nil, plan.request.audioBitrateKbps == nil,
           !plan.isAggressive, speed == nil, loudness == nil, !convertsToAAC("alac")
        {
            throw EsclopError.alreadySmaller
        }
        let codec = try targetCodec(for: source, plan: plan)
        let sameExtension = AudioCodec(fileExtension: source.pathExtension) == codec
        let sameFormat = sameExtension && codec.carries(audio.codec)
        let factor = plan.factor(for: .audio, format: plan.format, env: env)
        var bitrate = plan.request.audioBitrateKbps
            ?? codec.bitrate(forFactor: factor)
            ?? codec.defaultBitrate
        bitrate = codec.resolveBitrate(bitrate, inputBitrate: sameFormat ? audio.bitrate : nil)
        if plan.isAggressive, !codec.allowedBitrates.isEmpty, sameFormat {
            bitrate = min(bitrate, codec.stepBelow(audio.bitrate))
        }
        // Downscale scales the source's bitrate, never above what optimising alone gives and
        // never under the codec's lowest step.
        if let scale = plan.downscale, plan.request.audioBitrateKbps == nil, let floor = codec.allowedBitrates.first, let input = audio.bitrate {
            bitrate = codec.resolveBitrate(max(floor, min(bitrate, Int(Double(input) * scale))), inputBitrate: nil)
        }
        var steps: [String] = []
        if sameExtension, !sameFormat {
            steps.append("Converted \(AudioCodec.label(probed: audio.codec)) to \(codec.label)")
        } else if !sameFormat {
            steps.append("Converted to \(codec.fileExtension.uppercased())")
        }
        if codec == .mp3 {
            // LAME VBR aims at a quality, not a rate: the file's rate depends on the sound.
            steps.append("Encoded VBR, about \(AudioCodec.lameVBRAverage(quality: AudioCodec.lameVBRQuality(forBitrate: bitrate))) kbit/s")
        } else if !codec.isLossless {
            steps.append("Encoded at \(bitrate) kbit/s")
        }
        let adpcm = codec == .wav && plan.isAggressive
        if adpcm { steps.append("Encoded as IMA ADPCM, which is lossy") }
        let deep = (audio.bitsPerSample ?? 16) > 16
        var aiff24Bit = false
        if codec == .aiff, deep { aiff24Bit = await FFmpegCapabilities.shared.encoders(tools: env.tools).contains("pcm_s24be") }
        if codec == .aiff, deep, !aiff24Bit {
            steps.append("Reduced to 16 bits: this ffmpeg has no 24-bit AIFF encoder")
        } else if codec == .aiff || (codec == .wav && !plan.isAggressive), (audio.bitsPerSample ?? 0) > 24 {
            steps.append("Reduced to 24 bits")
        }

        // MPEG-4 audio keeps its own name: an audiobook stays `.m4b`, also when converted to
        // AAC or fitted, since the container does not change.
        let sourceExtension = source.pathExtension.lowercased()
        let ext = codec == .aac && ["m4a", "m4b"].contains(sourceExtension) ? sourceExtension : codec.fileExtension
        let output = work.file(stem: "encoded", ext: ext)
        let duration = info.duration.map { $0 / (speed ?? 1) }
        let options = FFmpegProgress(duration: duration, sink: progress).options

        func arguments(appleAAC: Bool) -> [String] {
            var args = ["-hide_banner", "-nostdin", "-y", "-i", source.path]
            args += coverArtArgs(info: info, codec: codec)
            args += codec.encodingArgs(bitrate: bitrate, aggressive: plan.isAggressive, inputBits: audio.bitsPerSample, aiff24Bit: aiff24Bit, appleAAC: appleAAC)
            var filters: [String] = []
            if let speed { filters.append(VideoEngine.atempoChain(speed)) }
            if let loudness {
                // Single-pass loudnorm resamples to 192 kHz, which AudioToolbox AAC rejects.
                let rate = audio.sampleRate.map { Int($0) } ?? 48000
                filters.append("loudnorm=I=\(loudness):TP=-1.5:LRA=11,aresample=\(rate)")
            }
            if !filters.isEmpty { args += ["-filter:a", filters.joined(separator: ",")] }
            // Music keeps its title, artist and album unless stripping is asked for: the
            // strip-metadata setting describes photos and videos, not songs. The cover follows
            // the cover-art setting either way; only `strip` (`stripMetadata(_:work:)`) drops it.
            // Stripping as `stripMetadata(_:work:)` does, so the chapters keep their titles.
            args += plan.request.stripMetadata == true ? Self.stripTags : ["-map_metadata", "0"]
            // Chapter times do not follow a speed change (as in VideoEngine).
            if speed != nil { args += ["-map_chapters", "-1"] }
            args += ["-progress", "pipe:1", "-nostats", output.path]
            return args
        }

        do {
            try await ProcessRunner.run(.ffmpeg, arguments(appleAAC: true), options: options, locator: env.tools)
        } catch let error as EsclopError where codec == .aac && error != .cancelled {
            Log.audio.info("AudioToolbox AAC failed, using ffmpeg's AAC: \(error.description, privacy: .private)")
            try await ProcessRunner.run(.ffmpeg, arguments(appleAAC: false), options: options, locator: env.tools)
        }
        if let speed {
            steps.append("Changed speed to \(String(format: "%g", speed))x")
            if info.chapterCount > 0 {
                steps.append("Left out \(info.chapterCount) chapter\(info.chapterCount == 1 ? "" : "s"): their times do not follow a speed change")
            }
        }
        if info.hasCoverArt, codec.supportsCoverArt, env.value(EsclopSettings.audioCoverArt) == .optimise {
            steps.append("Recompressed the cover, 600 px at most")
        }
        if let loudness { steps.append("Normalised loudness to \(String(format: "%g", loudness)) LUFS") }
        if plan.request.stripMetadata == true { steps.append("Removed metadata") }
        // A new codec under the same name (Apple Lossless to AAC in an .m4a) still has to shrink.
        let changesContent = !sameExtension || speed != nil || loudness != nil
        let sameContent = sameFormat && speed == nil && loudness == nil
        return Produced(url: output, width: nil, height: nil, duration: duration, steps: steps, allowLarger: changesContent, lossless: codec.isLossless && !adpcm && sameContent)
    }

    /// Album artwork: kept, recompressed to at most 600 px JPEG, or dropped.
    private func coverArtArgs(info: MediaInfo, codec: AudioCodec) -> [String] {
        guard info.hasCoverArt, codec.supportsCoverArt else { return ["-map", "0:a", "-vn"] }
        switch env.value(EsclopSettings.audioCoverArt) {
        case .remove:
            return ["-map", "0:a", "-vn"]
        case .keep:
            return ["-map", "0:a", "-map", "0:v?", "-c:v", "copy", "-disposition:v:0", "attached_pic"]
        case .optimise:
            return [
                "-map", "0:a", "-map", "0:v?", "-c:v", "mjpeg", "-q:v", "4",
                "-vf", "scale='min(600,iw)':'min(600,ih)':force_original_aspect_ratio=decrease",
                "-disposition:v:0", "attached_pic",
            ]
        }
    }

    /// Bitrate from the duration, then one allowed step lower at a time.
    func fit(_ source: URL, under target: Int, plan: Plan, work: WorkFolder, progress: ProgressSink) async throws -> Produced {
        let info = try await MediaInfo.probe(source, tools: env.tools)
        guard let duration = info.duration, duration > 0 else {
            throw EsclopError.unsupportedFile("Cannot read the duration of \(source.lastPathComponent)")
        }
        var codec = try targetCodec(for: source, plan: plan)
        if codec.isLossless, plan.format == nil { codec = .aac }
        guard !codec.isLossless else {
            throw EsclopError.losslessCannotFit(format: codec.fileExtension.uppercased())
        }
        let budget = Int(Double(target) * 8 / duration / 1000 * 0.95)
        var candidates = codec.allowedBitrates.filter { $0 <= budget }.reversed().map { $0 }
        if candidates.isEmpty, let lowest = codec.allowedBitrates.first { candidates = [lowest] }
        var smallest = Int.max
        for kbps in candidates {
            var attempt = plan
            attempt.format = codec == .aac ? .m4a : OutputFormat(name: codec.fileExtension)
            attempt.request.audioBitrateKbps = kbps
            let folder = try WorkFolder(root: work.url)
            var produced = try await process(source, plan: attempt, work: folder, progress: progress)
            let size = fileSize(produced.url)
            smallest = min(smallest, size)
            if size <= target {
                produced.allowLarger = true
                produced.steps.append("Fit under \(ByteFormat.string(target))")
                return produced
            }
        }
        throw EsclopError.cannotFit(underBytes: target, smallest: smallest == Int.max ? nil : smallest)
    }

    /// The file's and the audio's tags go (Ogg and Opus keep theirs on the stream, and with them
    /// the track language); the chapters and their titles describe the content and stay, as in
    /// a video's strip. A plain `-map_metadata -1` blanks the chapter titles.
    static let stripTags = ["-map_metadata:g", "-1", "-map_metadata:s:a", "-1"]

    func stripMetadata(_ source: URL, work: WorkFolder) async throws -> Produced {
        let output = work.file(stem: "stripped", ext: source.pathExtension.isEmpty ? "m4a" : source.pathExtension)
        try await ProcessRunner.run(.ffmpeg, [
            "-hide_banner", "-nostdin", "-y", "-i", source.path, "-map", "0:a", "-c", "copy",
        ] + Self.stripTags + ["-map_chapters", "0", "-progress", "pipe:1", "-nostats", output.path], options: FFmpegProgress(duration: nil, sink: .none).options, locator: env.tools)
        return Produced(url: output, width: nil, height: nil, duration: nil, steps: ["Removed metadata and artwork"], allowLarger: true)
    }
}
