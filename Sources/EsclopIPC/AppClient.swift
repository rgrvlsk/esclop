// SPDX-License-Identifier: GPL-3.0-or-later
//
// The CLI and MCP side of the IPC protocol. Every call opens a reply port, sends one message to
// the app and reads `AppEvent`s until the exchange ends. A watchdog turns a vanished app into
// `EsclopError.appNotRunning` instead of a hang.

import EsclopCore
import Foundation

public struct AppClient: Sendable {
    public var ports: IPCPorts
    public var bundleIdentifier: String
    /// How long a settings or control exchange may take before giving up.
    public var replyTimeout: TimeInterval
    /// How long the app may take to accept a job. Jobs themselves have no time limit.
    public var acceptTimeout: TimeInterval = 10

    public init(ports: IPCPorts = .default, bundleIdentifier: String = Paths.bundleIdentifier, replyTimeout: TimeInterval = 15) {
        self.ports = ports
        self.bundleIdentifier = bundleIdentifier
        self.replyTimeout = replyTimeout
    }

    /// True when the app listens for requests. Cheap: one bootstrap lookup.
    public var isAppRunning: Bool { RemoteMessagePort.isListening(ports.request) }

    // MARK: Jobs

    /// Sends a job and streams its progress. Returns when the app says `finished`.
    public func perform(
        _ job: OptimisationJob,
        progress: @escaping @Sendable (OptimisationProgress) -> Void = { _ in }
    ) async throws -> JobReport {
        var report = JobReport(route: "app")
        try await exchange(port: ports.request, body: job, timeout: nil, acceptWithin: acceptTimeout) { event in
            switch event {
            case .accepted: return false
            case let .progress(p): progress(p); return false
            case let .result(r): report.results.append(r); return false
            case let .failure(f): report.failures.append(f); return false
            case .finished: return true
            case let .refused(error): throw error
            default: return false
            }
        }
        return report
    }

    /// Cancels jobs by id. One-way: the app answers through the jobs' own reply ports.
    public func stop(_ ids: [UUID], remove: Bool = false) throws {
        let envelope = IPCEnvelope(body: StopRequest(ids: ids, remove: remove))
        try RemoteMessagePort.send(try envelope.encoded(), to: ports.stop)
    }

    // MARK: Settings

    public func settings(_ command: SettingsCommand, origin: RequestOrigin) async throws -> SettingsReply {
        var reply: SettingsReply?
        try await exchange(port: ports.settings, body: SettingsCall(command: command, origin: origin), timeout: replyTimeout) { event in
            switch event {
            case let .settings(r): reply = r; return true
            case let .refused(error): throw error
            default: return false
            }
        }
        guard let reply else { throw EsclopError.other("The L'Esclop app sent no settings reply") }
        return reply
    }

    // MARK: Control

    public func status() async throws -> AppStatus {
        var status: AppStatus?
        try await exchange(port: ports.control, body: ControlCommand.status, timeout: replyTimeout) { event in
            switch event {
            case let .status(s): status = s; return true
            case let .refused(error): throw error
            default: return false
            }
        }
        guard let status else { throw EsclopError.other("The L'Esclop app sent no status") }
        return status
    }

    public func recentResults(limit: Int) async throws -> [OptimisationResult] {
        var results: [OptimisationResult] = []
        try await exchange(port: ports.control, body: ControlCommand.recentResults(limit: limit), timeout: replyTimeout) { event in
            switch event {
            case let .results(r): results = r; return true
            case let .refused(error): throw error
            default: return false
            }
        }
        return results
    }

    /// Asks the app to quit and waits until its ports are gone.
    public func quit(timeout: TimeInterval = 10) async throws {
        guard isAppRunning else { throw EsclopError.appNotRunning }
        try await exchange(port: ports.control, body: ControlCommand.quit, timeout: replyTimeout) { event in
            switch event {
            case .done: return true
            case let .refused(error): throw error
            default: return false
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while isAppRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        if isAppRunning { throw EsclopError.other("The L'Esclop app is still running \(Int(timeout)) s after being asked to quit") }
    }

    /// Opens the app in the background and waits until it listens.
    public func launchApp(timeout: TimeInterval = 15) async throws {
        if isAppRunning { return }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-b", bundleIdentifier]
        open.standardOutput = FileHandle.nullDevice
        open.standardError = FileHandle.nullDevice
        open.standardInput = FileHandle.nullDevice
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else {
            throw EsclopError.other("The L'Esclop app (\(bundleIdentifier)) is not installed. Install esclop.app; until then the CLI and MCP server work in-process.")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !isAppRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard isAppRunning else { throw EsclopError.other("The L'Esclop app opened but did not start listening within \(Int(timeout)) s") }
    }

    // MARK: Exchange

    private enum Incoming: Sendable {
        case event(AppEvent)
        case lost
        case notAccepted
        case timedOut
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Sends `body` to `port` and feeds replies to `handle` until it returns true.
    func exchange<Body: Codable & Sendable>(
        port: String, body: Body, timeout: TimeInterval?, acceptWithin: TimeInterval? = nil,
        handle: (AppEvent) throws -> Bool
    ) async throws {
        let id = UUID()
        let replyName = ports.reply(id)
        let (stream, continuation) = AsyncStream<Incoming>.makeStream()
        let heard = Flag()
        let listener = try LocalMessagePort(name: replyName) { data in
            if let envelope = try? IPCEnvelope<AppEvent>.decode(data), envelope.id == id {
                heard.set()
                continuation.yield(.event(envelope.body))
            } else if let header = try? JSONCoding.wireDecoder().decode(IPCHeader.self, from: data), header.id == id,
                      header.version != IPCProtocol.version {
                // An app of another version answered: say so, instead of waiting for a reply
                // this client cannot read.
                heard.set()
                continuation.yield(.event(.refused(IPCProtocol.mismatch(header.version))))
            }
        }
        defer {
            listener.invalidate()
            continuation.finish()
        }

        try RemoteMessagePort.send(try IPCEnvelope(id: id, replyPort: replyName, body: body).encoded(), to: port)

        let watchedPort = ports.request
        let watchdog = Task.detached {
            let started = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                if !RemoteMessagePort.isListening(watchedPort) {
                    continuation.yield(.lost)
                    return
                }
                let waited = Date().timeIntervalSince(started)
                if let timeout, waited > timeout {
                    continuation.yield(.timedOut)
                    return
                }
                if let acceptWithin, waited > acceptWithin, !heard.isSet {
                    continuation.yield(.notAccepted)
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        for await incoming in stream {
            switch incoming {
            case let .event(event):
                if try handle(event) { return }
            case .lost:
                // Before any reply nothing was done, so the caller may do the work itself; after
                // one, some files may already be processed and must not be processed twice.
                throw heard.isSet ? EsclopError.other("The L'Esclop app quit while working on the request; results it finished are kept on disk") : EsclopError.appNotRunning
            case .notAccepted:
                throw EsclopError.other("The L'Esclop app did not accept the request within \(Int(acceptWithin ?? 0)) s. Is it a different version from this esclop? Update both together")
            case .timedOut:
                throw EsclopError.other("The L'Esclop app did not answer within \(Int(timeout ?? 0)) s")
            }
        }
        throw EsclopError.cancelled
    }
}
