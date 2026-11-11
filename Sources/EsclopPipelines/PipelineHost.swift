// SPDX-License-Identifier: GPL-3.0-or-later
//
// The seams the runner reaches through: the app (clipboard, shelves, uploads, extra result
// cards), engines that can do more than the contract's `OptimisationEngine`, and processes.

import EsclopCore
import Foundation

// MARK: - Host

/// Things only the running app can do well. The runner asks; a host that cannot answers
/// `.unavailable` and the step is logged as skipped instead of failing the file.
public enum PipelineHostAction: Hashable, Codable, Sendable {
    case copyToClipboard(format: ClipboardFormat, relativeTo: String?)
    case copyLinkForSending(expiration: TimeInterval?)
    case shelve(app: String)
    case upload(app: String)
    /// Upload to one of the person's upload targets (nil: the default) and copy the link.
    case uploadTo(target: String?)
    case open(app: String)
    /// Show this file as an extra result (the `fork` step).
    case presentFork
}

public enum PipelineHostOutcome: Hashable, Sendable {
    /// Done; the message, if any, goes into the run log (a share link, for example).
    case handled(String?)
    /// Not possible here; the reason goes into the run log.
    case unavailable(String)
}

public protocol PipelineHost: Sendable {
    func perform(_ action: PipelineHostAction, file: URL, options: PipelineRunOptions) async throws -> PipelineHostOutcome
}

/// The default host: does nothing and says why, so the CLI can run any pipeline.
public struct NoopPipelineHost: PipelineHost {
    public init() {}

    public func perform(_ action: PipelineHostAction, file: URL, options: PipelineRunOptions) async throws -> PipelineHostOutcome {
        .unavailable("needs the esclop app")
    }
}

/// A host for the command line: opens files with `open -a` and copies paths and Markdown with
/// `pbcopy`. Everything else needs the app.
public struct CommandLinePipelineHost: PipelineHost {
    let commands: any CommandRunner

    public init(commands: any CommandRunner = ProcessCommandRunner()) {
        self.commands = commands
    }

    public func perform(_ action: PipelineHostAction, file: URL, options: PipelineRunOptions) async throws -> PipelineHostOutcome {
        switch action {
        case let .open(app):
            let out = try await commands.run(URL(fileURLWithPath: "/usr/bin/open"), ["-a", app, file.path], environment: nil, input: nil)
            guard out.status == 0 else { throw EsclopError.toolFailed(tool: "open", exitCode: out.status, stderr: out.stderr) }
            return .handled(nil)
        case let .copyToClipboard(format, relativeTo):
            guard format != .imageData else { return .unavailable("copying image data needs the esclop app") }
            let text = clipboardText(file: file, format: format, relativeTo: relativeTo)
            let out = try await commands.run(URL(fileURLWithPath: "/usr/bin/pbcopy"), [], environment: nil, input: Data(text.utf8))
            guard out.status == 0 else { throw EsclopError.toolFailed(tool: "pbcopy", exitCode: out.status, stderr: out.stderr) }
            return .handled("copied \(text)")
        default:
            return .unavailable("needs the esclop app")
        }
    }
}

/// The text `copyToClipboard` puts on the clipboard for `path` and `markdown`. Shared by hosts.
public func clipboardText(file: URL, format: ClipboardFormat, relativeTo: String?) -> String {
    var path = file.path
    if let relativeTo {
        let base = URL(fileURLWithPath: TemplateContext.expandHome(relativeTo)).standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        if path.hasPrefix(prefix) { path = String(path.dropFirst(prefix.count)) }
    }
    guard format == .markdown else { return path }
    let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    let title = file.deletingPathExtension().lastPathComponent
    return MediaKind.of(file) == .image ? "![\(title)](\(encoded))" : "[\(title)](\(encoded))"
}

// MARK: - Media operations beyond the contract

/// Operations pipelines need that `OptimisationEngine` does not have. An engine adopts this to
/// support `lowerBitrate`, `capFps`, `normalize`, `watermark`, `extractPagesAsImages` and the
/// `frames` argument of `changeSpeed`. Every method follows the engine contract: it writes where
/// `request.location` says and never deletes the source unless the location is `.inPlace`.
public protocol PipelineMediaOperations: Sendable {
    func lowerBitrate(_ source: URL, kbps: Int, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult
    func capFrameRate(_ source: URL, fps: Int, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult
    func normalizeLoudness(_ source: URL, lufs: Double, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult
    /// `keepFrames` nil follows the app's setting.
    func changeSpeed(_ source: URL, factor: Double, keepFrames: Bool?, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult
    func removeAudio(_ source: URL, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult
    func watermark(_ source: URL, image: URL, position: WatermarkPosition, opacity: Double, scale: Double, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> OptimisationResult
    /// Writes one image per page into `directory` and returns them in page order.
    func extractPages(_ source: URL, format: PageImageFormat, scale: Double, into directory: URL, request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void) async throws -> [URL]
}

// MARK: - Processes

public struct CommandOutput: Sendable, Hashable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunner: Sendable {
    /// `environment` nil inherits the current one.
    func run(_ executable: URL, _ arguments: [String], environment: [String: String]?, input: Data?) async throws -> CommandOutput
}

/// Runs a process through `ProcessRunner`: stdout and stderr are read as they fill so a chatty
/// script never blocks, the child is killed when the task is cancelled, and nothing waits on
/// `DispatchQueue.global()` (which CPU-bound work elsewhere in the process can starve).
public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    public func run(_ executable: URL, _ arguments: [String], environment: [String: String]?, input: Data?) async throws -> CommandOutput {
        // `environment` is the caller's full environment; laid over the current one it is the same.
        let options = ProcessOptions(
            environment: environment ?? [:], stdin: input, stderrLimit: 16 * 1024 * 1024, acceptsAnyExitCode: true
        )
        let result = try await ProcessRunner.run(executable: executable, arguments: arguments, options: options)
        return CommandOutput(status: result.exitCode, stdout: result.stdoutString, stderr: result.stderrString)
    }
}
