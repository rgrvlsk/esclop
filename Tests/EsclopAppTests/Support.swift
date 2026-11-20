// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EsclopCore
import EsclopIPC
import EsclopMCP
import EsclopPipelines
@testable import EsclopAppKit
import Foundation
import SwiftUI
import Testing

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

/// A settings suite of its own, emptied when the value goes away. A named suite, as the app's own
/// is: on CI runners a suite at a path sometimes lost a write, even to a read through the same
/// UserDefaults, and a change through key-value observation. Each one still leaves a plist in
/// ~/Library/Preferences (cfprefsd writes a removed domain back), so the first one of a run
/// removes those of earlier runs.
final class TestSettings: @unchecked Sendable {
    static let prefix = "dev.esclop.app-tests."
    static let sweptEarlierRuns = SettingsStore.removeEarlierSuites(prefix: prefix)
    let store: SettingsStore

    init() {
        _ = Self.sweptEarlierRuns
        store = SettingsStore(suiteName: Self.prefix + UUID().uuidString)
    }

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
    /// Where `.temporary` results go; `.sameFolder` ones go beside the source, the rest in place.
    var temporaryRoot: URL?

    func optimise(_ source: URL, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult {
        log?.add(request)
        progress(OptimisationProgress(requestID: request.id, source: source, fraction: 0.5))
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        let started = Date()
        let before = AppModel.size(of: source)
        if request.location == .temporary, let temporaryRoot {
            let output = request.location.destination(for: source, extension: source.pathExtension, temporaryRoot: temporaryRoot)
            try Paths.ensure(output.deletingLastPathComponent())
            try Data(repeating: 0x42, count: Int(Double(before) * factor)).write(to: output)
            return OptimisationResult(
                id: request.id, source: source, output: output, kind: MediaKind.of(source) ?? .image,
                bytesBefore: before, bytesAfter: AppModel.size(of: output), startedAt: started, finishedAt: Date()
            )
        }
        if request.location == .sameFolder {
            let output = try OutputPlanner.destination(for: source, location: .sameFolder, suffix: "optimised")
            try Data(repeating: 0x42, count: Int(Double(before) * factor)).write(to: output)
            return OptimisationResult(
                id: request.id, source: source, output: output, kind: MediaKind.of(source) ?? .image,
                bytesBefore: before, bytesAfter: AppModel.size(of: output), startedAt: started, finishedAt: Date()
            )
        }
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
    func fit(_ source: URL, underBytes: Int, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult {
        var request = request
        request.targetBytes = underBytes
        return try await optimise(source, request: request, progress: progress)
    }
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
            engine: ShrinkingEngine(
                backups: locations.backups, failure: failure, delay: delay, log: requests,
                temporaryRoot: temp.url.appendingPathComponent("esclop-temporary", isDirectory: true)
            ),
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

    /// A copy made in another app: the clipboard holds `data`, and the watcher's decision on it.
    func copy(image data: Data, app: String? = nil) -> ClipboardAction {
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        return .optimiseImage(data, .png, copyNow(app: app))
    }

    /// Files copied in Finder; `optimise` are the ones the watcher lets through (all by default).
    func copy(files: [URL], optimise: [URL]? = nil) -> ClipboardAction {
        pasteboard.clearContents()
        pasteboard.writeObjects(files as [NSURL])
        return .optimiseFiles(optimise ?? files, copied: files, copyNow())
    }

    func copyNow(app: String? = nil) -> ClipboardCopy {
        ClipboardCopy(changeCount: pasteboard.changeCount, app: app, types: Set((pasteboard.types ?? []).map(\.rawValue)))
    }

    /// Waits until every clipboard read and write queued so far has run.
    func clipboardSettles() async {
        await model.clipboard.run { _ in }
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

// MARK: Renders

/// Where renders keep their PNGs: `ESCLOP_RENDER_DIR`, for pull requests. Without it a render is
/// drawn and encoded but written nowhere, so a test run leaves no folder behind, passed or failed.
let renderFolder: URL? = ProcessInfo.processInfo.environment["ESCLOP_RENDER_DIR"].flatMap {
    $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
}

/// Encodes a render as PNG and writes `<name>-<light|dark>.png` into `folder` when there is one.
@discardableResult
func keepRender(_ rep: NSBitmapImageRep, name: String, scheme: ColorScheme, in folder: URL? = renderFolder) throws -> URL? {
    let data = try #require(rep.representation(using: .png, properties: [:]), "\(name) did not encode")
    guard let folder else { return nil }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
    try data.write(to: url)
    return url
}
