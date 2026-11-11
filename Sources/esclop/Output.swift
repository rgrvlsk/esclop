// SPDX-License-Identifier: GPL-3.0-or-later
//
// Printing results for people (colour on a terminal) and for machines (--json), progress on
// stderr, exit codes and Ctrl-C.

import AppKit
import ArgumentParser
import EsclopCore
import EsclopIPC
import EsclopMCP
import Foundation

struct Terminal {
    let colorEnabled: Bool
    let stderrIsTTY: Bool

    init(color: Bool) {
        let env = ProcessInfo.processInfo.environment
        colorEnabled = color && isatty(STDOUT_FILENO) != 0 && env["NO_COLOR"] == nil && env["TERM"] != "dumb"
        stderrIsTTY = isatty(STDERR_FILENO) != 0
    }

    private func paint(_ text: String, _ code: String) -> String { colorEnabled ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
    func bold(_ t: String) -> String { paint(t, "1") }
    func dim(_ t: String) -> String { paint(t, "2") }
    func green(_ t: String) -> String { paint(t, "32") }
    func red(_ t: String) -> String { paint(t, "31") }
    func yellow(_ t: String) -> String { paint(t, "33") }
    func cyan(_ t: String) -> String { paint(t, "36") }

    func line(_ result: ResultSummary) -> String {
        let name = URL(fileURLWithPath: result.source).lastPathComponent
        let saved = result.savedBytes >= 0
        let percent = saved ? "−\(ResultSummary.percentText(result.savedPercent))%" : "+\(ResultSummary.percentText(-result.savedPercent))%"
        var text = "\(green("✓")) \(bold(name)) \(ByteSize.format(result.bytesBefore)) \(dim("→")) \(ByteSize.format(result.bytesAfter)) \(saved ? green(percent) : yellow(percent))"
        if result.output != result.source { text += " \(dim("→")) \(cyan(PathInput.abbreviate(result.output)))" }
        return text
    }

    func line(_ failure: FailureSummary) -> String {
        "\(red("✗")) \(bold(URL(fileURLWithPath: failure.source).lastPathComponent)) \(red(failure.error))"
    }
}

extension ResultSummary {
    static func percentText(_ value: Double) -> String { percent(value) }
}

/// What to do when a bundled tool (esclop-engine, ffmpeg, gifsicle) cannot be found.
let missingToolHint = """
A bundled tool is missing. The L'Esclop app carries them; from a checkout, build them with \
Scripts/build-tools.sh and `cargo build --release` in engine/, or point ESCLOP_BIN at a folder that \
has them. `esclop status` shows the route jobs take.

"""

enum Output {
    static func json<T: Encodable>(_ value: T) {
        print(JSONCoding.presentationString(value))
    }

    static func error(_ message: String, terminal: Terminal = Terminal(color: true)) {
        FileHandle.standardError.write(Data("\(isatty(STDERR_FILENO) != 0 ? terminal.red("error:") : "error:") \(message)\n".utf8))
    }

    /// Prints a job and returns the exit code it deserves.
    static func report(_ summary: JobSummary, global: GlobalOptions) -> Int32 {
        let terminal = global.terminal
        if global.json {
            json(summary)
        } else {
            summary.results.forEach { print(terminal.line($0)) }
            summary.failures.forEach { print(terminal.line($0)) }
            if summary.results.count > 1 {
                print(terminal.dim("Total \(ByteSize.format(summary.bytesBefore)) → \(ByteSize.format(summary.bytesAfter)) (−\(ResultSummary.percentText(summary.savedPercent))%) over \(summary.results.count) files"))
            }
            if summary.results.isEmpty, summary.failures.isEmpty { print("No files to process.") }
            if summary.failures.contains(where: { $0.code == "toolMissing" }) {
                FileHandle.standardError.write(Data(missingToolHint.utf8))
            }
        }
        if summary.failures.isEmpty { return 0 }
        if summary.results.isEmpty, summary.failures.allSatisfy({ $0.code == "fileNotFound" }) { return 66 }
        if summary.results.isEmpty, summary.failures.allSatisfy({ $0.code == "toolMissing" }) { return 69 }
        if summary.results.isEmpty, summary.failures.allSatisfy({ $0.code == "unreadable" }) { return 65 }
        return 1
    }

