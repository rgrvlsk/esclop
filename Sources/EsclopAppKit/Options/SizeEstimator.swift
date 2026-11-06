// SPDX-License-Identifier: GPL-3.0-or-later
//
// "≈ 410 kB" before a choice is applied (DESIGN.md › Options popover). Estimates are computed
// in the background when the popover asks for them, two at a time, cancelled when it closes and
// cached per file (path, size, modification date) and choice, so they never block the UI.
//
// - Images and PDFs up to 25 MB: the engine really encodes the original into a scratch folder,
//   so the estimate is the size the choice will produce with the current settings.
// - Video and audio: a bitrate model (bits per pixel per frame for each codec, kbit/s for audio),
//   calibrated by the result the card already has, so the systematic error of the model cancels.

import AVFoundation
import EsclopCore
import EsclopIPC
import Foundation

/// What an estimate is for: the choice plus the Size tab's changes.
public struct EstimateRequest: Hashable, Sendable {
    public var choice: OptimiseChoice
    public var downscale: Double?
    public var crop: CropSize?

    public init(choice: OptimiseChoice, downscale: Double? = nil, crop: CropSize? = nil) {
        self.choice = choice
        self.downscale = downscale
        self.crop = crop
    }

    func apply(to job: inout OptimisationJob) {
        choice.apply(to: &job.request)
        if let downscale, downscale < 1 { job.request.downscale = downscale }
        if let crop { job.request.crop = crop }
    }
}

/// The parts of a video or audio file the model needs.
public struct MediaFacts: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var fps: Double
    public var duration: Double
    public var hasAudio: Bool

    public init(width: Int, height: Int, fps: Double, duration: Double, hasAudio: Bool) {
        self.width = width
        self.height = height
        self.fps = fps
        self.duration = duration
        self.hasAudio = hasAudio
    }

    static func read(_ url: URL) async -> MediaFacts? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return nil }
        let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard let video = try? await asset.loadTracks(withMediaType: .video).first else {
            return MediaFacts(width: 0, height: 0, fps: 0, duration: duration, hasAudio: !audio.isEmpty)
        }
        let size = (try? await video.load(.naturalSize)) ?? .zero
        let transform = (try? await video.load(.preferredTransform)) ?? .identity
        let upright = size.applying(transform)
        let fps = Double((try? await video.load(.nominalFrameRate)) ?? 30)
        return MediaFacts(width: Int(abs(upright.width)), height: Int(abs(upright.height)), fps: fps > 0 ? fps : 30, duration: duration, hasAudio: !audio.isEmpty)
    }
}

/// The bitrate model for video and audio, in bytes. Pure, so it is tested on its own.
public enum SizeModel {
    /// Bits per pixel per frame at adaptive compression, measured on screen recordings and
    /// phone video with the bundled encoders.
    static func bitsPerPixel(format: OutputFormat?, encoder: VideoEncoder?) -> Double {
        switch format {
        case .hevc: return 0.05
        case .av1: return 0.04
        case .webm: return 0.06
        default:
            switch encoder {
            case .hevcVideoToolbox, .hevcSoftware: return 0.05
            case .av1: return 0.04
            case .vp9: return 0.06
            default: return 0.09
            }
        }
    }

    static func compressionScale(_ choice: OptimiseChoice) -> Double {
        if let quality = choice.quality { return pow(2, Double(quality - 70) / 15) }
        switch choice.compression {
        case .adaptive: return 1
        case .lossless: return 3
        case .aggressive: return 0.6
        }
    }

    public static func video(_ facts: MediaFacts, _ request: EstimateRequest, input: OutputFormat?) -> Double {
        let choice = request.choice
        var width = Double(facts.width), height = Double(facts.height)
        if let region = request.crop?.region(inWidth: facts.width, height: facts.height) {
            width = region.width
            height = region.height
        }
        if let scale = request.downscale {
            width *= scale
            height *= scale
        }
        let speed = choice.playbackSpeed ?? 1
        let duration = facts.duration / max(0.1, speed)
        let format = choice.format ?? input
        if format == .gifVideo || format == .gif {
            // GIF: palette frames, about a byte for every eight pixels at 15 fps.
            return width * height * min(15, facts.fps) * duration / 8
        }
        let fps = min(facts.fps, choice.fps ?? facts.fps)
        var bytes = bitsPerPixel(format: format, encoder: choice.videoEncoder) * compressionScale(choice) * width * height * fps * duration / 8
        if facts.hasAudio, !choice.removeAudio { bytes += Double(choice.audioBitrate ?? 128) * 1000 / 8 * duration }
        return bytes
    }

