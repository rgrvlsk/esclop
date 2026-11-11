// SPDX-License-Identifier: GPL-3.0-or-later
//
// Runs the bundled tools. One-shot runs (`run`) capture stdout and the tail of stderr, stream
// lines to optional handlers (ffmpeg's `-progress pipe:1` output, for instance),
// honour Swift task cancellation by killing the child, and time out. Long-lived children
// (`launch`, used for `esclop-engine serve`) expose stdin writes and an ordered stream of
// stdout lines.
//
// Nothing here waits on `DispatchQueue.global()`. That queue only gets a thread when this
// process's worker pool has one free, and CPU-bound Swift tasks (parallel tests, image work)
// can occupy the whole pool for minutes; a timeout or a completion queued there waits for them.
// Timers, completion and kill escalation run on a private serial queue per child instead, which
// GCD always serves. A call ends once the child has exited and its pipes are drained, or a short
// grace after it exited when a descendant keeps the pipes open.

import Foundation

public struct ProcessOptions: Sendable {
    /// Added to (and overriding) the current environment. `ESCLOP_BIN` is always set.
    public var environment: [String: String]
    public var currentDirectory: URL?
    /// Seconds before the child is terminated and the run fails. nil waits for ever.
    public var timeout: TimeInterval?
    /// Written to the child's stdin, which is then closed. nil gives it /dev/null.
    public var stdin: Data?
    /// Exit codes that count as success (pngquant-style tools use others for "no gain").
    public var acceptedExitCodes: Set<Int32>
    /// Return every exit status instead of throwing (script steps report their own status).
    public var acceptsAnyExitCode: Bool
    public var onStdoutLine: (@Sendable (String) -> Void)?
    public var onStderrLine: (@Sendable (String) -> Void)?
    /// How much of stderr is kept for error messages (the tail).
    public var stderrLimit: Int
    /// After the child exits, how long to wait for its pipes to close. A descendant it left
    /// running (a daemon, `cmd &`) can hold them open indefinitely.
    public var drainGrace: TimeInterval

    public init(
        environment: [String: String] = [:], currentDirectory: URL? = nil, timeout: TimeInterval? = nil,
        stdin: Data? = nil, acceptedExitCodes: Set<Int32> = [0],
        onStdoutLine: (@Sendable (String) -> Void)? = nil, onStderrLine: (@Sendable (String) -> Void)? = nil,
        stderrLimit: Int = 64 * 1024, drainGrace: TimeInterval = 2, acceptsAnyExitCode: Bool = false
    ) {
        self.drainGrace = drainGrace
        self.acceptsAnyExitCode = acceptsAnyExitCode
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.timeout = timeout
        self.stdin = stdin
        self.acceptedExitCodes = acceptedExitCodes
        self.onStdoutLine = onStdoutLine
        self.onStderrLine = onStderrLine
        self.stderrLimit = stderrLimit
    }
}

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var duration: TimeInterval

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessRunner {
    /// Runs a bundled tool found by `locator`.
    @discardableResult
    public static func run(
        _ tool: Tool, _ arguments: [String], options: ProcessOptions = .init(), locator: ToolLocator = .shared
    ) async throws -> ProcessResult {
        let executable = try locator.url(for: tool)
        return try await run(executable: executable, arguments: arguments, name: tool.rawValue, options: options, locator: locator)
    }

    @discardableResult
    public static func run(
        executable: URL, arguments: [String], name: String? = nil, options: ProcessOptions = .init(),
        locator: ToolLocator = .shared
    ) async throws -> ProcessResult {
        let name = name ?? executable.lastPathComponent
        if Task.isCancelled { throw EsclopError.cancelled }
        _ = ignoreSIGPIPE

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment(adding: options.environment, locator: locator)
        if let dir = options.currentDirectory { process.currentDirectoryURL = dir }

        let execution = Execution(name: name, options: options)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe: Pipe? = options.stdin == nil ? nil : Pipe()
        process.standardInput = inPipe ?? FileHandle.nullDevice

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                execution.streamClosed(stdout: true)
            } else {
                execution.appendStdout(data)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                execution.streamClosed(stdout: false)
            } else {
                execution.appendStderr(data)
            }
        }
        process.terminationHandler = { process in execution.exited(process.terminationStatus) }

        Log.process.debug("run \(name, privacy: .public) \(arguments.joined(separator: " "), privacy: .private)")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                guard execution.begin(continuation, handles: [outPipe.fileHandleForReading, errPipe.fileHandleForReading]) else {
                    return
                }
                do {
                    try process.run()
                } catch {
                    execution.launchFailed(error)
                    return
                }
                execution.launched(process)
                if let data = options.stdin, let inPipe {
                    execution.write(data, to: inPipe.fileHandleForWriting)
                }
            }
        } onCancel: {
            execution.cancel()
        }
    }

    /// Starts a long-lived child that talks over stdin/stdout. The caller owns its lifetime.
    public static func launch(
        _ tool: Tool, _ arguments: [String], environment extra: [String: String] = [:], locator: ToolLocator = .shared
    ) throws -> RunningProcess {
        let executable = try locator.url(for: tool)
        return try launch(executable: executable, arguments: arguments, name: tool.rawValue, environment: extra, locator: locator)
    }

    public static func launch(
        executable: URL, arguments: [String], name: String? = nil, environment extra: [String: String] = [:],
        locator: ToolLocator = .shared
    ) throws -> RunningProcess {
        _ = ignoreSIGPIPE
        let running = RunningProcess(name: name ?? executable.lastPathComponent)
        let process = running.process
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment(adding: extra, locator: locator)
        do {
            try running.start()
        } catch {
            throw EsclopError.toolFailed(tool: running.name, exitCode: -1, stderr: error.localizedDescription)
        }
        return running
    }

    /// The environment children see: ours, plus `ESCLOP_BIN`, plus the caller's overrides.
    static func environment(adding extra: [String: String], locator: ToolLocator) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let bin = locator.bundledDirectory {
            env["ESCLOP_BIN"] = bin.path
        }
        for (key, value) in extra { env[key] = value }
        return env
    }

    static func tail(_ text: String, limit: Int = 2000) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return "…" + trimmed.suffix(limit)
    }

    /// Writing to a child that has exited raises SIGPIPE, which would kill us; ignore it once so
    /// the write fails with EPIPE instead.
    private static let ignoreSIGPIPE: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()
}

