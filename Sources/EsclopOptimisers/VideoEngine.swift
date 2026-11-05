// SPDX-License-Identifier: GPL-3.0-or-later
//
// Videos through ffmpeg. H.264 and HEVC use VideoToolbox (the media engine on Apple Silicon;
// with `-allow_sw` as a fallback where there is no hardware encoder), AV1 uses SVT-AV1, WebM
// uses VP9 and Opus. One ffmpeg pass applies crop, scale, speed, frame rate cap, audio removal
// and bitrate together. Videos become GIFs through esclop-engine's gifski, or ffmpeg's palette
// filters when the engine cannot.

import EsclopCore
import Foundation

struct VideoEngine: Sendable {
    let env: EngineEnvironment

    enum Codec: Equatable {
        case h264VT, hevcVT, av1, vp9, h264x264, hevcx265

        var label: String {
            switch self {
            case .h264VT: return "H.264 (VideoToolbox)"
            case .hevcVT: return "HEVC (VideoToolbox)"
            case .av1: return "AV1 (SVT-AV1)"
            case .vp9: return "VP9"
            case .h264x264: return "H.264 (x264)"
            case .hevcx265: return "HEVC (x265)"
            }
        }
    }

    struct EncodeSettings {
        var container: OutputFormat
        var codec: Codec
        var factor: Int
        var videoBitrate: Int?
        var filters: [String]
        var fpsCap: Double?
        var speed: Double?
        var removeAudio: Bool
        var audioBitrate: Int?
        var reencodeAudio: Bool
        var strip: Bool
        var hdr: MediaInfo.Video?
        var width: Int
        var height: Int
        var loudness: Double?
        var watermark: Watermark?
    }

    // MARK: Optimise, convert, downscale, crop

    func process(_ source: URL, plan: Plan, work: WorkFolder, progress: ProgressSink) async throws -> Produced {
        let info = try await MediaInfo.probe(source, tools: env.tools)
        guard let video = info.video else {
            throw EsclopError.unsupportedFile("\(source.lastPathComponent) has no video stream")
        }
        let sourceFormat = OutputFormat.of(url: source)
        let container = targetContainer(for: source, sourceFormat: sourceFormat, plan: plan)
        if container == .gif || container == .gifVideo {
            return try await toGIF(source, info: info, plan: plan, work: work, progress: progress)
        }
        if container.kind != .video {
            throw EsclopError.invalidArgument("Videos convert to video formats or GIF, not \(container.rawValue)")
        }

        var steps: [String] = []
        let formatChanged = container.fileExtension != source.pathExtension.lowercased()
            && !(container == .mp4 && ["mp4", "m4v"].contains(source.pathExtension.lowercased()))
        if formatChanged { steps.append("Converted to \(container.fileExtension.uppercased())") }

        var settings = try await videoSettings(for: video, info: info, container: container, plan: plan, steps: &steps)
        let produced = try await encode(source, info: info, settings: &settings, work: work, progress: progress, steps: steps)
        var result = produced
        let speedChanged = (plan.request.playbackSpeed ?? 1) != 1
        result.allowLarger = plan.allowsLarger(formatChanged: formatChanged) || speedChanged
            || plan.watermark != nil || plan.request.loudnessLUFS != nil
        return result
    }

    func targetContainer(for source: URL, sourceFormat: OutputFormat?, plan: Plan) -> OutputFormat {
        if let format = plan.format { return format }
        let ext = source.pathExtension.lowercased()
        if plan.automatic, env.value(EsclopSettings.formatsToConvertToMP4).map({ $0.lowercased() }).contains(ext) {
            return .mp4
        }
        switch ext {
        case "mov", "qt": return .mov
        case "webm": return .webm
        case "mkv": return .mkv
        case "mp4", "m4v": return .mp4
        default: return .mp4 // avi, mpeg, wmv, flv, animated GIF...: MP4 plays everywhere
        }
    }