    public static func audio(_ facts: MediaFacts, _ request: EstimateRequest, input: OutputFormat?) -> Double {
        let choice = request.choice
        let duration = facts.duration / max(0.1, choice.playbackSpeed ?? 1)
        let kbps: Double
        switch choice.format ?? input {
        case .flac: kbps = 700
        case .wav: kbps = 1411
        case .opus: kbps = Double(choice.audioBitrate ?? 96)
        default: kbps = Double(choice.audioBitrate ?? 160) * (choice.compression == .aggressive ? 0.6 : 1)
        }
        return kbps * 1000 / 8 * duration
    }

    /// Scales the model by how far it was off for the result already made.
    public static func calibrated(_ estimate: Double, model reference: Double?, actual: Int?) -> Int {
        guard let reference, reference > 0, let actual, actual > 0 else { return Int(estimate.rounded()) }
        let scale = min(4, max(0.25, Double(actual) / reference))
        return Int((estimate * scale).rounded())
    }
}

public actor SizeEstimator {
    struct Key: Hashable {
        var path: String
        var bytes: Int
        var modified: Date
        var origin: RequestOrigin
        var request: EstimateRequest
    }

    private let executor: JobExecutor
    private let scratch: URL
    private var cache: [Key: Int] = [:]
    private var running: [Key: Task<Int?, Never>] = [:]
    private var facts: [String: MediaFacts] = [:]
    private var free = 2
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Real encodes run for images and for PDFs up to this size.
    static let realEncodeLimit = 25_000_000

    public init(executor: JobExecutor, scratch: URL = Paths.temporary.appendingPathComponent("estimates", isDirectory: true)) {
        self.executor = executor
        self.scratch = scratch
    }

    /// The cached estimate, without starting any work.
    public func cached(_ original: URL, origin: RequestOrigin, request: EstimateRequest) -> Int? {
        key(original, origin: origin, request: request).flatMap { cache[$0] }
    }

    /// Bytes `request` would produce from `original`. `reference` is the card's current result
    /// (its request and size), used to calibrate the model for video and audio.
    public func estimate(
        _ original: URL, origin: RequestOrigin, request: EstimateRequest, reference: (EstimateRequest, Int)? = nil
    ) async -> Int? {
        guard let key = key(original, origin: origin, request: request) else { return nil }
        if let known = cache[key] { return known }
        if let task = running[key] { return await task.value }
        let task = Task { await self.compute(original, key: key, reference: reference) }
        running[key] = task
        let value = await task.value
        running[key] = nil
        if let value { cache[key] = value }
        return value
    }

    /// Stops the work started for `original` (the popover closed).
    public func cancel(_ original: URL) {
        for (key, task) in running where key.path == original.standardizedFileURL.path { task.cancel() }
    }

    private func key(_ original: URL, origin: RequestOrigin, request: EstimateRequest) -> Key? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: original.path) else { return nil }
        let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        return Key(path: original.standardizedFileURL.path, bytes: bytes, modified: modified, origin: origin, request: request)
    }

    private func compute(_ original: URL, key: Key, reference: (EstimateRequest, Int)?) async -> Int? {
        let kind = MediaKind.of(original)
        let input = OutputFormat.of(original)
        switch kind {
        case .image?:
            return await encode(original, key: key)
        case .pdf?:
            return key.bytes <= Self.realEncodeLimit ? await encode(original, key: key) : nil
        case .video?, .audio?:
            guard let facts = await mediaFacts(original) else { return nil }
            let model: (EstimateRequest) -> Double = kind == .video
                ? { SizeModel.video(facts, $0, input: input) }
                : { SizeModel.audio(facts, $0, input: input) }
            // An explicit audio bitrate is its own best estimate: the default result picked its
            // bitrate from the content, so scaling by it would carry the wrong correction.
            let comparable = reference.map { $0.0.choice.audioBitrate == key.request.choice.audioBitrate } ?? false
            return SizeModel.calibrated(model(key.request), model: comparable ? reference.map { model($0.0) } : nil, actual: comparable ? reference?.1 : nil)
        default:
            return nil
        }
    }

    private func mediaFacts(_ url: URL) async -> MediaFacts? {
        if let known = facts[url.path] { return known }
        let read = await MediaFacts.read(url)
        facts[url.path] = read
        return read
    }

    /// Runs the engine for real into a scratch folder, then throws the output away.
    private func encode(_ original: URL, key: Key) async -> Int? {
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return nil }
        let folder = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var request = OptimisationRequest(sources: [original], origin: key.origin, location: .path(folder.path + "/"), showResultUI: false)
        request.quality = .normal
        var job = OptimisationJob(request: request, operation: .optimise)
        key.request.apply(to: &job)
        do {
            let result = try await executor.process(original, job: job) { _ in }
            return result.bytesAfter
        } catch EsclopError.alreadySmaller {
            return key.bytes
        } catch {
            return nil
        }
    }

    private func acquire() async {
        if free > 0 {
            free -= 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume() }
    }
}
