// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EsclopCore
import EsclopIPC
import EsclopMCP
import EsclopPipelines
@testable import EsclopAppKit
import Foundation

/// A temporary folder removed when the value goes away.
final class TempDir: @unchecked Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("esclop-app-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// A real PNG, for what checks a file's bytes.
    func png(_ name: String) -> URL {
        let file = url.appendingPathComponent(name)
        try? pngData().write(to: file)
        return file
    }

    func file(_ name: String, bytes: Int = 100_000) -> URL {
        let file = url.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data(repeating: 0x41, count: bytes))
        return file
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// A settings suite of its own, emptied when the value goes away.
final class TestSettings: @unchecked Sendable {
    let store = SettingsStore(suiteName: "dev.esclop.app-tests.\(UUID().uuidString)")
    deinit { store.removeAll() }
}

/// Writes a smaller file in place (keeping a backup), or fails as told.
/// The requests an engine was given, in order.
final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [OptimisationRequest] = []

    func add(_ request: OptimisationRequest) { lock.withLock { stored.append(request) } }
    var requests: [OptimisationRequest] { lock.withLock { stored } }
}

struct ShrinkingEngine: OptimisationEngine {
    var factor = 0.4
    var backups: URL
    var failure: EsclopError?
    var delay: Duration = .zero
    var log: RequestLog?

    func optimise(_ source: URL, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult {
        log?.add(request)
        progress(OptimisationProgress(requestID: request.id, source: source, fraction: 0.5))
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        let started = Date()
        let before = AppModel.size(of: source)
        let backup = try OutputPlanner.backup(source, into: backups)
        try Data(repeating: 0x42, count: Int(Double(before) * factor)).write(to: source)
        return OptimisationResult(
            id: request.id, source: source, output: source, backup: backup, kind: MediaKind.of(source) ?? .image,
            bytesBefore: before, bytesAfter: AppModel.size(of: source), startedAt: started, finishedAt: Date()
        )
    }

    func convert(_ source: URL, to format: OutputFormat, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult { try await optimise(source, request: request, progress: progress) }
    func downscale(_ source: URL, factor: Double, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult { try await optimise(source, request: request, progress: progress) }
    func crop(_ source: URL, to size: CropSize, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult { try await optimise(source, request: request, progress: progress) }
    func fit(_ source: URL, underBytes: Int, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult { try await optimise(source, request: request, progress: progress) }
    func stripMetadata(_ source: URL, request: OptimisationRequest) async throws -> OptimisationResult { try await optimise(source, request: request) { _ in } }
    func supports(_ url: URL) -> Bool { true }
}

/// An app model over a temporary support folder, its own settings and pasteboard.
@MainActor
struct Harness {
    let temp = TempDir()
    let settings = TestSettings()
    let pasteboard = NSPasteboard.withUniqueName()
    let model: AppModel
    let revealed = Revealed()
    let requests = RequestLog()
    let announcements = Revealed()

    final class Revealed: @unchecked Sendable {
        var urls: [URL] = []
        var texts: [String] = []
    }

    init(failure: EsclopError? = nil, delay: Duration = .zero, gate: WorkGate = WorkGate(limit: 4)) {
        let locations = EsclopLocations(support: temp.url.appendingPathComponent("support", isDirectory: true))
        let service = EsclopService(ServiceContext(
            origin: .app,
            engine: ShrinkingEngine(backups: locations.backups, failure: failure, delay: delay, log: requests),
            engineName: "test", settings: RegistrySettingsProvider(store: settings.store),
            pipelines: PipelineStore(directory: locations.pipelines, useTrash: false),
            locations: locations, useApp: false
        ))
        let revealed = revealed
        model = AppModel(settings: settings.store, service: service, pasteboard: pasteboard, gate: gate) { revealed.urls += $0 }
        model.loadsThumbnails = false
        let announcements = announcements
        model.announce = { announcements.texts.append($0) }
    }

    func job(_ file: URL, origin: RequestOrigin = .dropZone, showUI: Bool = true, location: OutputLocation = .inPlace) -> OptimisationJob {
        OptimisationJob(
            request: OptimisationRequest(sources: [file], origin: origin, location: location, showResultUI: showUI),
            operation: .optimise
        )
    }
}

/// A tiny PNG of a solid colour.
func pngData(width: Int = 64, height: Int = 64) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.systemTeal.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// Waits until `condition` holds. The timeout only catches a hang: on a busy CI runner other
/// main-actor suites can hold the main actor for many seconds, so it is never a speed check.
@MainActor
func eventually(_ timeout: Duration = .seconds(60), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}
