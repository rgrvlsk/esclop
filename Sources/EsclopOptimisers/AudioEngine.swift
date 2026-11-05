// SPDX-License-Identifier: GPL-3.0-or-later
//
// Audio through ffmpeg: AAC with AudioToolbox (ffmpeg's own AAC as fallback), MP3 with LAME
// VBR, Opus, FLAC, 16-bit WAV/AIFF. Lossless sources convert by the format lists in the settings
// (WAV to MP3, AIFF/FLAC to AAC); everything else is re-encoded in its own format at the bitrate
// the compression factor maps to, never above the source's.

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
        if env.value(EsclopSettings.formatsToConvertToAAC).map({ $0.lowercased() }).contains(ext) { return .aac }
        if env.value(EsclopSettings.formatsToConvertToMP3).map({ $0.lowercased() }).contains(ext) { return .mp3 }
        return AudioCodec(fileExtension: ext) ?? .aac
    }

    func process(_ source: URL, plan: Plan, work: WorkFolder, progress: ProgressSink) async throws -> Produced {
        let info = try await MediaInfo.probe(source, tools: env.tools)
        guard let audio = info.audio else {
            throw EsclopError.unsupportedFile("\(source.lastPathComponent) has no audio")
        }
        let codec = try targetCodec(for: source, plan: plan)
        let sameFormat = AudioCodec(fileExtension: source.pathExtension) == codec
        let factor = plan.factor(for: .audio, format: plan.format, env: env)
        var bitrate = plan.request.audioBitrateKbps
            ?? codec.bitrate(forFactor: factor)
            ?? codec.defaultBitrate
        bitrate = codec.resolveBitrate(bitrate, inputBitrate: sameFormat ? audio.bitrate : nil)
        if plan.isAggressive, !codec.allowedBitrates.isEmpty, sameFormat {
            bitrate = min(bitrate, codec.stepBelow(audio.bitrate))
        }
        var steps: [String] = []
        if !sameFormat { steps.append("Converted to \(codec.fileExtension.uppercased())") }
        if !codec.isLossless { steps.append("Encoded at \(bitrate) kbit/s") }

        let output = work.file(stem: "encoded", ext: codec.fileExtension)
        let speed = plan.request.playbackSpeed.flatMap { $0 > 0 && abs($0 - 1) > 0.001 ? $0 : nil }
        let loudness = plan.request.loudnessLUFS ?? (env.value(EsclopSettings.normalizeLoudness) ? env.value(EsclopSettings.loudnessTarget) : nil)
        let duration = info.duration.map { $0 / (speed ?? 1) }
        let parser = FFmpegProgress(duration: duration, sink: progress)

        func arguments(appleAAC: Bool) -> [String] {
            var args = ["-hide_banner", "-nostdin", "-y", "-i", source.path]
            args += coverArtArgs(info: info, codec: codec)
            args += codec.encodingArgs(bitrate: bitrate, aggressive: plan.isAggressive, inputSampleRate: audio.sampleRate, appleAAC: appleAAC)
            var filters: [String] = []
            if let speed { filters.append(VideoEngine.atempoChain(speed)) }
            if let loudness {
                // Single-pass loudnorm resamples to 192 kHz, which AudioToolbox AAC rejects.
                let rate = audio.sampleRate.map { Int($0) } ?? 48000
                filters.append("loudnorm=I=\(loudness):TP=-1.5:LRA=11,aresample=\(rate)")
            }
            if !filters.isEmpty { args += ["-filter:a", filters.joined(separator: ",")] }
            args += ["-map_metadata", plan.strip ? "-1" : "0"]
            args += ["-progress", "pipe:1", "-nostats", output.path]
            return args
        }

        do {
            try await ProcessRunner.run(.ffmpeg, arguments(appleAAC: true), options: ProcessOptions(onStdoutLine: parser.lineHandler), locator: env.tools)
        } catch let error as EsclopError where codec == .aac && error != .cancelled {
            Log.audio.info("AudioToolbox AAC failed, using ffmpeg's AAC: \(error.description, privacy: .public)")
            try await ProcessRunner.run(.ffmpeg, arguments(appleAAC: false), options: ProcessOptions(onStdoutLine: parser.lineHandler), locator: env.tools)
        }
        if let speed { steps.append("Changed speed to \(String(format: "%g", speed))x") }
        if let loudness { steps.append("Normalised loudness to \(String(format: "%g", loudness)) LUFS") }
        let changesContent = !sameFormat || speed != nil || loudness != nil
        return Produced(url: output, width: nil, height: nil, duration: duration, steps: steps, allowLarger: changesContent)
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
            throw EsclopError.invalidArgument("\(codec.fileExtension.uppercased()) is lossless and cannot be fitted to a size")
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
        throw EsclopError.other("Could not fit under \(ByteFormat.string(target)); the smallest attempt was \(ByteFormat.string(smallest))")
    }

    func stripMetadata(_ source: URL, work: WorkFolder) async throws -> Produced {
        let output = work.file(stem: "stripped", ext: source.pathExtension.isEmpty ? "m4a" : source.pathExtension)
        try await ProcessRunner.run(.ffmpeg, [
            "-hide_banner", "-nostdin", "-y", "-i", source.path, "-map", "0:a", "-c", "copy",
            "-map_metadata", "-1", "-map_chapters", "-1", output.path,
        ], locator: env.tools)
        return Produced(url: output, width: nil, height: nil, duration: nil, steps: ["Removed metadata and artwork"], allowLarger: true)
    }
}
