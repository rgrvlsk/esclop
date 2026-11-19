// SPDX-License-Identifier: GPL-3.0-or-later
//
// Where esclop keeps things on disk. Every module uses these instead of building paths itself,
// so the CLI, the MCP server and the app agree.

import Foundation

public enum Paths {
    public static let bundleIdentifier = "dev.esclop.app"
    public static let defaultsSuite = "dev.esclop.app"

    /// Where the settings live: the app's suite, or `settings.plist` in `$ESCLOP_SUPPORT_DIR` when
    /// it is set, so a scripted or test run never changes the person's settings.
    public static func defaultsSuite(environment: [String: String]) -> String {
        guard let support = environment["ESCLOP_SUPPORT_DIR"], !support.isEmpty else { return defaultsSuite }
        return applicationSupport(environment: environment).appendingPathComponent("settings").path
    }

    /// `~/Library/Application Support/esclop`, or `$ESCLOP_SUPPORT_DIR` when it is set (tests and
    /// scripted runs keep backups, pipelines, logs and results out of the person's folder).
    public static var applicationSupport: URL { applicationSupport(environment: ProcessInfo.processInfo.environment) }

    public static func applicationSupport(environment: [String: String]) -> URL {
        if let support = environment["ESCLOP_SUPPORT_DIR"], !support.isEmpty {
            return URL(fileURLWithPath: (support as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("esclop", isDirectory: true)
    }

    public static var backups: URL { applicationSupport.appendingPathComponent("backups", isDirectory: true) }
    public static var pipelines: URL { applicationSupport.appendingPathComponent("pipelines", isDirectory: true) }
    public static var logs: URL { applicationSupport.appendingPathComponent("logs", isDirectory: true) }
    public static var temporary: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("esclop", isDirectory: true)
    }

    /// Creates the folder if needed and returns it.
    @discardableResult
    public static func ensure(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Placeholder engine used before EsclopOptimisers is wired in, and in tests that only need the
/// shape. Every operation fails with `toolMissing("engine")`.
public struct UnavailableEngine: OptimisationEngine {
    public init() {}

    public func optimise(_ source: URL, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult { throw EsclopError.toolMissing("engine") }
    public func convert(_ source: URL, to format: OutputFormat, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult { throw EsclopError.toolMissing("engine") }
    public func downscale(_ source: URL, factor: Double, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult { throw EsclopError.toolMissing("engine") }
    public func crop(_ source: URL, to size: CropSize, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult { throw EsclopError.toolMissing("engine") }
    public func fit(_ source: URL, underBytes: Int, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult { throw EsclopError.toolMissing("engine") }
    public func stripMetadata(_ source: URL, request: OptimisationRequest) async throws -> OptimisationResult { throw EsclopError.toolMissing("engine") }
    public func supports(_ url: URL) -> Bool { false }
}