    private func videoSettings(
        for video: MediaInfo.Video, info: MediaInfo, container: OutputFormat, plan: Plan, steps: inout [String]
    ) async throws -> EncodeSettings {
        let request = plan.request
        let factor = plan.factor(for: .video, format: container, env: env)
        let codec = try await chooseCodec(container: container, request: request, video: video, keepHDR: plan.keepHDR)

        var filters: [String] = []
        var width = video.width
        var height = video.height
        if let crop = plan.crop {
            let target = crop.targetSize(fromWidth: width, height: height)
            if crop.cropsAspect(fromWidth: width, height: height) {
                let aspect = Double(target.width) / Double(target.height)
                let rect = ImageIOCodec.cropRect(for: nil, width: width, height: height, aspect: aspect, smart: false)
                filters.append("crop=\(even(rect.width)):\(even(rect.height)):\(Int(rect.minX)):\(Int(rect.minY))")
                steps.append("Cropped to \(even(rect.width))x\(even(rect.height))")
            }
            width = target.width
            height = target.height
        }
        if let factor = plan.downscale {
            width = Int(Double(width) * factor)
            height = Int(Double(height) * factor)
        }
        width = even(Double(width))
        height = even(Double(height))
        if width != even(Double(video.width)) || height != even(Double(video.height)) || filters.contains(where: { $0.hasPrefix("crop") }) {
            filters.append("scale=\(width):\(height):flags=lanczos")
            steps.append("Resized to \(width)x\(height)")
        } else if video.width % 2 == 1 || video.height % 2 == 1 {
            filters.append("scale=trunc(iw/2)*2:trunc(ih/2)*2")
        }

        // Frame rate cap: the request, else the settings (-2 halves, -4 quarters the source rate).
        var fpsCap = request.fpsCap
        if fpsCap == nil, env.value(EsclopSettings.capVideoFPS) {
            let target = env.value(EsclopSettings.targetVideoFPS)
            let minimum = env.value(EsclopSettings.minVideoFPS)
            if target < 0, let fps = video.fps {
                fpsCap = max(fps / abs(target), minimum)
            } else if target > 0 {
                fpsCap = target
            }
        }
        if let cap = fpsCap, let fps = video.fps, cap >= fps - 0.01 { fpsCap = nil }

        var speed = request.playbackSpeed.flatMap { $0 > 0 && abs($0 - 1) > 0.001 ? $0 : nil }
        if let factor = speed {
            filters.append("setpts=PTS/\(String(format: "%.4f", factor))")
            let keepFrames = plan.keepFrames ?? (env.value(EsclopSettings.playbackSpeedFrames) == .keepFrames)
            if !keepFrames, let fps = video.fps {
                filters.append("fps=\(String(format: "%.3f", fps))")
            }
            steps.append("Changed speed to \(String(format: "%g", factor))x")
        } else {
            speed = nil
        }
        if let cap = fpsCap { steps.append("Capped frame rate at \(String(format: "%g", cap)) fps") }

        let removeAudio = request.removeAudio || env.value(EsclopSettings.removeAudioFromVideos) || info.audio == nil
        if request.removeAudio || env.value(EsclopSettings.removeAudioFromVideos), info.audio != nil {
            steps.append("Removed audio")
        }
        let loudness = removeAudio ? nil : request.loudnessLUFS
        if let loudness { steps.append("Normalised loudness to \(String(format: "%g", loudness)) LUFS") }
        if let mark = plan.watermark { steps.append("Added a watermark (\(mark.position.rawValue))") }
        let reencodeAudio = !removeAudio && (speed != nil || loudness != nil || container == .webm || request.audioBitrateKbps != nil
            || env.value(EsclopSettings.convertAudioToAAC) || !audioFits(info.audio?.codec, in: container))
        if let kbps = request.videoBitrateKbps { steps.append("Video bitrate \(kbps) kbit/s") }

        return EncodeSettings(
            container: container, codec: codec, factor: factor, videoBitrate: request.videoBitrateKbps,
            filters: filters, fpsCap: fpsCap, speed: speed, removeAudio: removeAudio,
            audioBitrate: request.audioBitrateKbps, reencodeAudio: reencodeAudio, strip: plan.strip,
            hdr: plan.keepHDR && video.isHDR ? video : nil, width: width, height: height,
            loudness: loudness, watermark: plan.watermark
        )
    }

