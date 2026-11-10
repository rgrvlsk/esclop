// SPDX-License-Identifier: GPL-3.0-or-later
//
// Finds the command line tools the engines run. Resolution order:
//   1. $ESCLOP_BIN (a folder)
//   2. <app bundle>/Contents/Resources/bin
//   3. <prefix>/libexec/esclop for a command line installed as <prefix>/bin/esclop (release tarball)
//   4. Binaries/ and engine/target/release/ in a development checkout
//   5. PATH, plus the Homebrew prefixes GUI apps do not get on their PATH

import Foundation

public enum Tool: String, CaseIterable, Codable, Sendable {
    /// The Rust image engine (docs/engine-protocol.md).
    case esclopEngine = "esclop-engine"
    case ffmpeg, ffprobe
    case gs
    /// GPL-2.0-only: only ever run as a separate process, never linked.
    case gifsicle

    /// Name of the executable on disk.
    public var executableName: String { rawValue }

    /// What the tool is for, for error messages and `esclop status`.
    public var purpose: String {
        switch self {
        case .esclopEngine: return "image optimisation"
        case .ffmpeg: return "video and audio encoding"
        case .ffprobe: return "video and audio inspection"
        case .gs: return "PDF compression (Ghostscript)"
        case .gifsicle: return "GIF optimisation"
        }
    }

    /// The executable, or `EsclopError.toolMissing`.
    public var url: URL {
        get throws { try ToolLocator.shared.url(for: self) }
    }

    public var isAvailable: Bool { ToolLocator.shared.locate(self) != nil }
}

public struct ToolLocator: Sendable {
    public static let shared = ToolLocator()

    /// Folders searched in order before PATH.
    public let searchDirectories: [URL]
    /// PATH entries, searched last.
    public let pathDirectories: [URL]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main) {
        var dirs: [URL] = []
        if let bin = environment["ESCLOP_BIN"], !bin.isEmpty {
            dirs.append(URL(fileURLWithPath: (bin as NSString).expandingTildeInPath, isDirectory: true))
        }
        if let resources = bundle.resourceURL, bundle.bundleURL.pathExtension == "app" {
            dirs.append(resources.appendingPathComponent("bin", isDirectory: true))
        }
        if let executable = bundle.executableURL {
            let libexec = Self.libexecDirectory(forExecutable: executable)
            if FileManager.default.fileExists(atPath: libexec.path) { dirs.append(libexec) }
        }
        dirs.append(contentsOf: Self.checkoutBinaries())
        searchDirectories = dirs

        var path = (environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        for extra in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            let url = URL(fileURLWithPath: extra, isDirectory: true)
            if !path.contains(url) { path.append(url) }
        }
        pathDirectories = path
    }

    public init(searchDirectories: [URL], pathDirectories: [URL] = []) {
        self.searchDirectories = searchDirectories
        self.pathDirectories = pathDirectories
    }

    /// `<prefix>/libexec/esclop` for an executable at `<prefix>/bin/esclop`, following symlinks so a
    /// link to it from a folder on PATH still finds the tools it shipped with.
    static func libexecDirectory(forExecutable executable: URL) -> URL {
        executable.resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("libexec/esclop", isDirectory: true)
    }

    /// `Binaries/` and `engine/target/release/` next to `Package.swift`, found by walking up from the running executable
    /// (`.build/debug/esclop`) and, for test runners hosted elsewhere, from this source file.
    static func checkoutBinaries() -> [URL] {
        var starts: [URL] = []
        if let executable = Bundle.main.executableURL { starts.append(executable.deletingLastPathComponent()) }
        // Debug builds only: a release binary must not carry the path of the machine that built
        // it, nor look for tools in a checkout that is not its own.
        #if DEBUG
            starts.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent())
        #endif
        var found: [URL] = []
        let fm = FileManager.default
        for start in starts {
            var dir = start
            for _ in 0 ..< 8 {
                if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                    // Binaries/ holds ffmpeg, gs and gifsicle; the Rust engine builds into engine/target.
                    for sub in ["Binaries", "engine/target/release"] {
                        let candidate = dir.appendingPathComponent(sub, isDirectory: true)
                        if !found.contains(candidate) { found.append(candidate) }
                    }
                    break
                }
                let parent = dir.deletingLastPathComponent()
                if parent == dir { break }
                dir = parent
            }
        }
        return found
    }

    public func locate(_ tool: Tool) -> URL? {
        let fm = FileManager.default
        for dir in searchDirectories + pathDirectories {
            let candidate = dir.appendingPathComponent(tool.executableName)
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    public func url(for tool: Tool) throws -> URL {
        guard let url = locate(tool) else {
            Log.tools.error("Missing tool \(tool.rawValue, privacy: .public)")
            throw EsclopError.toolMissing(tool.rawValue)
        }
        return url
    }

    /// The folder holding bundled tools, passed to child processes as `ESCLOP_BIN`.
    public var bundledDirectory: URL? {
        searchDirectories.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Every tool with where it was found, for `esclop status` and onboarding.
    public func report() -> [(tool: Tool, url: URL?)] {
        Tool.allCases.map { ($0, locate($0)) }
    }
}
