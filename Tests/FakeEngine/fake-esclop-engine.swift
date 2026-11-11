// SPDX-License-Identifier: GPL-3.0-or-later
//
// A stand-in for `esclop-engine serve` used by the tests until the Rust engine exists. It speaks
// the JSON-lines protocol of docs/engine-protocol.md and does the pixel work with ImageIO, which
// is enough to exercise the Swift client: capabilities, out-of-order replies, progress, errors,
// cancellation and crashes. It is compiled by the test suite (not part of any target).
//
// Supported ops: hello, probe, png.optimise, jpeg.optimise, resize, crop, convert (png, jpeg,
// gif, avif when ImageIO writes it), metadata.strip, gif.from_frames, avif.encode (same
// condition), plus test hooks: sleep {seconds}, crash, and FAKE_ENGINE_BARE_HELLO=1 for the
// bare hello reply.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

setvbuf(stdout, nil, _IOLBF, 0)

let outputLock = NSLock()
let stateLock = NSLock()
var cancelled = Set<String>()
/// Each request's stage: 0 queued, 1 running, 2 answered while queued (by a cancel).
var stages: [String: Int] = [:]
let workers = DispatchSemaphore(value: Int(ProcessInfo.processInfo.environment["FAKE_ENGINE_WORKERS"] ?? "") ?? 1000)
let work = DispatchQueue(label: "fake-engine", attributes: .concurrent)
let canWriteAVIF = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains("public.avif")

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return }
    outputLock.lock()
    print(text)
    fflush(stdout)
    outputLock.unlock()
}

func fail(_ id: String, _ code: String, _ message: String) {
    emit(["id": id, "ok": false, "error": ["code": code, "message": message]])
}

func size(_ path: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
}

func load(_ path: String) -> (CGImage, [CFString: Any], String)? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let type = CGImageSourceGetType(source) as String?
    else { return nil }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    return (image, properties, type)
}

func eightBit(_ image: CGImage, width: Int? = nil, height: Int? = nil) -> CGImage? {
    let w = width ?? image.width
    let h = height ?? image.height
    guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return context.makeImage()
}

func write(_ image: CGImage, to path: String, format: String, quality: Double?, properties: [CFString: Any]?) -> Bool {
    let type: String
    switch format {
    case "png": type = "public.png"
    case "jpeg", "jpg": type = "public.jpeg"
    case "gif": type = "com.compuserve.gif"
    case "avif": type = "public.avif"
    default: return false
    }
    guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, type as CFString, 1, nil) else { return false }
    var options = properties ?? [:]
    if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
    CGImageDestinationAddImage(destination, image, options as CFDictionary)
    return CGImageDestinationFinalize(destination)
}

func keptMetadata(_ properties: [CFString: Any], strip: Bool) -> [CFString: Any] {
    if strip { return [kCGImagePropertyOrientation: properties[kCGImagePropertyOrientation] ?? 1] }
    var kept: [CFString: Any] = [:]
    for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyOrientation] {
        if let value = properties[key] { kept[key] = value }
    }
    return kept
}

func formatName(_ type: String) -> String {
    switch type {
    case "public.png": return "png"
    case "public.jpeg": return "jpeg"
    case "com.compuserve.gif": return "gif"
    case "public.avif": return "avif"
    default: return type
    }
}

func success(_ id: String, input: String?, output: String, width: Int, height: Int, format: String, extra: [String: Any] = [:]) {
    var result: [String: Any] = [
        "bytes_before": input.map(size) ?? 0, "bytes_after": size(output),
        "width": width, "height": height, "format": format,
    ]
    for (key, value) in extra { result[key] = value }
    emit(["id": id, "ok": true, "result": result])
}