    /// The codec for a container and encoder choice, given what this ffmpeg build has.
    func chooseCodec(container: OutputFormat, request: OptimisationRequest, video: MediaInfo.Video, keepHDR: Bool) async throws -> Codec {
        let encoders = await FFmpegCapabilities.shared.encoders(tools: env.tools)
        switch container {
        case .webm: return .vp9
        case .av1: return .av1
        case .hevc: return .hevcVT
        default: break
        }
        let choice = request.videoEncoder ?? env.value(EsclopSettings.videoEncoder)
        var codec: Codec
        switch choice {
        case .h264VideoToolbox: codec = .h264VT
        case .hevcVideoToolbox: codec = .hevcVT
        case .av1: codec = .av1
        case .vp9: codec = container == .mkv ? .vp9 : .h264VT
        case .h264Software: codec = encoders.contains("libx264") ? .h264x264 : .h264VT
        case .hevcSoftware: codec = encoders.contains("libx265") ? .hevcx265 : .hevcVT
        }
        // 8-bit H.264 would clip HDR; HEVC Main 10 keeps it.
        if keepHDR, video.isHDR, codec == .h264VT || codec == .h264x264 { codec = .hevcVT }
        return codec
    }

    private func audioFits(_ codec: String?, in container: OutputFormat) -> Bool {
        guard let codec else { return true }
        switch container {
        case .mp4, .mov, .hevc, .av1:
            return ["aac", "alac", "mp3", "ac3", "eac3", "opus", "pcm_s16le", "pcm_s24le"].contains(codec)
                && !(container == .mp4 && codec.hasPrefix("pcm"))
        case .webm: return ["opus", "vorbis"].contains(codec)
        default: return true
        }
    }

    // MARK: ffmpeg

    func encoderArgs(_ settings: EncodeSettings, softwareFallback: Bool) -> [String] {
        let curves = Curves(settings.factor)
        let tag = settings.container == .mkv ? [] : ["-tag:v"]
        var args: [String]
        switch settings.codec {
        case .h264VT, .hevcVT:
            let hevc = settings.codec == .hevcVT
            args = ["-c:v", hevc ? "hevc_videotoolbox" : "h264_videotoolbox"]
            if let kbps = settings.videoBitrate {
                args += ["-b:v", "\(kbps)k", "-maxrate", "\(kbps * 3 / 2)k", "-bufsize", "\(kbps * 2)k"]
            } else if softwareFallback {
                // The software encoder has no constant-quality mode; aim at a bitrate instead.
                args += ["-b:v", "\(estimatedBitrate(settings))k"]
            } else {
                args += ["-q:v", "\(hevc ? curves.videoToolboxHEVCQuality : curves.videoToolboxH264Quality)"]
            }
            if softwareFallback { args += ["-allow_sw", "1"] }
            if !tag.isEmpty { args += tag + [hevc ? "hvc1" : "avc1"] }
            if hevc, settings.hdr != nil { args += ["-profile:v", "main10", "-pix_fmt", "p010le"] } else { args += ["-pix_fmt", "yuv420p"] }
        case .av1:
            args = ["-c:v", "libsvtav1", "-preset", "\(curves.av1Preset)"]
            if let kbps = settings.videoBitrate {
                args += ["-b:v", "\(kbps)k"]
            } else {
                args += ["-crf", "\(curves.av1CRF)"]
            }
            args += ["-pix_fmt", settings.hdr != nil ? "yuv420p10le" : "yuv420p", "-svtav1-params", "log-level=1"]
        case .vp9:
            args = ["-c:v", "libvpx-vp9", "-row-mt", "1"]
            if let kbps = settings.videoBitrate {
                args += ["-b:v", "\(kbps)k"]
            } else {
                args += ["-crf", "\(curves.vp9CRF)", "-b:v", "0"]
            }
        case .h264x264:
            args = ["-c:v", "libx264", "-preset", "slow"] + (settings.videoBitrate.map { ["-b:v", "\($0)k"] } ?? ["-crf", "\(18 + settings.factor * 14 / 100)"])
            if !tag.isEmpty { args += tag + ["avc1"] }
        case .hevcx265:
            args = ["-c:v", "libx265", "-preset", "medium"] + (settings.videoBitrate.map { ["-b:v", "\($0)k"] } ?? ["-crf", "\(20 + settings.factor * 14 / 100)"])
            if !tag.isEmpty { args += tag + ["hvc1"] }
        }
        if let hdr = settings.hdr {
            if let primaries = hdr.colorPrimaries { args += ["-color_primaries", primaries] }
            if let transfer = hdr.colorTransfer { args += ["-color_trc", transfer] }
            if let space = hdr.colorSpace { args += ["-colorspace", space] }
        }
        return args
    }