    static func exitCode(for error: EsclopError) -> Int32 {
        switch error {
        case .fileNotFound: return 66
        case .appNotRunning, .toolMissing: return 69
        case .notPermitted: return 77
        case .invalidArgument, .invalidPipeline, .unsupportedFile: return 64
        case .cancelled: return 130
        case .unreadable: return 65
        default: return 1
        }
    }
}

/// Runs a command body, turning `EsclopError`s into a message and the documented exit code.
func guarded(_ global: GlobalOptions, _ body: () async throws -> Int32) async throws {
    let code: Int32
    do {
        code = try await body()
    } catch let error as EsclopError {
        if global.json {
            Output.json(["error": error.description, "code": error.code])
        } else {
            Output.error(error.description, terminal: global.terminal)
        }
        throw ExitCode(Output.exitCode(for: error))
    } catch let error as ConfigError {
        Output.error(error.message, terminal: global.terminal)
        throw ExitCode(1)
    }
    if code != 0 { throw ExitCode(code) }
}

struct ConfigError: Error {
    let message: String
}

/// Progress on stderr, one rewritten line, only on a terminal.
final class ProgressLine: @unchecked Sendable {
    private let enabled: Bool
    private let lock = NSLock()
    private var shown = false

    init(enabled: Bool) { self.enabled = enabled && isatty(STDERR_FILENO) != 0 }

    func update(_ progress: OptimisationProgress) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        let percent = progress.fraction >= 0 ? " \(Int(progress.fraction * 100))%" : ""
        let message = progress.message.map { " \($0)" } ?? ""
        FileHandle.standardError.write(Data("\r\u{1B}[2K\(progress.source.lastPathComponent)\(percent)\(message)".utf8))
        shown = true
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        guard shown else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
        shown = false
    }
}

/// Calls `handler` once on Ctrl-C, then exits with 130.
final class InterruptHandler: @unchecked Sendable {
    private var source: DispatchSourceSignal?

    init(_ handler: @escaping @Sendable () -> Void) {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler {
            handler()
            FileHandle.standardError.write(Data("\ninterrupted\n".utf8))
            exit(130)
        }
        source.resume()
        self.source = source
    }

    func cancel() {
        source?.cancel()
        source = nil
        signal(SIGINT, SIG_DFL)
    }
}

enum Clipboard {
    static func copy(_ files: [URL]) {
        guard !files.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(files as [NSURL])
    }
}

/// Builds the job, runs it through the service with progress and Ctrl-C, prints the outcome.
func runFileJob(
    _ operation: JobOperation, files: FileOptions, global: GlobalOptions,
    configure: (inout OptimisationRequest) -> Void = { _ in }
) async throws {
    guard !files.items.isEmpty else { throw ValidationError("Give at least one file or folder.") }
    try await guarded(global) {
        let sources = try files.sources()
        guard !sources.isEmpty else {
            if global.json { Output.json(JobSummary(operation: operation.name, report: JobReport())) } else { print("No files to process.") }
            return 0
        }
        var request = OptimisationRequest(sources: sources, origin: .cli, location: files.location, showResultUI: files.gui)
        configure(&request)
        let service = EsclopService(global.context())
        let job = OptimisationJob(request: request, operation: operation)
        let progress = ProgressLine(enabled: !files.noProgress && !global.json)
        let interrupt = InterruptHandler { service.stop([job.id]) }
        defer { interrupt.cancel() }
        let report = try await service.perform(job) { progress.update($0) }
        progress.clear()
        if files.copy { Clipboard.copy(report.results.map(\.output)) }
        return Output.report(JobSummary(operation: operation.name, report: report), global: global)
    }
}
