// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import EsclopCore
@testable import EsclopIPC
import Foundation

/// A temporary folder removed when the value goes away.
final class TempDir: @unchecked Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("esclop-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String, bytes: Int = 1000) -> URL {
        let file = url.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data(repeating: 0x41, count: bytes))
        return file
    }

    /// A PDF with pages of the given sizes in points.
    func pdf(_ name: String, pages: [CGSize]) -> URL {
        let file = url.appendingPathComponent(name)
        var box = CGRect(origin: .zero, size: pages.first ?? CGSize(width: 600, height: 800))
        let context = CGContext(file as CFURL, mediaBox: &box, nil)!
        for size in pages {
            var media = CGRect(origin: .zero, size: size)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &media, count: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(info)
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 20, y: 20, width: size.width - 40, height: size.height - 40))
            context.endPDFPage()
        }
        context.closePDF()
        return file
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Records what it was asked and returns a result that halves the file.
final class FakeEngine: OptimisationEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }

    private func record(_ call: String, _ source: URL, _ request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void = { _ in }) -> OptimisationResult {
        lock.lock(); _calls.append(call); lock.unlock()
        progress(OptimisationProgress(requestID: request.id, source: source, fraction: 0.5, message: call))
        let size = ((try? FileManager.default.attributesOfItem(atPath: source.path))?[.size] as? NSNumber)?.intValue ?? 0
        return OptimisationResult(source: source, output: source, kind: MediaKind.of(source) ?? .image, bytesBefore: size, bytesAfter: size / 2,
                                  startedAt: Date(), finishedAt: Date(), steps: [call])
    }

    func optimise(_ source: URL, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult { record("optimise", source, request, progress: progress) }
    func convert(_ source: URL, to format: OutputFormat, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult { record("convert:\(format.rawValue)", source, request) }
    func downscale(_ source: URL, factor: Double, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult { record("downscale:\(factor)", source, request) }
    func crop(_ source: URL, to size: CropSize, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult { record("crop:\(size.width ?? 0)x\(size.height ?? 0)", source, request) }
    func fit(_ source: URL, underBytes: Int, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult { record("fit:\(underBytes)", source, request) }
    func stripMetadata(_ source: URL, request: OptimisationRequest) async throws -> OptimisationResult { record("strip", source, request) }
    func supports(_ url: URL) -> Bool { true }
}

func sampleResult(_ name: String = "a.png") -> OptimisationResult {
    OptimisationResult(
        source: URL(fileURLWithPath: "/tmp/\(name)"), output: URL(fileURLWithPath: "/tmp/out-\(name)"),
        backup: URL(fileURLWithPath: "/tmp/backup-\(name)"), kind: .image, bytesBefore: 2000, bytesAfter: 500,
        width: 100, height: 50, duration: nil, startedAt: Date(timeIntervalSinceReferenceDate: 1000.25),
        finishedAt: Date(timeIntervalSinceReferenceDate: 1001.75), steps: ["pngquant", "oxipng"]
    )
}

/// Encodes, decodes and encodes again; equal bytes mean nothing was lost.
func roundTrips<T: Codable & Sendable>(_ body: T) throws -> Bool {
    let first = try IPCEnvelope(replyPort: "port", body: body).encoded()
    let decoded = try IPCEnvelope<T>.decode(first)
    let second = try IPCEnvelope(id: decoded.id, replyPort: decoded.replyPort, body: decoded.body).encoded()
    return first == second && decoded.replyPort == "port"
}