    /// A bitrate (kbit/s) for encoders without a quality mode, from pixels per second.
    func estimatedBitrate(_ settings: EncodeSettings) -> Int {
        let pixels = Double(settings.width * settings.height) * (settings.fpsCap ?? 30)
        let bitsPerPixel = 0.12 - Double(settings.factor) / 100 * 0.08
        return max(200, Int(pixels * bitsPerPixel / 1000))
    }

    func audioArgs(_ settings: EncodeSettings, appleAAC: Bool) -> [String] {
        if settings.removeAudio { return ["-an"] }
        var args: [String] = []
        var filters: [String] = []
        if let speed = settings.speed { filters.append(Self.atempoChain(speed)) }
        if let loudness = settings.loudness {
            // Single-pass loudnorm resamples to 192 kHz; bring it back to a rate AAC takes.
            filters.append("loudnorm=I=\(loudness):TP=-1.5:LRA=11,aresample=48000")
        }
        if !filters.isEmpty { args += ["-filter:a", filters.joined(separator: ",")] }
        if settings.container == .webm {
            return args + ["-c:a", "libopus", "-b:a", "\(settings.audioBitrate ?? 128)k"]
        }
        if settings.reencodeAudio {
            return args + ["-c:a", appleAAC ? "aac_at" : "aac", "-b:a", "\(settings.audioBitrate ?? 160)k"]
        }
        return args + ["-c:a", "copy"]
    }

    /// atempo takes 0.5...100 per instance; chain instances for anything outside.
    static func atempoChain(_ factor: Double) -> String {
        var filters: [String] = []
        var remaining = factor
        while remaining < 0.5 {
            filters.append("atempo=0.5")
            remaining /= 0.5
        }
        while remaining > 100 {
            filters.append("atempo=100")
            remaining /= 100
        }
        filters.append("atempo=\(String(format: "%.4f", remaining))")
        return filters.joined(separator: ",")
    }

