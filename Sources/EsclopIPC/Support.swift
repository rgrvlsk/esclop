// SPDX-License-Identifier: GPL-3.0-or-later
//
// Small helpers the CLI and the MCP server share: data locations, the recent-results log, path
// and size parsing, result summaries, and running a helper process with a timeout.

import EsclopCore
import Foundation

// MARK: - Locations

/// Where the CLI and MCP server read and write their data. `ESCLOP_SUPPORT_DIR` moves all of it
/// (tests use a temporary folder); `ESCLOP_PIPELINES_DIR` moves only the pipelines.
public struct EsclopLocations: Sendable, Hashable {
    public var support: URL
    public var pipelines: URL
    public var backups: URL
    public var logs: URL
    public var recentResults: URL { support.appendingPathComponent("recent-results.jsonl") }

    public init(support: URL, pipelines: URL? = nil, backups: URL? = nil, logs: URL? = nil) {
        self.support = support
        self.pipelines = pipelines ?? support.appendingPathComponent("pipelines", isDirectory: true)
        self.backups = backups ?? support.appendingPathComponent("backups", isDirectory: true)
        self.logs = logs ?? support.appendingPathComponent("logs", isDirectory: true)
    }

    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> EsclopLocations {
        var locations: EsclopLocations
        if let support = environment["ESCLOP_SUPPORT_DIR"], !support.isEmpty {
            locations = EsclopLocations(support: URL(fileURLWithPath: (support as NSString).expandingTildeInPath, isDirectory: true))
        } else {
            locations = EsclopLocations(support: Paths.applicationSupport, pipelines: Paths.pipelines, backups: Paths.backups, logs: Paths.logs)
        }
        if let pipelines = environment["ESCLOP_PIPELINES_DIR"], !pipelines.isEmpty {
            locations.pipelines = URL(fileURLWithPath: (pipelines as NSString).expandingTildeInPath, isDirectory: true)
        }
        return locations
    }
}

// MARK: - Recent results

/// Results of jobs the CLI and MCP server ran, newest last, one JSON object per line. The app may
/// append its own; readers de-duplicate by result id.
public struct ResultsLog: Sendable {
    public let url: URL
    public var keep: Int

    public init(url: URL, keep: Int = 500) {
        self.url = url
        self.keep = keep
    }

    public func append(_ results: [OptimisationResult]) {
        guard !results.isEmpty else { return }
        let encoder = JSONCoding.wireEncoder()
        var data = Data()
        for result in results {
            guard let line = try? encoder.encode(result) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        do {
            try Paths.ensure(url.deletingLastPathComponent())
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
        trimIfNeeded()
    }

    /// Newest first.
    public func recent(limit: Int) -> [OptimisationResult] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONCoding.wireDecoder()
        var seen = Set<UUID>()
        var results: [OptimisationResult] = []
        for line in data.split(separator: 0x0A).reversed() {
            guard let result = try? decoder.decode(OptimisationResult.self, from: Data(line)), seen.insert(result.id).inserted else { continue }
            results.append(result)
            if results.count >= limit { break }
        }
        return results
    }

    private func trimIfNeeded() {
        guard let data = try? Data(contentsOf: url) else { return }
        let lines = data.split(separator: 0x0A)
        guard lines.count > keep * 2 else { return }
        let kept = lines.suffix(keep).map { Data($0) + Data([0x0A]) }.reduce(Data(), +)
        try? kept.write(to: url, options: .atomic)
    }
}

// MARK: - Paths from people and agents

public enum PathInput {
    /// Accepts absolute and relative paths, `~`, and `file://` URLs.
    public static func url(_ raw: String, relativeTo base: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws -> URL {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" {
            text = String(text.dropFirst().dropLast())
        }
        guard !text.isEmpty else { throw EsclopError.invalidArgument("Empty path") }
        if text.lowercased().hasPrefix("file:") {
            guard let url = URL(string: text), url.isFileURL else { throw EsclopError.invalidArgument("Not a file URL: \(raw)") }
            return url.standardizedFileURL
        }
        if text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") {
            throw EsclopError.invalidArgument("\(raw) is a web address; download it first and pass the local file")
        }
        text = (text as NSString).expandingTildeInPath
        if text.hasPrefix("/") { return URL(fileURLWithPath: text).standardizedFileURL }
        return base.appendingPathComponent(text).standardizedFileURL
    }

