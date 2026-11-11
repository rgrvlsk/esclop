// SPDX-License-Identifier: GPL-3.0-or-later
//
// Client for `esclop-engine serve`, the Rust image engine (docs/engine-protocol.md). One
// long-lived child per client; requests carry an id and may be answered out of order. If the
// child dies (a decoder crash, for instance) the requests in flight fail, the next call starts a
// fresh child, and a request that died with the old one is retried once.

import EsclopCore
import Foundation

/// What the running engine says it can do (`{"op":"hello"}`).
public struct EngineCapabilities: Codable, Hashable, Sendable {
    public var version: String
    public var ops: Set<String>
    public var features: [String: JSONValue]

    public init(version: String, ops: Set<String>, features: [String: JSONValue] = [:]) {
        self.version = version
        self.ops = ops
        self.features = features
    }

    public func supports(_ op: String) -> Bool { ops.contains(op) }

    /// Formats the engine can write. Read from `features.encode` (or `features.formats`) when the
    /// engine lists them, else the formats the protocol's first version promises.
    public var encodableFormats: Set<String> {
        for key in ["encode", "formats"] {
            if let list = features[key]?.arrayValue?.compactMap(\.stringValue), !list.isEmpty {
                return Set(list.map { $0.lowercased() })
            }
        }
        var formats: Set<String> = []
        if supports("png.optimise") || supports("convert") { formats.insert("png") }
        if supports("jpeg.optimise") || supports("convert") { formats.insert("jpeg") }
        if supports("webp.encode") { formats.insert("webp") }
        if supports("avif.encode") { formats.insert("avif") }
        if supports("gif.optimise") || supports("convert") { formats.insert("gif") }
        return formats
    }

    public func canEncode(_ format: String) -> Bool {
        encodableFormats.contains(format.lowercased() == "jpg" ? "jpeg" : format.lowercased())
    }
}

/// A successful reply. The common fields are parsed; everything else stays in `raw`.
public struct EngineReply: Sendable {
    public var bytesBefore: Int?
    public var bytesAfter: Int?
    public var width: Int?
    public var height: Int?
    public var format: String?
    public var raw: [String: JSONValue]

    init(_ result: [String: JSONValue]) {
        raw = result
        bytesBefore = result["bytes_before"]?.intValue
        bytesAfter = result["bytes_after"]?.intValue
        width = result["width"]?.intValue
        height = result["height"]?.intValue
        format = result["format"]?.stringValue
    }
}