    func arguments(source: URL, output: URL, settings: EncodeSettings, softwareFallback: Bool, appleAAC: Bool) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-y", "-i", source.path]
        if let mark = settings.watermark {
            // Scale the mark to its share of the output width, fade it, lay it 20 px from the edge.
            let markWidth = max(16, Int(Double(settings.width) * mark.scale))
            let position: String
            switch mark.position {
            case .topLeft: position = "20:20"
            case .topRight: position = "W-w-20:20"
            case .bottomLeft: position = "20:H-h-20"
            case .center: position = "(W-w)/2:(H-h)/2"
            case .bottomRight: position = "W-w-20:H-h-20"
            }
            let base = settings.filters.isEmpty ? "[0:v:0]null[base]" : "[0:v:0]\(settings.filters.joined(separator: ","))[base]"
            let graph = "\(base);[1:v]scale=\(markWidth):-1,format=rgba,colorchannelmixer=aa=\(String(format: "%.3f", min(1, max(0, mark.opacity))))[mark];[base][mark]overlay=\(position):format=auto:shortest=1[video]"
            args += ["-loop", "1", "-i", mark.image.path, "-filter_complex", graph, "-map", "[video]", "-shortest"]
        } else {
            args += ["-map", "0:v:0"]
            if !settings.filters.isEmpty { args += ["-vf", settings.filters.joined(separator: ",")] }
        }
        if !settings.removeAudio { args += ["-map", "0:a?"] }
        if let cap = settings.fpsCap {
            args += ["-fpsmax", String(format: "%.3f", cap)]
        } else if settings.speed == nil {
            // Screen recordings have variable frame rates; resampling to the average would drop
            // exactly the frames where something moves.
            args += ["-fps_mode", "passthrough"]
        }
        args += encoderArgs(settings, softwareFallback: softwareFallback)
        args += audioArgs(settings, appleAAC: appleAAC)
        args += ["-map_metadata", settings.strip ? "-1" : "0", "-map_chapters", settings.strip ? "-1" : "0"]
        if [.mp4, .mov, .hevc, .av1].contains(settings.container) { args += ["-movflags", "+faststart"] }
        args += ["-progress", "pipe:1", "-nostats", output.path]
        return args
    }

    /// Runs ffmpeg, falling back to the software VideoToolbox path and ffmpeg's own AAC encoder
    /// when the first attempt fails.
    func encode(
        _ source: URL, info: MediaInfo, settings: inout EncodeSettings, work: WorkFolder, progress: ProgressSink, steps: [String]
    ) async throws -> Produced {
        var steps = steps
        let output = work.file(stem: "encoded", ext: settings.container.fileExtension)
        let duration = info.duration.map { $0 / (settings.speed ?? 1) }
        let parser = FFmpegProgress(duration: duration, sink: progress)
        let options = ProcessOptions(onStdoutLine: parser.lineHandler)
        let videoToolbox = settings.codec == .h264VT || settings.codec == .hevcVT
        let attempts: [(software: Bool, appleAAC: Bool)] = videoToolbox
            ? [(false, true), (true, true), (true, false)]
            : [(false, true), (false, false)]
        var lastError: Error = EsclopError.other("ffmpeg did not run")
        for (index, attempt) in attempts.enumerated() {
            do {
                try await ProcessRunner.run(
                    .ffmpeg, arguments(source: source, output: output, settings: settings, softwareFallback: attempt.software, appleAAC: attempt.appleAAC),
                    options: options, locator: env.tools
                )
                if index > 0 { Log.video.info("ffmpeg succeeded on attempt \(index + 1)") }
                if attempt.software { steps.append("Used the software encoder") }
                steps.append("Encoded \(settings.codec.label)")
                return Produced(
                    url: output, width: settings.width, height: settings.height, duration: duration,
                    steps: steps, allowLarger: false
                )
            } catch EsclopError.cancelled {
                throw EsclopError.cancelled
            } catch {
                lastError = error
                Log.video.error("ffmpeg attempt \(index + 1) failed: \(String(describing: error), privacy: .public)")
            }
        }
        throw lastError
    }

    // MARK: GIF

    func toGIF(_ source: URL, info: MediaInfo, plan: Plan, work: WorkFolder, progress: ProgressSink) async throws -> Produced {
        guard let video = info.video else { throw EsclopError.unsupportedFile(source.lastPathComponent) }
        let fps = min(Double(env.value(EsclopSettings.gifFPS)), plan.request.fpsCap ?? 50, video.fps ?? 50)
        var width = min(env.value(EsclopSettings.gifMaxWidth), video.width)
        var cropFilter = ""
        if let crop = plan.crop {
            let target = crop.targetSize(fromWidth: video.width, height: video.height)
            if crop.cropsAspect(fromWidth: video.width, height: video.height) {
                let rect = ImageIOCodec.cropRect(for: nil, width: video.width, height: video.height, aspect: Double(target.width) / Double(target.height), smart: false)
                cropFilter = "crop=\(even(rect.width)):\(even(rect.height)):\(Int(rect.minX)):\(Int(rect.minY)),"
            }
            width = min(width, target.width)
        }
        if let factor = plan.downscale { width = max(16, Int(Double(width) * factor)) }
        let factor = plan.factor(for: .image, format: .gif, env: env)
        let quality = factor >= 50 ? 60 : 90
        let output = work.file(stem: "animation", ext: "gif")
        let fpsText = String(format: "%g", fps)
        var steps = ["Made a GIF at \(fpsText) fps, \(width) px wide"]

        if let caps = await env.images.capabilitiesIfAvailable(), caps.supports("gif.from_frames") {
            let frames = work.url.appendingPathComponent("frames", isDirectory: true)
            try Paths.ensure(frames)
            let parser = FFmpegProgress(duration: info.duration, sink: progress.scaled(0 ... 0.5))
            try await ProcessRunner.run(.ffmpeg, [
                "-hide_banner", "-nostdin", "-y", "-i", source.path,
                "-vf", "\(cropFilter)fps=\(fpsText),scale=\(width):-2:flags=lanczos",
                "-progress", "pipe:1", "-nostats", frames.appendingPathComponent("frame%05d.png").path,
            ], options: ProcessOptions(onStdoutLine: parser.lineHandler), locator: env.tools)
            let later = progress.scaled(0.5 ... 1)
            try await env.images.call("gif.from_frames", output: output, params: [
                "fps": .double(fps), "quality": .int(quality), "width": .int(width), "frames_dir": .string(frames.path),
            ], progress: { later($0) })
            steps.append("Encoded with gifski at quality \(quality)")
        } else {
            let parser = FFmpegProgress(duration: info.duration, sink: progress)
            try await ProcessRunner.run(.ffmpeg, [
                "-hide_banner", "-nostdin", "-y", "-i", source.path,
                "-vf", "\(cropFilter)fps=\(fpsText),scale=\(width):-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4",
                "-loop", "0", "-progress", "pipe:1", "-nostats", output.path,
            ], options: ProcessOptions(onStdoutLine: parser.lineHandler), locator: env.tools)
            steps.append("Encoded with ffmpeg's palette filters")
            if env.tools.locate(.gifsicle) != nil {
                let optimised = work.file(stem: "animation-optimised", ext: "gif")
                if (try? await ProcessRunner.run(.gifsicle, Curves(factor).gifsicleArgs + ["--output", optimised.path, output.path], locator: env.tools)) != nil,
                   fileSize(optimised) > 0, fileSize(optimised) < fileSize(output)
                {
                    try FileManager.default.removeItem(at: output)
                    try FileManager.default.moveItem(at: optimised, to: output)
                    steps.append("Optimised with gifsicle")
                }
            }
        }
        let info = ImageInfo.probe(output)
        return Produced(url: output, width: info?.width, height: info?.height, duration: nil, steps: steps, allowLarger: true)
    }

    // MARK: Remove audio (no re-encode)

    func removeAudio(_ source: URL, plan: Plan, work: WorkFolder, progress: ProgressSink) async throws -> Produced {
        let info = try await MediaInfo.probe(source, tools: env.tools)
        guard info.audio != nil else { throw EsclopError.alreadySmaller }
        let output = work.file(stem: "muted", ext: source.pathExtension.isEmpty ? "mp4" : source.pathExtension)
        // Video only: iPhone data tracks (mebx, timecode) do not survive a copy into MOV/MP4.
        var args = ["-hide_banner", "-nostdin", "-y", "-i", source.path, "-map", "0:v", "-c", "copy"]
        args += ["-map_metadata", plan.strip ? "-1" : "0"]
        if ["mp4", "mov", "m4v"].contains(source.pathExtension.lowercased()) { args += ["-movflags", "+faststart"] }
        args.append(output.path)
        try await ProcessRunner.run(.ffmpeg, args, locator: env.tools)
        return Produced(
            url: output, width: info.video?.width, height: info.video?.height, duration: info.duration,
            steps: ["Removed audio"], allowLarger: false
        )
    }

    // MARK: Fit under size

    /// Bitrate from the duration, VideoToolbox first with up to three corrections, smaller
    /// frames when the bitrate gets too thin for the resolution, AV1 as the last resort.
    func fit(_ source: URL, under target: Int, plan: Plan, work: WorkFolder, progress: ProgressSink) async throws -> Produced {
        let info = try await MediaInfo.probe(source, tools: env.tools)
        guard let video = info.video, let rawDuration = info.duration, rawDuration > 0 else {
            throw EsclopError.unsupportedFile("Cannot read the duration of \(source.lastPathComponent)")
        }
        var container = targetContainer(for: source, sourceFormat: OutputFormat.of(url: source), plan: plan)
        if container == .gif || container == .gifVideo || container == .webm { container = container == .webm ? .webm : .mp4 }
        var steps: [String] = []
        var settings = try await videoSettings(for: video, info: info, container: container, plan: plan, steps: &steps)
        let duration = rawDuration / (settings.speed ?? 1)

        // Container overhead takes a few percent; audio takes its share unless it is tiny.
        let totalKbps = Double(target) * 8 / duration / 1000 * 0.92
        var audioKbps = settings.removeAudio ? 0 : min(96, max(32, Int(totalKbps * 0.12)))
        if !settings.removeAudio, totalKbps - Double(audioKbps) < 80 {
            settings.removeAudio = true
            audioKbps = 0
            steps.append("Removed audio to make room")
        }
        if !settings.removeAudio {
            settings.reencodeAudio = true
            settings.audioBitrate = audioKbps
        }
        var videoKbps = max(30, Int(totalKbps) - audioKbps)

        // Under about 0.04 bits per pixel the picture falls apart; shrink the frame instead.
        let fps = settings.fpsCap ?? video.fps ?? 30
        let pixels = Double(settings.width * settings.height)
        let neededPixels = Double(videoKbps * 1000) / (0.04 * fps)
        if neededPixels < pixels {
            let scale = max(0.2, sqrt(neededPixels / pixels))
            settings.width = even(Double(settings.width) * scale)
            settings.height = even(Double(settings.height) * scale)
            settings.filters.removeAll { $0.hasPrefix("scale=") }
            settings.filters.append("scale=\(settings.width):\(settings.height):flags=lanczos")
            steps.append("Resized to \(settings.width)x\(settings.height) to fit")
        }

        let codecs: [Codec] = settings.codec == .vp9 ? [.vp9] : [settings.codec, .av1].reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        var smallest = Int.max
        for codec in codecs {
            settings.codec = codec
            var kbps = videoKbps
            for round in 0 ..< 3 {
                settings.videoBitrate = kbps
                let folder = try WorkFolder(root: work.url)
                let produced = try await encode(source, info: info, settings: &settings, work: folder, progress: progress.scaled(Double(round) / 3 ... Double(round + 1) / 3), steps: steps)
                let size = fileSize(produced.url)
                smallest = min(smallest, size)
                if size <= target {
                    var result = produced
                    result.allowLarger = true
                    result.steps.append("Fit under \(ByteFormat.string(target)) at \(kbps) kbit/s")
                    return result
                }
                kbps = max(20, Int(Double(kbps) * Double(target) / Double(size) * 0.93))
            }
            videoKbps = max(20, Int(Double(videoKbps) * 0.9))
            steps.append("\(codec.label) could not fit; trying the next encoder")
        }
        throw EsclopError.other("Could not fit under \(ByteFormat.string(target)); the smallest attempt was \(ByteFormat.string(smallest))")
    }

    // MARK: Metadata

    func stripMetadata(_ source: URL, work: WorkFolder) async throws -> Produced {
        let output = work.file(stem: "stripped", ext: source.pathExtension.isEmpty ? "mp4" : source.pathExtension)
        var args = ["-hide_banner", "-nostdin", "-y", "-i", source.path, "-map", "0:v", "-map", "0:a?", "-c", "copy", "-map_metadata", "-1", "-map_chapters", "-1"]
        if ["mp4", "mov", "m4v"].contains(source.pathExtension.lowercased()) { args += ["-movflags", "+faststart"] }
        args.append(output.path)
        try await ProcessRunner.run(.ffmpeg, args, locator: env.tools)
        return Produced(url: output, width: nil, height: nil, duration: nil, steps: ["Removed metadata"], allowLarger: true)
    }
}

func even(_ value: Double) -> Int {
    max(2, Int(value / 2) * 2)
}

/// What the ffmpeg in use can encode, asked once per process.
actor FFmpegCapabilities {
    static let shared = FFmpegCapabilities()
    private var cached: [String: Set<String>] = [:]

    func encoders(tools: ToolLocator) async -> Set<String> {
        guard let ffmpeg = tools.locate(.ffmpeg) else { return [] }
        if let known = cached[ffmpeg.path] { return known }
        let output = (try? await ProcessRunner.run(executable: ffmpeg, arguments: ["-hide_banner", "-encoders"], locator: tools))?.stdoutString ?? ""
        let names = Set(output.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0].count == 6 else { return nil }
            return String(parts[1])
        })
        cached[ffmpeg.path] = names
        return names
    }
}