    /// Expands folders into the media files inside them. Files pass through even when missing, so
    /// the job reports them; `extensions` (lowercase, no dot) filters what folders contribute.
    public static func expand(_ urls: [URL], recursive: Bool, extensions: Set<String> = []) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                out.append(url)
                continue
            }
            let keys: [URLResourceKey] = [.isRegularFileKey]
            let options: FileManager.DirectoryEnumerationOptions = recursive
                ? [.skipsHiddenFiles, .skipsPackageDescendants]
                : [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]
            guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: options) else { continue }
            var found: [URL] = []
            for case let file as URL in enumerator {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let ext = file.pathExtension.lowercased()
                if !extensions.isEmpty, !extensions.contains(ext) { continue }
                if extensions.isEmpty, MediaKind.of(file) == nil { continue }
                found.append(file.standardizedFileURL)
            }
            out.append(contentsOf: found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
        }
        return out
    }

    /// `~/...` instead of the home folder, for text people read.
    public static func abbreviate(_ url: URL) -> String { abbreviate(url.path) }

    public static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

// MARK: - Sizes

public enum ByteSize {
    /// `2MB`, `500 KB`, `1.5MiB`, `300000`, `2m`. KB/MB/GB are decimal, KiB/MiB/GiB binary.
    public static func parse(_ text: String) throws -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let number = trimmed.prefix { $0.isNumber || $0 == "." }
        let unit = trimmed.dropFirst(number.count).trimmingCharacters(in: .whitespaces)
        guard let value = Double(number), value > 0 else {
            throw EsclopError.invalidArgument("Expected a size like 2MB, 500KB or 300000, not \(text)")
        }
        let multipliers: [String: Double] = [
            "": 1, "b": 1, "byte": 1, "bytes": 1,
            "k": 1e3, "kb": 1e3, "kib": 1024, "m": 1e6, "mb": 1e6, "mib": 1_048_576,
            "g": 1e9, "gb": 1e9, "gib": 1_073_741_824,
        ]
        guard let multiplier = multipliers[unit] else {
            throw EsclopError.invalidArgument("Unknown size unit \(unit) in \(text); use B, KB, MB, GB, KiB, MiB or GiB")
        }
        return Int((value * multiplier).rounded())
    }

    /// `512 B`, `340 KB`, `1.2 MB`: decimal units like Finder, always with a dot.
    public static func format(_ bytes: Int) -> String {
        let value = Double(abs(bytes))
        let sign = bytes < 0 ? "-" : ""
        switch value {
        case ..<1000: return "\(sign)\(Int(value)) B"
        case ..<1e6: return sign + trimmed(value / 1e3) + " KB"
        case ..<1e9: return sign + trimmed(value / 1e6) + " MB"
        default: return sign + trimmed(value / 1e9) + " GB"
        }
    }

    private static func trimmed(_ value: Double) -> String {
        value >= 100 ? String(Int(value.rounded())) : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

// MARK: - Summaries

/// One result in the shape the CLI's `--json` and the MCP tools return.
public struct ResultSummary: Codable, Sendable, Hashable {
    public var id: UUID
    public var source: String
    public var output: String
    public var backup: String?
    public var kind: MediaKind
    public var bytesBefore: Int
    public var bytesAfter: Int
    public var savedBytes: Int
    /// 0...100, one decimal.
    public var savedPercent: Double
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var seconds: Double
    public var steps: [String]
    public var finishedAt: Date
    /// The public link of an uploaded file.
    public var link: String?

    public init(_ result: OptimisationResult) {
        id = result.id
        source = result.source.path
        output = result.output.path
        backup = result.backup?.path
        kind = result.kind
        bytesBefore = result.bytesBefore
        bytesAfter = result.bytesAfter
        savedBytes = result.savedBytes
        savedPercent = (result.savedFraction * 1000).rounded() / 10
        width = result.width
        height = result.height
        duration = result.duration
        link = result.link?.absoluteString
        seconds = (result.finishedAt.timeIntervalSince(result.startedAt) * 100).rounded() / 100
        steps = result.steps
        finishedAt = result.finishedAt
    }

    /// `photo.png 1.2 MB → 340 KB (−72%) → ~/Desktop/photo-optimised.png`
    public var line: String {
        let name = URL(fileURLWithPath: source).lastPathComponent
        if let link { return "\(name) uploaded → \(link)" }
        let change = savedBytes >= 0 ? "−\(Self.percent(savedPercent))%" : "+\(Self.percent(-savedPercent))%"
        var text = "\(name) \(ByteSize.format(bytesBefore)) → \(ByteSize.format(bytesAfter)) (\(change))"
        if output != source { text += " → \(PathInput.abbreviate(output))" }
        return text
    }

    public static func percent(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

public struct FailureSummary: Codable, Sendable, Hashable {
    public var source: String
    public var error: String
    public var code: String

    public init(_ failure: FileFailure) {
        source = failure.source.path
        error = failure.error.description
        code = failure.error.code
    }
}

public struct JobSummary: Codable, Sendable {
    public var operation: String
    public var route: String
    public var results: [ResultSummary]
    public var failures: [FailureSummary]
    public var bytesBefore: Int
    public var bytesAfter: Int
    public var savedBytes: Int
    public var savedPercent: Double

    public init(operation: String, report: JobReport) {
        self.operation = operation
        route = report.route
        results = report.results.map(ResultSummary.init)
        failures = report.failures.map(FailureSummary.init)
        bytesBefore = report.results.reduce(0) { $0 + $1.bytesBefore }
        bytesAfter = report.results.reduce(0) { $0 + $1.bytesAfter }
        savedBytes = bytesBefore - bytesAfter
        savedPercent = bytesBefore > 0 ? (Double(savedBytes) / Double(bytesBefore) * 1000).rounded() / 10 : 0
    }

    /// A few lines for a person or an agent: one per file, then a total when there are several.
    public var text: String {
        var lines = results.map(\.line)
        lines += failures.map { "✗ \(URL(fileURLWithPath: $0.source).lastPathComponent): \($0.error)" }
        if results.count > 1 {
            lines.append("Total \(ByteSize.format(bytesBefore)) → \(ByteSize.format(bytesAfter)) (−\(ResultSummary.percent(savedPercent))%) over \(results.count) files")
        }
        if lines.isEmpty { lines = ["No files to process"] }
        return lines.joined(separator: "\n")
    }
}

extension EsclopError {
    /// A stable machine-readable name for the case.
    public var code: String {
        switch self {
        case .unsupportedFile: return "unsupportedFile"
        case .fileNotFound: return "fileNotFound"
        case .toolMissing: return "toolMissing"
        case .toolFailed: return "toolFailed"
        case .alreadySmaller: return "alreadySmaller"
        case .cancelled: return "cancelled"
        case .notPermitted: return "notPermitted"
        case .invalidPipeline: return "invalidPipeline"
        case .invalidArgument: return "invalidArgument"
        case .appNotRunning: return "appNotRunning"
        case .unreadable: return "unreadable"
        case .other: return "other"
        }
    }
}

// MARK: - Helper processes

public enum HelperProcess {
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
        public var timedOut: Bool
    }

    /// Runs a program with no stdin and collects its output, killing it after `timeout`.
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30, environment: [String: String]? = nil) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        // Drain both pipes while the child runs: a full pipe would block it forever.
        final class Box: @unchecked Sendable { var data = Data() }
        let stdoutBox = Box(), stderrBox = Box()
        let group = DispatchGroup()
        for (pipe, box) in [(out, stdoutBox), (err, stderrBox)] {
            group.enter()
            DispatchQueue.global().async {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL); _ = exited.wait(timeout: .now() + 1) }
        }
        _ = group.wait(timeout: .now() + 5)
        return Output(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutBox.data, as: UTF8.self),
            stderr: String(decoding: stderrBox.data, as: UTF8.self),
            timedOut: timedOut
        )
    }
}