// MARK: - One run

/// The state of one `run`: output buffers (filled from Foundation's pipe handler threads under
/// `lock`) and the lifecycle (launch, exit, pipes closed, cancel, timeout) on `queue`, a private
/// serial queue that resumes the caller exactly once.
private final class Execution: @unchecked Sendable {
    private let name: String
    private let options: ProcessOptions
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var outLines = LineSplitter()
    private var errLines = LineSplitter()

    // Owned by `queue`.
    private var continuation: CheckedContinuation<ProcessResult, Error>?
    private var handles: [FileHandle] = []
    private var process: Process?
    private var exitStatus: Int32?
    private var openStreams = 2
    private var cancelled = false
    private var timedOut = false
    private var started = Date()

    init(name: String, options: ProcessOptions) {
        self.name = name
        self.options = options
        queue = DispatchQueue(label: "dev.esclop.process.\(name)", qos: .userInitiated)
    }

    // MARK: Output (pipe handler threads)

    func appendStdout(_ data: Data) {
        let lines: [String]
        lock.lock()
        out.append(data)
        lines = options.onStdoutLine == nil ? [] : outLines.push(data)
        lock.unlock()
        lines.forEach { options.onStdoutLine?($0) }
    }

    func appendStderr(_ data: Data) {
        let lines: [String]
        lock.lock()
        err.append(data)
        if err.count > options.stderrLimit * 2 {
            err = err.suffix(options.stderrLimit)
        }
        lines = options.onStderrLine == nil ? [] : errLines.push(data)
        lock.unlock()
        lines.forEach { options.onStderrLine?($0) }
    }

    func streamClosed(stdout: Bool) {
        lock.lock()
        let rest = stdout ? outLines.flush() : errLines.flush()
        lock.unlock()
        if let rest { (stdout ? options.onStdoutLine : options.onStderrLine)?(rest) }
        queue.async {
            self.openStreams -= 1
            self.finishIfDone()
        }
    }

    // MARK: Lifecycle (`queue`)

