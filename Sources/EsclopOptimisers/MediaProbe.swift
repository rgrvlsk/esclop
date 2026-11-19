// SPDX-License-Identifier: GPL-3.0-or-later
//
// Video and audio facts from ffprobe's JSON, and ffmpeg's `-progress` output turned into a
// fraction.

import EsclopCore
import Foundation

struct MediaInfo: Sendable {
    struct Video: Sendable {
        var codec: String
        /// Displayed size (rotation applied).
        var width: Int
        var height: Int
        var fps: Double?
        var pixelFormat: String?
        var colorTransfer: String?
        var colorPrimaries: String?
        var colorSpace: String?

        var isHDR: Bool { ["smpte2084", "arib-std-b67"].contains(colorTransfer ?? "") }
    }

    struct Audio: Sendable {
        var codec: String
        var sampleRate: Double?
        /// kbit/s
        var bitrate: Int?
        var channels: Int?
        /// PCM and lossless sources only (lossy codecs have no bit depth).
        var bitsPerSample: Int?
    }

    struct Stream: Sendable {
        /// ffprobe's `codec_type`: video, audio, subtitle, data, attachment.
        var type: String
        var codec: String
        /// Cover art (a video stream that is one picture).
        var attachedPicture: Bool
    }

    var duration: Double?
    /// kbit/s for the whole file.
    var bitrate: Int?
    var video: Video?
    var audio: Audio?
    var hasCoverArt: Bool
    var audioStreamCount: Int
    /// Every stream, in file order.
    var streams: [Stream] = []

    func streams(_ type: String) -> [Stream] { streams.filter { $0.type == type && !$0.attachedPicture } }

    static func probe(_ url: URL, tools: ToolLocator) async throws -> MediaInfo {
        let kind = MediaKind.of(url) ?? .video
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                .ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path],
                options: ProcessOptions(timeout: 60), locator: tools
            )
        } catch let EsclopError.toolFailed(tool, code, stderr) {
            // The person gets a plain message; the tool's words stay in the log.
            Log.engine.error("\(tool, privacy: .public) could not read \(url.lastPathComponent, privacy: .private) (\(code)): \(stderr, privacy: .private)")
            throw EsclopError.unreadable(kind: kind)
        }
        let json = JSONValue(parsing: result.stdoutString)
        guard let format = json["format"]?.objectValue else {
            throw EsclopError.unreadable(kind: kind)
        }
        let streams = json["streams"]?.arrayValue?.compactMap(\.objectValue) ?? []
        func number(_ value: JSONValue?) -> Double? {
            value?.doubleValue ?? value?.stringValue.flatMap(Double.init)
        }
        func rate(_ value: JSONValue?) -> Double? {
            guard let text = value?.stringValue else { return nil }
            let parts = text.split(separator: "/").compactMap { Double($0) }
            guard parts.count == 2, parts[1] > 0, parts[0] > 0 else { return Double(text) }
            return parts[0] / parts[1]
        }

        var info = MediaInfo(
            duration: number(format["duration"]),
            bitrate: number(format["bit_rate"]).map { Int($0 / 1000) },
            video: nil, audio: nil, hasCoverArt: false, audioStreamCount: 0
        )
        for stream in streams {
            let type = stream["codec_type"]?.stringValue
            let attached = stream["disposition"]?["attached_pic"]?.intValue == 1
            info.streams.append(Stream(type: type ?? "unknown", codec: stream["codec_name"]?.stringValue ?? "unknown", attachedPicture: attached))
            if type == "video", attached {
                info.hasCoverArt = true
            } else if type == "video", info.video == nil {
                var width = stream["width"]?.intValue ?? 0
                var height = stream["height"]?.intValue ?? 0
                let rotation = Self.rotation(stream)
                if abs(rotation) % 180 == 90 { swap(&width, &height) }
                let fps = rate(stream["avg_frame_rate"]) ?? rate(stream["r_frame_rate"])
                info.video = Video(
                    codec: stream["codec_name"]?.stringValue ?? "unknown", width: width, height: height,
                    fps: fps.flatMap { $0 > 0 && $0 < 1000 ? $0 : nil },
                    pixelFormat: stream["pix_fmt"]?.stringValue,
                    colorTransfer: stream["color_transfer"]?.stringValue,
                    colorPrimaries: stream["color_primaries"]?.stringValue,
                    colorSpace: stream["color_space"]?.stringValue
                )
            } else if type == "audio" {
                info.audioStreamCount += 1
                if info.audio == nil {
                    info.audio = Audio(
                        codec: stream["codec_name"]?.stringValue ?? "unknown",
                        sampleRate: number(stream["sample_rate"]),
                        bitrate: number(stream["bit_rate"]).map { Int($0 / 1000) },
                        channels: stream["channels"]?.intValue,
                        bitsPerSample: [stream["bits_per_raw_sample"], stream["bits_per_sample"]]
                            .lazy.compactMap { number($0).map(Int.init) }.first { $0 > 0 }
                    )
                }
            }
        }
        if info.audio?.bitrate == nil, info.video == nil, let total = info.bitrate {
            info.audio?.bitrate = total
        }
        return info
    }

    private static func rotation(_ stream: [String: JSONValue]) -> Int {
        if let sideData = stream["side_data_list"]?.arrayValue {
            for item in sideData {
                if let rotation = item["rotation"]?.intValue { return rotation }
            }
        }
        if let text = stream["tags"]?["rotate"]?.stringValue, let rotation = Int(text) { return rotation }
        return 0
    }
}

/// Reads ffmpeg's `-progress pipe:1` key=value lines and reports a fraction of `duration`.
final class FFmpegProgress: @unchecked Sendable {
    private let duration: Double
    private let sink: ProgressSink
    private let lock = NSLock()
    private var last = -1.0
    private var lastTime = -1.0

    init(duration: Double?, sink: ProgressSink) {
        self.duration = duration ?? 0
        self.sink = sink
    }

    func handle(_ line: String) {
        guard duration > 0, line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms="),
              let micros = Double(line.split(separator: "=").last ?? ""), micros >= 0
        else { return }
        let fraction = min(0.99, micros / 1_000_000 / duration)
        lock.lock()
        let report = fraction - last >= 0.01
        if report { last = fraction }
        lock.unlock()
        if report { sink(fraction) }
    }

    var lineHandler: @Sendable (String) -> Void {
        { [self] line in handle(line) }
    }

    /// True when `line` carries an output time other than the one before (a retry starts again
    /// from zero, which counts too).
    func advanced(_ line: String) -> Bool {
        guard line.hasPrefix("out_time_us="), let micros = Double(line.dropFirst("out_time_us=".count)) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard micros != lastTime else { return false }
        lastTime = micros
        return true
    }

    // ponytail: one limit for every ffmpeg run. ffmpeg prints its progress twice a second, so
    // five minutes without the output time moving means it hangs (a read that never returns, a
    // stuck encoder). Ceiling: the palette GIF path writes nothing until it has read the whole
    // video; a per-run limit if a GIF of a very long video ever needs more.
    static let stallLimit: TimeInterval = 300

    /// Options for an ffmpeg run with `-progress pipe:1`: progress to the sink, and the run
    /// stopped when the output time stops moving for `stallLimit`.
    var options: ProcessOptions {
        ProcessOptions(onStdoutLine: lineHandler, stallTimeout: Self.stallLimit, madeProgress: { [self] in advanced($0) })
    }
}
