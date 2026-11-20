// SPDX-License-Identifier: GPL-3.0-or-later
//
// Printing results for people (colour on a terminal) and for machines (--json), progress on
// stderr, exit codes and Ctrl-C.

import AppKit
import ArgumentParser
import EsclopCore
import EsclopIPC
import EsclopMCP
import EsclopOptimisers
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

    /// `fullPath` names the file by its path rather than its name (`esclop recent`).
    func line(_ result: ResultSummary, fullPath: Bool = false) -> String {
        let name = fullPath ? PathInput.abbreviate(URL(fileURLWithPath: result.source)) : URL(fileURLWithPath: result.source).lastPathComponent
        let saved = result.savedBytes >= 0
        let percent = saved ? "−\(ResultSummary.percentText(result.savedPercent))%" : "+\(ResultSummary.percentText(-result.savedPercent))%"
        var text = "\(green("✓")) \(bold(name)) \(ByteSize.format(result.bytesBefore)) \(dim("→")) \(ByteSize.format(result.bytesAfter)) \(saved ? green(percent) : yellow(percent))"
        if let link = result.link { return "\(green("✓")) \(bold(name)) \(dim("→")) \(cyan(link))" }
        if result.skippedByFilter { return "\(dim("–")) \(bold(name)) \(dim("skipped by the filter"))" }
        if result.output != result.source { text += " \(dim("→")) \(cyan(PathInput.abbreviate(result.output)))" }
        return text
    }

    func line(_ failure: FailureSummary) -> String {
        let name = bold(URL(fileURLWithPath: failure.source).lastPathComponent)
        if failure.isUnchanged { return "\(dim("–")) \(name) \(dim("unchanged: already as small as it gets"))" }
        return "\(red("✗")) \(name) \(red(failure.message))"
    }
}

extension ResultSummary {
    static func percentText(_ value: Double) -> String { percent(value) }
}

extension FailureSummary {
    /// Nothing to gain: the file is left as it is, which is not an error (exit 0).
    var isUnchanged: Bool { code == "alreadySmaller" }
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

    /// Prints a job and returns the exit code it deserves. A file already as small as it gets is
    /// listed as unchanged and does not fail the command.
    static func report(_ summary: JobSummary, printing: Printing) -> Int32 {
        let terminal = printing.terminal
        if printing.json {
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
        return exitCode(for: summary)
    }

    static func exitCode(for summary: JobSummary) -> Int32 {
        let failures = summary.failures.filter { !$0.isUnchanged }
        if failures.isEmpty { return 0 }
        let nothingDone = summary.results.isEmpty && failures.count == summary.failures.count
        if nothingDone, failures.allSatisfy({ $0.code == "fileNotFound" }) { return 66 }
        if nothingDone, failures.allSatisfy({ $0.code == "toolMissing" }) { return 69 }
        if nothingDone, failures.allSatisfy({ $0.code == "unreadable" }) { return 65 }
        return 1
    }

    static func exitCode(for error: EsclopError) -> Int32 {
        switch error {
        case .fileNotFound, .backupRemoved: return 66
        case .appNotRunning, .toolMissing: return 69
        case .notPermitted: return 77
        case .invalidArgument, .invalidPipeline, .unsupportedFile, .leftAsIs: return 64
        case .cancelled: return 130
        case .unreadable: return 65
        default: return 1
        }
    }
}

/// Runs a command body, turning `EsclopError`s into a message and the documented exit code.
func guarded(_ global: GlobalOptions, _ body: () async throws -> Int32) async throws {
    try await guarded(global.printing, body)
}

func guarded(_ printing: Printing, _ body: () async throws -> Int32) async throws {
    let code: Int32
    do {
        code = try await body()
    } catch let error as EsclopError {
        if printing.json {
            Output.json(["error": error.description, "code": error.code])
        } else {
            Output.error(error.description, terminal: printing.terminal)
        }
        throw ExitCode(Output.exitCode(for: error))
    } catch let error as ConfigError {
        Output.error(error.message, terminal: printing.terminal)
        throw ExitCode(1)
    }
    if code != 0 { throw ExitCode(code) }
}

/// A line on stderr that does not change the outcome.
func note(_ message: String) {
    FileHandle.standardError.write(Data("note: \(message)\n".utf8))
}

/// Notes the files `flag` does nothing for: those not of `kinds` (`--pdf-dpi` on a PNG).
func noteFlag(_ flag: String, appliesTo kinds: Set<MediaKind>, _ kindName: String, sources: [URL]) {
    let others = sources.filter { MediaKind.of($0).map { !kinds.contains($0) } ?? true }
    guard !others.isEmpty else { return }
    var names = others.prefix(3).map(\.lastPathComponent).joined(separator: ", ")
    if others.count > 3 { names += " and \(others.count - 3) more" }
    note("\(flag) applies to \(kindName) only; ignored for \(names)")
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

/// Builds the job, runs it through the service with progress and Ctrl-C, prints the outcome.
func runFileJob(
    _ operation: JobOperation, files: FileOptions, global: GlobalOptions,
    configure: (inout OptimisationRequest) -> Void = { _ in }
) async throws {
    try await runJob(operation, inputs: files.inputs, printing: global.printing, context: global.context()) { request in
        request.location = files.location
        if files.locationFromSettings { request.locationFromSettings = true }
        configure(&request)
    } finished: { report in
        // Marked as L'Esclop's write, so the app's clipboard watcher does not optimise it again.
        if files.copy, !report.results.isEmpty { Clipboard.write(files: report.results.map(\.output)) }
    }
}

func runJob(
    _ operation: JobOperation, inputs: FileInputs, printing: Printing, context: @autoclosure () -> ServiceContext,
    configure: (inout OptimisationRequest) -> Void, finished: (JobReport) -> Void
) async throws {
    guard !inputs.items.isEmpty else { throw ValidationError("Give at least one file or folder.") }
    try await guarded(printing) {
        let sources = try await inputs.sources()
        guard !sources.isEmpty else {
            if printing.json { Output.json(JobSummary(operation: operation.name, report: JobReport())) } else { print("No files to process.") }
            return 0
        }
        var request = OptimisationRequest(sources: sources, origin: .cli, showResultUI: inputs.gui)
        configure(&request)
        let service = EsclopService(context())
        let job = OptimisationJob(request: request, operation: operation)
        let progress = ProgressLine(enabled: !inputs.noProgress && !printing.json)
        let interrupt = InterruptHandler { service.stop([job.id]) }
        defer { interrupt.cancel() }
        let report = try await service.perform(job) { progress.update($0) }
        progress.clear()
        finished(report)
        return Output.report(JobSummary(operation: operation.name, report: report), printing: printing)
    }
}