    /// Called before the launch so the timeout counts from the start of the call. Returns false
    /// (and has already answered the caller) when the task was cancelled before it got here:
    /// a task cancelled earlier runs its cancellation handler before this, with nothing to stop.
    func begin(_ continuation: CheckedContinuation<ProcessResult, Error>, handles: [FileHandle]) -> Bool {
        let proceed = queue.sync { () -> Bool in
            self.continuation = continuation
            self.handles = handles
            self.started = Date()
            if self.cancelled {
                self.finish(.failure(EsclopError.cancelled))
                return false
            }
            return true
        }
        if proceed, let timeout = options.timeout {
            queue.asyncAfter(deadline: .now() + timeout) { self.timeOut() }
        }
        return proceed
    }

    func launchFailed(_ error: Error) {
        queue.async {
            self.finish(.failure(EsclopError.toolFailed(tool: self.name, exitCode: -1, stderr: error.localizedDescription)))
        }
    }

    func launched(_ process: Process) {
        queue.async {
            self.process = process
            // Cancelled or timed out while launching: the caller has its answer, the child goes.
            if self.cancelled || self.timedOut { self.stop() }
        }
    }

    func write(_ data: Data, to handle: FileHandle) {
        // A child that does not read its stdin must not block anyone.
        DispatchQueue(label: "dev.esclop.process.\(name).stdin").async {
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }

    func exited(_ status: Int32) {
        queue.async {
            self.exitStatus = status
            if self.openStreams > 0 {
                self.queue.asyncAfter(deadline: .now() + self.options.drainGrace) {
                    guard self.continuation != nil else { return }
                    Log.process.info("\(self.name, privacy: .public) exited but a descendant still holds its output; not waiting for it")
                    self.openStreams = 0
                    self.finishIfDone()
                }
            }
            self.finishIfDone()
        }
    }

    func cancel() {
        queue.async {
            guard !self.cancelled else { return }
            // Recorded even before `begin`, which then answers without launching.
            self.cancelled = true
            guard self.continuation != nil else { return }
            if self.process == nil {
                // Still launching; `launched` kills it.
                self.finish(.failure(EsclopError.cancelled))
            } else {
                self.stop()
            }
        }
    }

    private func timeOut() {
        guard continuation != nil, exitStatus == nil, !cancelled else { return }
        timedOut = true
        if process == nil {
            finish(.failure(timeoutError(status: -1)))
        } else {
            stop()
        }
    }

    /// SIGTERM, then SIGKILL if the child is still there two seconds later.
    private func stop() {
        guard let process, exitStatus == nil else { return }
        let pid = process.processIdentifier
        process.terminate()
        queue.asyncAfter(deadline: .now() + 2) {
            if self.exitStatus == nil { kill(pid, SIGKILL) }
        }
    }

    private func finishIfDone() {
        guard continuation != nil, let status = exitStatus, openStreams <= 0 else { return }
        if cancelled {
            finish(.failure(EsclopError.cancelled))
        } else if timedOut {
            finish(.failure(timeoutError(status: status)))
        } else if !options.acceptsAnyExitCode, !options.acceptedExitCodes.contains(status) {
            let stderr = ProcessRunner.tail(stderrString)
            Log.process.error("\(self.name, privacy: .public) exited \(status): \(stderr, privacy: .public)")
            finish(.failure(EsclopError.toolFailed(tool: name, exitCode: status, stderr: stderr)))
        } else {
            lock.lock()
            let result = ProcessResult(exitCode: status, stdout: out, stderr: err.suffix(options.stderrLimit), duration: Date().timeIntervalSince(started))
            lock.unlock()
            finish(.success(result))
        }
    }

    private func finish(_ outcome: Result<ProcessResult, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        // Stop listening; a descendant that keeps writing no longer matters to this call.
        for handle in handles { handle.readabilityHandler = nil }
        continuation.resume(with: outcome)
    }

    private var stderrString: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: err.suffix(options.stderrLimit), as: UTF8.self)
    }

    private func timeoutError(status: Int32) -> EsclopError {
        let seconds = options.timeout.map { $0 < 10 ? String(format: "%.1f", $0) : String(Int($0)) } ?? "?"
        return .toolFailed(tool: name, exitCode: status, stderr: "timed out after \(seconds) s. \(ProcessRunner.tail(stderrString))")
    }

    /// SIGTERM, then SIGKILL two seconds later, for children this file does not track.
    static func stop(_ process: Process, on queue: DispatchQueue) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        queue.asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// Splits a byte stream into lines on `\n` or `\r`, keeping partial lines for the next chunk.
struct LineSplitter {
    private var buffer = Data()

