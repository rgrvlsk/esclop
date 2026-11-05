// SPDX-License-Identifier: GPL-3.0-or-later

import EsclopCore
import EsclopIPC
@testable import EsclopMCP
import EsclopPipelines
import Foundation

final class TempDir: @unchecked Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("esclop-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ name: String, bytes: Int = 1000) -> URL {
        let file = url.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data(repeating: 0x41, count: bytes))
        return file
    }

    @discardableResult
    func write(_ name: String, _ text: String) -> URL {
        let file = url.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func read(_ name: String) -> String {
        (try? String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Records every call; results halve the file and keep its path.
final class FakeEngine: OptimisationEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(String, URL)] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return log.map(\.0) }
    var sources: [URL] { lock.lock(); defer { lock.unlock() }; return log.map(\.1) }

    private func record(_ call: String, _ source: URL) -> OptimisationResult {
        lock.lock(); log.append((call, source)); lock.unlock()
        let size = ((try? FileManager.default.attributesOfItem(atPath: source.path))?[.size] as? NSNumber)?.intValue ?? 0
        return OptimisationResult(source: source, output: source, kind: MediaKind.of(source) ?? .image, bytesBefore: size, bytesAfter: size / 2,
                                  startedAt: Date(), finishedAt: Date(), steps: [call])
    }

    func optimise(_ source: URL, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult { record("optimise", source) }
    func convert(_ source: URL, to format: OutputFormat, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult { record("convert:\(format.rawValue)", source) }
    func downscale(_ source: URL, factor: Double, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult { record("downscale:\(factor)", source) }
    func crop(_ source: URL, to size: CropSize, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult { record("crop", source) }
    func fit(_ source: URL, underBytes: Int, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult { record("fit:\(underBytes)", source) }
    func stripMetadata(_ source: URL, request: OptimisationRequest) async throws -> OptimisationResult { record("strip", source) }
    func supports(_ url: URL) -> Bool { true }
}

func makeService(_ temp: TempDir, origin: RequestOrigin, allow: [AgentPermission] = [], engine: any OptimisationEngine = FakeEngine()) -> EsclopService {
    let settings = InMemorySettingsProvider(values: Dictionary(uniqueKeysWithValues: allow.map { ($0.rawValue, JSONValue.bool(true)) }))
    let locations = EsclopLocations(support: temp.url.appendingPathComponent("support", isDirectory: true))
    return EsclopService(ServiceContext(
        origin: origin, engine: engine, engineName: "fake", settings: settings,
        pipelines: PipelineStore(directory: locations.pipelines, useTrash: false), locations: locations,
        app: AppClient(ports: IPCPorts(prefix: "dev.esclop.test.none.\(UUID().uuidString.prefix(6))")), useApp: false
    ))
}