func handle(_ id: String, _ op: String, _ input: String?, _ output: String?, _ params: [String: Any]) {
    let strip = params["strip"] as? Bool ?? false
    switch op {
    case "probe":
        guard let input, let (image, _, type) = load(input) else { return fail(id, "decode", "cannot decode") }
        emit(["id": id, "ok": true, "result": ["width": image.width, "height": image.height, "format": formatName(type), "bytes_before": size(input), "bytes_after": size(input)]])

    case "png.optimise":
        guard let input, let output, let (image, properties, type) = load(input) else { return fail(id, "not_found", "missing input") }
        guard type == "public.png" else { return fail(id, "unsupported", "not a PNG") }
        emit(["id": id, "event": "progress", "fraction": 0.5])
        guard let flat = eightBit(image), write(flat, to: output, format: "png", quality: nil, properties: keptMetadata(properties, strip: strip)) else {
            return fail(id, "encode", "png write failed")
        }
        if size(output) >= size(input) {
            try? FileManager.default.removeItem(atPath: output)
            return fail(id, "already_smaller", "already as small as it gets")
        }
        success(id, input: input, output: output, width: image.width, height: image.height, format: "png")

    case "jpeg.optimise":
        guard let input, let output, let (image, properties, type) = load(input) else { return fail(id, "not_found", "missing input") }
        guard type == "public.jpeg" else { return fail(id, "unsupported", "not a JPEG") }
        let quality = (params["quality"] as? Double ?? 85) / 100
        guard write(image, to: output, format: "jpeg", quality: quality * 0.6, properties: keptMetadata(properties, strip: strip)) else {
            return fail(id, "encode", "jpeg write failed")
        }
        if size(output) >= size(input) {
            try? FileManager.default.removeItem(atPath: output)
            return fail(id, "already_smaller", "already as small as it gets")
        }
        success(id, input: input, output: output, width: image.width, height: image.height, format: "jpeg")

    case "resize", "crop", "convert", "metadata.strip", "avif.encode":
        guard let input, let output, let (loaded, properties, type) = load(input) else { return fail(id, "not_found", "missing input") }
        var image = loaded
        if op == "crop" {
            let rect = CGRect(x: params["x"] as? Double ?? 0, y: params["y"] as? Double ?? 0,
                              width: params["width"] as? Double ?? Double(image.width), height: params["height"] as? Double ?? Double(image.height))
            guard let cropped = image.cropping(to: rect) else { return fail(id, "invalid_params", "crop outside the image") }
            image = cropped
        }
        if op == "resize" {
            var width = params["width"] as? Int
            var height = params["height"] as? Int
            if let scale = params["scale"] as? Double {
                width = Int(Double(image.width) * scale)
                height = Int(Double(image.height) * scale)
            }
            guard let resized = eightBit(image, width: width, height: height) else { return fail(id, "encode", "resize failed") }
            image = resized
        }
        let format = op == "avif.encode" ? "avif" : (params["format"] as? String ?? formatName(type))
        guard ["png", "jpeg", "gif"].contains(format) || (format == "avif" && canWriteAVIF) else {
            return fail(id, "unsupported", "fake engine cannot write \(format)")
        }
        let quality = (params["quality"] as? Double).map { $0 / 100 }
        guard write(image, to: output, format: format, quality: quality ?? (format == "jpeg" ? 0.9 : nil),
                    properties: keptMetadata(properties, strip: op == "metadata.strip" || strip)) else {
            return fail(id, "encode", "write failed")
        }
        success(id, input: input, output: output, width: image.width, height: image.height, format: format)

    case "gif.from_frames":
        guard let output, let dir = params["frames_dir"] as? String else { return fail(id, "invalid_params", "frames_dir missing") }
        let frames = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
        guard !frames.isEmpty,
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, "com.compuserve.gif" as CFString, frames.count, nil)
        else { return fail(id, "invalid_params", "no frames") }
        let fps = params["fps"] as? Double ?? 10
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        var last: CGImage?
        for (index, frame) in frames.enumerated() {
            guard let (image, _, _) = load(dir + "/" + frame) else { continue }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary)
            last = image
            emit(["id": id, "event": "progress", "fraction": Double(index + 1) / Double(frames.count)])
        }
        guard CGImageDestinationFinalize(destination), let last else { return fail(id, "encode", "gif write failed") }
        success(id, input: nil, output: output, width: last.width, height: last.height, format: "gif")

    case "sleep":
        let seconds = params["seconds"] as? Double ?? 1
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            stateLock.lock()
            let stop = cancelled.contains(id)
            stateLock.unlock()
            // `stuck`: a step that never looks at the cancel flag.
            if stop, params["stuck"] as? Bool != true { return fail(id, "cancelled", "cancelled") }
            Thread.sleep(forTimeInterval: 0.02)
        }
        emit(["id": id, "ok": true, "result": ["slept": seconds]])

    case "crash":
        FileHandle.standardError.write(Data("fake engine crashing on purpose\n".utf8))
        exit(3)

    default:
        fail(id, "unsupported", "unknown op \(op)")
    }
}

var ops = ["hello", "cancel", "probe", "png.optimise", "jpeg.optimise", "resize", "crop", "convert", "metadata.strip", "gif.from_frames", "sleep", "crash"]
var encodable = ["png", "jpeg", "gif"]
if canWriteAVIF {
    ops.append("avif.encode")
    encodable.append("avif")
}

while let line = readLine() {
    guard let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let op = message["op"] as? String
    else { continue }
    let id = (message["id"] as? String) ?? (message["id"] as? Int).map(String.init) ?? ""
    switch op {
    case "hello":
        let caps: [String: Any] = ["version": "fake-1", "ops": ops, "features": ["encode": encodable]]
        if ProcessInfo.processInfo.environment["FAKE_ENGINE_BARE_HELLO"] != nil {
            // The protocol document's short form: no id, no envelope, sent a little late.
            work.asyncAfter(deadline: .now() + 0.2) { emit(caps) }
        } else {
            emit(["id": id, "ok": true, "result": caps])
        }
    case "cancel":
        // A request still queued is answered at once; a running one gets the flag.
        stateLock.lock()
        if stages[id] == 0 {
            stages[id] = 2
            stateLock.unlock()
            fail(id, "cancelled", "cancelled")
        } else {
            cancelled.insert(id)
            stateLock.unlock()
        }
    default:
        let input = message["input"] as? String
        let output = message["output"] as? String
        let params = message["params"] as? [String: Any] ?? [:]
        stateLock.lock()
        stages[id] = 0
        stateLock.unlock()
        work.async {
            // FAKE_ENGINE_WORKERS: at most that many run at once, like the engine's pool.
            workers.wait()
            defer { workers.signal() }
            stateLock.lock()
            let answered = stages[id] == 2
            stages[id] = answered ? nil : 1
            stateLock.unlock()
            if answered { return }
            emit(["id": id, "event": "started", "fraction": 0.0])
            handle(id, op, input, output, params)
            stateLock.lock()
            stages[id] = nil
            stateLock.unlock()
        }
    }
}