    mutating func push(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = buffer[buffer.startIndex ..< index]
            buffer.removeSubrange(buffer.startIndex ... index)
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
        }
        return lines
    }

    mutating func flush() -> String? {
        defer { buffer.removeAll() }
        return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
    }
}

// MARK: - Long-lived children

/// A child process kept running between requests, such as `esclop-engine serve`.
public final class RunningProcess: @unchecked Sendable {
    public let name: String
    /// stdout, one element per line, in order. Finishes when the child closes stdout.
    public let lines: AsyncStream<String>
    let process = Process()
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var splitter = LineSplitter()
    private var errTail = Data()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private var exitHandlers: [@Sendable (Int32) -> Void] = []
    private var exited: Int32?
    /// stderr reached end of file, or the grace after the exit ran out (a descendant holds it).
    private var stderrDone = false
    /// The exit handlers have run; later ones run at once.
    private var reported = false
    private let drainGrace: TimeInterval = 2
    /// Writes and kill escalation; never the global queue (see the top of this file).
    private let queue: DispatchQueue

    init(name: String) {
        self.name = name
        queue = DispatchQueue(label: "dev.esclop.process.\(name).io", qos: .userInitiated)
        var continuation: AsyncStream<String>.Continuation!
        lines = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func start() throws {
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.lock.lock()
                let rest = self.splitter.flush()
                self.lock.unlock()
                if let rest { self.continuation.yield(rest) }
                self.continuation.finish()
                return
            }
            self.lock.lock()
            let lines = self.splitter.push(data)
            self.lock.unlock()
            lines.forEach { self.continuation.yield($0) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.lock.lock()
                self.stderrDone = true
                self.lock.unlock()
                self.reportExitIfDone()
                return
            }
            self.lock.lock()
            self.errTail.append(data)
            if self.errTail.count > 32 * 1024 { self.errTail = self.errTail.suffix(16 * 1024) }
            self.lock.unlock()
        }
        // The exit is reported once stderr is drained too, so `stderrTail` holds the child's last
        // words (a crash message) when the handlers run.
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.lock.lock()
            self.exited = process.terminationStatus
            self.lock.unlock()
            self.queue.asyncAfter(deadline: .now() + self.drainGrace) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.stderrDone = true
                self.lock.unlock()
                self.reportExitIfDone()
            }
            self.reportExitIfDone()
        }
        try process.run()
    }

    public var isRunning: Bool { process.isRunning }
    public var processIdentifier: Int32 { process.processIdentifier }

    /// The last part of what the child wrote to stderr (its logs).
    public var stderrTail: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: errTail, as: UTF8.self)
    }

    /// Called once with the exit status, after the child has exited and its stderr is drained;
    /// immediately if that already happened.
    public func onExit(_ handler: @escaping @Sendable (Int32) -> Void) {
        lock.lock()
        if reported, let exited {
            lock.unlock()
            handler(exited)
            return
        }
        exitHandlers.append(handler)
        lock.unlock()
    }

    private func reportExitIfDone() {
        lock.lock()
        guard !reported, let status = exited, stderrDone else {
            lock.unlock()
            return
        }
        reported = true
        let handlers = exitHandlers
        exitHandlers = []
        lock.unlock()
        handlers.forEach { $0(status) }
    }

    /// Queues one line (a newline is added) for the child's stdin. Never blocks the caller, even
    /// when the child has stopped reading; a failed write shows up as the child's exit.
    public func send(_ line: String) throws {
        guard process.isRunning else {
            throw EsclopError.toolFailed(tool: name, exitCode: process.terminationStatus, stderr: "not running")
        }
        let data = Data((line + "\n").utf8)
        let handle = inPipe.fileHandleForWriting
        let name = self.name
        queue.async {
            do {
                try handle.write(contentsOf: data)
            } catch {
                Log.process.error("\(name, privacy: .public): write to stdin failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Closes stdin (a well-behaved server exits) and terminates it if it is still running later.
    public func stop(grace: TimeInterval = 1) {
        let handle = inPipe.fileHandleForWriting
        let process = self.process
        let queue = self.queue
        // Behind any queued writes, so the last request still reaches the child.
        queue.async {
            try? handle.close()
            guard process.isRunning else { return }
            queue.asyncAfter(deadline: .now() + grace) {
                Execution.stop(process, on: queue)
            }
        }
    }
}