public actor EngineClient {
    /// Shared by every `EsclopEngine` in the process, so there is one engine child.
    public static let shared = EngineClient()

    private let locator: ToolLocator
    private let executable: URL?
    private let arguments: [String]
    private let environment: [String: String]

    private var running: RunningProcess?
    private var reader: Task<Void, Never>?
    private var pending: [String: Pending] = [:]
    private var cancelledEarly: Set<String> = []
    /// Ids of hello requests in flight; a bare reply without an id answers the oldest.
    private var helloIDs: [String] = []
    private var nextID = 1
    private var cachedCapabilities: EngineCapabilities?
    private var exits: [Date] = []
    private var stopping: ObjectIdentifier?
    /// Requests cancelled (or timed out) whose reply has not come back yet, by the child that
    /// runs them. One still missing after `cancelGrace` holds a worker in a step that does not
    /// check for cancellation: the child is restarted to free it.
    private var abandoned: [String: ObjectIdentifier] = [:]
    private let cancelGrace: TimeInterval

    private struct Pending {
        let continuation: CheckedContinuation<[String: JSONValue], Error>
        let progress: (@Sendable (Double) -> Void)?
        let generation: ObjectIdentifier
        /// The input's kind, for a `decode` refusal (a damaged file of that kind).
        let kind: MediaKind?
    }

    /// The child process went away while a request was in flight.
    struct ChildExited: Error {
        let status: Int32
        let stderr: String
    }

    /// `executable` overrides the locator (tests point it at a fake engine); `environment` is
    /// added to the child's.
    public init(
        locator: ToolLocator = .shared, executable: URL? = nil, arguments: [String] = ["serve"], environment: [String: String] = [:],
        cancelGrace: TimeInterval = 30
    ) {
        self.locator = locator
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.cancelGrace = cancelGrace
    }

    /// The running child's process id (tests).
    var childProcessIdentifier: Int32? { running?.processIdentifier }

    /// Whether an engine executable exists at all.
    public nonisolated var isInstalled: Bool {
        executable.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? (locator.locate(.esclopEngine) != nil)
    }

    // MARK: Capabilities

    public func capabilities() async throws -> EngineCapabilities {
        if let cachedCapabilities { return cachedCapabilities }
        // An engine that never answers hello must not hang every image operation.
        let result = try await withThrowingTaskGroup(of: [String: JSONValue].self) { group in
            group.addTask { try await self.send(op: "hello", input: nil, output: nil, params: nil, progress: nil) }
            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                throw EsclopError.toolFailed(tool: Tool.esclopEngine.rawValue, exitCode: -1, stderr: "esclop-engine did not answer hello within 15 seconds")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        let caps = EngineCapabilities(
            version: result["version"]?.stringValue ?? "unknown",
            ops: Set(result["ops"]?.arrayValue?.compactMap(\.stringValue) ?? []),
            features: result["features"]?.objectValue ?? [:]
        )
        cachedCapabilities = caps
        Log.engine.info("esclop-engine \(caps.version, privacy: .public): \(caps.ops.sorted().joined(separator: ","), privacy: .public)")
        return caps
    }

    /// The capabilities, or nil when the engine is missing or does not start.
    public func capabilitiesIfAvailable() async -> EngineCapabilities? {
        guard isInstalled else { return nil }
        return try? await capabilities()
    }

    // MARK: Calls

    /// Runs one op. `input`/`output` are absolute file URLs. Errors map onto `EsclopError`.
    /// With `timeout`, a request that takes longer is cancelled and fails (see `abandoned`).
    @discardableResult
    public func call(
        _ op: String, input: URL? = nil, output: URL? = nil, params: [String: JSONValue] = [:],
        timeout: TimeInterval? = nil, progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> EngineReply {
        guard let timeout else { return try await call(op, input: input, output: output, params: params, progress: progress) }
        return try await withThrowingTaskGroup(of: EngineReply?.self) { group in
            group.addTask { try await self.call(op, input: input, output: output, params: params, progress: progress) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            guard let reply = try await group.next()!, !Task.isCancelled else {
                if Task.isCancelled { throw EsclopError.cancelled }
                let seconds = timeout < 10 ? String(format: "%.1f", timeout) : String(Int(timeout))
                throw EsclopError.toolFailed(
                    tool: Tool.esclopEngine.rawValue, exitCode: -1,
                    stderr: "esclop-engine did not finish \(input?.lastPathComponent ?? op) within \(seconds) s"
                )
            }
            return reply
        }
    }

    private func call(
        _ op: String, input: URL?, output: URL?, params: [String: JSONValue], progress: (@Sendable (Double) -> Void)?
    ) async throws -> EngineReply {
        do {
            return EngineReply(try await send(op: op, input: input, output: output, params: params, progress: progress))
        } catch is ChildExited {
            // The child crashed or was restarted under us; one more go on a fresh child.
            do {
                return EngineReply(try await send(op: op, input: input, output: output, params: params, progress: progress))
            } catch let exited as ChildExited {
                throw EsclopError.toolFailed(
                    tool: Tool.esclopEngine.rawValue, exitCode: exited.status,
                    stderr: "esclop-engine stopped while working on \(input?.lastPathComponent ?? op). \(exited.stderr)"
                )
            }
        }
    }

    /// Stops the child. The next call starts a new one.
    public func shutdown() {
        stopping = running.map(ObjectIdentifier.init)
        running?.stop()
        running = nil
        reader?.cancel()
        reader = nil
        cachedCapabilities = nil
    }

    private func send(
        op: String, input: URL?, output: URL?, params: [String: JSONValue]?,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> [String: JSONValue] {
        if Task.isCancelled { throw EsclopError.cancelled }
        let child = try ensureRunning()
        let id = String(nextID)
        nextID += 1
        if op == "hello" { helloIDs.append(id) }
        defer { helloIDs.removeAll { $0 == id } }
        var message: [String: JSONValue] = ["id": .string(id), "op": .string(op)]
        if let input { message["input"] = .string(input.path) }
        if let output { message["output"] = .string(output.path) }
        if let params { message["params"] = .object(params) }
        let line = JSONValue.object(message).jsonString()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: JSONValue], Error>) in
                if cancelledEarly.remove(id) != nil {
                    continuation.resume(throwing: EsclopError.cancelled)
                    return
                }
                pending[id] = Pending(
                    continuation: continuation, progress: progress, generation: ObjectIdentifier(child),
                    kind: input.flatMap(MediaKind.of)
                )
                do {
                    try child.send(line)
                } catch {
                    pending[id] = nil
                    continuation.resume(throwing: ChildExited(status: -1, stderr: child.stderrTail))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: String) {
        guard let entry = pending.removeValue(forKey: id) else {
            cancelledEarly.insert(id)
            return
        }
        entry.continuation.resume(throwing: EsclopError.cancelled)
        try? running?.send(JSONValue.object(["id": .string(id), "op": "cancel"]).jsonString())
        abandoned[id] = entry.generation
        let grace = cancelGrace
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            await self?.restartIfStillRunning(id)
        }
    }

    /// The cancelled request `id` never came back: its worker is stuck, so the child goes.
    /// Requests still in flight on it fail with `ChildExited` and are retried once.
    private func restartIfStillRunning(_ id: String) {
        guard let generation = abandoned.removeValue(forKey: id), let running, ObjectIdentifier(running) == generation else { return }
        Log.engine.error("esclop-engine did not stop request \(id, privacy: .public) when cancelled; restarting it")
        shutdown()
    }

    // MARK: Child process

    private func ensureRunning() throws -> RunningProcess {
        if let running, running.isRunning { return running }
        let now = Date()
        exits = exits.filter { now.timeIntervalSince($0) < 30 }
        if exits.count >= 3 {
            throw EsclopError.toolFailed(
                tool: Tool.esclopEngine.rawValue, exitCode: -1,
                stderr: "esclop-engine stopped \(exits.count) times in 30 seconds; not restarting it yet"
            )
        }
        let child: RunningProcess
        if let executable {
            child = try ProcessRunner.launch(executable: executable, arguments: arguments, name: Tool.esclopEngine.rawValue, environment: environment, locator: locator)
        } else {
            child = try ProcessRunner.launch(.esclopEngine, arguments, environment: environment, locator: locator)
        }
        running = child
        cachedCapabilities = nil
        let lines = child.lines
        reader = Task { [weak self] in
            for await line in lines {
                await self?.receive(line)
            }
        }
        let reader = self.reader
        child.onExit { [weak self] status in
            Task { await self?.childExited(child, status: status, reader: reader) }
        }
        Log.engine.info("Started esclop-engine (pid \(child.processIdentifier))")
        return child
    }

    private func childExited(_ child: RunningProcess, status: Int32, reader: Task<Void, Never>?) async {
        // Count the exit before waiting, so a crash loop is throttled even while new requests
        // start fresh children. A shutdown is not a crash.
        if stopping != ObjectIdentifier(child) { exits.append(Date()) }
        // Let replies the child wrote before exiting arrive first.
        await reader?.value
        let generation = ObjectIdentifier(child)
        abandoned = abandoned.filter { $0.value != generation }
        let stderr = child.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines).suffix(1000)
        for (id, entry) in pending where entry.generation == generation {
            pending[id] = nil
            entry.continuation.resume(throwing: ChildExited(status: status, stderr: String(stderr)))
        }
        if running === child {
            running = nil
            cachedCapabilities = nil
        }
        if status != 0 {
            Log.engine.error("esclop-engine exited with status \(status): \(stderr, privacy: .public)")
        }
    }

    private func receive(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{") else {
            Log.engine.debug("engine: \(trimmed, privacy: .public)")
            return
        }
        let value = JSONValue(parsing: trimmed)
        guard let object = value.objectValue else { return }
        let id = object["id"]?.stringValue ?? object["id"]?.intValue.map(String.init)

        if object["event"]?.stringValue == "progress" {
            if let id, let fraction = object["fraction"]?.doubleValue {
                pending[id]?.progress?(min(1, max(0, fraction)))
            }
            return
        }

        // A reply without an id can only be the hello answer in its bare form.
        if let id { abandoned[id] = nil }
        guard let id, let entry = pending.removeValue(forKey: id) else {
            if id == nil, object["version"] != nil,
               let helloID = helloIDs.first(where: { pending[$0] != nil })
            {
                pending.removeValue(forKey: helloID)?.continuation.resume(returning: object)
            }
            return
        }

        if let ok = object["ok"]?.boolValue {
            if ok {
                entry.continuation.resume(returning: object["result"]?.objectValue ?? [:])
            } else {
                let error = object["error"]?.objectValue ?? [:]
                entry.continuation.resume(throwing: Self.mapError(
                    code: error["code"]?.stringValue ?? "internal",
                    message: error["message"]?.stringValue ?? "esclop-engine failed",
                    kind: entry.kind,
                    reason: error["reason"]?.stringValue
                ))
            }
        } else {
            // Bare hello reply that kept the id.
            entry.continuation.resume(returning: object)
        }
    }

    /// `kind` is the input's: the engine's `decode` (it could not read the file) is a damaged
    /// file of that kind, its message going to the log.
    /// `reason`, with `unsupported`: why the file is left as it is, for people.
    static func mapError(code: String, message: String, kind: MediaKind? = nil, reason: String? = nil) -> EsclopError {
        if code == "unsupported", let reason, !reason.isEmpty {
            Log.engine.info("esclop-engine left the input as it is: \(message, privacy: .public)")
            return .leftAsIs(reason)
        }
        if code == "decode", let kind {
            Log.engine.info("esclop-engine could not read the input: \(message, privacy: .public)")
            return .unreadable(kind: kind)
        }
        switch code {
        case "unsupported": return .unsupportedFile(message)
        case "not_found": return .fileNotFound(message)
        case "already_smaller": return .alreadySmaller
        case "invalid_params": return .invalidArgument(message)
        case "cancelled": return .cancelled
        default: return .toolFailed(tool: Tool.esclopEngine.rawValue, exitCode: -1, stderr: "\(code): \(message)")
        }
    }
}
