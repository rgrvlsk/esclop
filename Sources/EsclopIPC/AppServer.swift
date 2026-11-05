// SPDX-License-Identifier: GPL-3.0-or-later
//
// The app side of the IPC protocol. The app creates one `AppServer` with its handler and calls
// `start()` at launch. Every request runs in its own task; replies go to the client's reply port
// through a serial queue so they arrive in order.

import EsclopCore
import Foundation

/// What the app implements to serve the CLI and the MCP server.
///
/// `perform` reports each file through `events` and returns when the job is done; throwing refuses
/// the whole job (for example `notPermitted` from `AgentPolicy`). The app should check
/// `AgentPolicy` itself: it is the place an agent cannot route around. `JobExecutor` does the
/// actual work if the app has nothing more specific to do.
public protocol AppRequestHandler: Sendable {
    func perform(_ job: OptimisationJob, events: @escaping @Sendable (JobEvent) -> Void) async throws
    func stop(_ request: StopRequest) async
    func settings(_ command: SettingsCommand, origin: RequestOrigin) async throws -> SettingsReply
    func status() async -> AppStatus
    func recentResults(limit: Int) async -> [OptimisationResult]
    /// Called after the client was told `done`. The app terminates itself here.
    func quit() async
}

public final class AppServer: @unchecked Sendable {
    public let ports: IPCPorts
    private let handler: any AppRequestHandler
    private let lock = NSLock()
    private var listeners: [LocalMessagePort] = []
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var stoppedEarly = Set<UUID>()

    public init(handler: any AppRequestHandler, ports: IPCPorts = .default) {
        self.handler = handler
        self.ports = ports
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return !listeners.isEmpty
    }

    public var activeJobs: Int {
        lock.lock(); defer { lock.unlock() }
        return jobs.count
    }

    /// Registers the four service ports. Throws when another instance already owns them.
    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard listeners.isEmpty else { return }
        do {
            listeners = [
                try LocalMessagePort(name: ports.request) { [weak self] in self?.receiveJob($0) },
                try LocalMessagePort(name: ports.stop) { [weak self] in self?.receiveStop($0) },
                try LocalMessagePort(name: ports.settings) { [weak self] in self?.receiveSettings($0) },
                try LocalMessagePort(name: ports.control) { [weak self] in self?.receiveControl($0) },
            ]
        } catch {
            listeners.forEach { $0.invalidate() }
            listeners = []
            throw error
        }
    }

    public func stop() {
        lock.lock()
        let current = listeners
        let running = jobs
        listeners = []
        jobs = [:]
        lock.unlock()
        current.forEach { $0.invalidate() }
        running.values.forEach { $0.cancel() }
    }

    deinit { stop() }

    // MARK: Receiving

    /// The part of every envelope that survives a version change, so a refusal can be sent back.
    private struct Header: Decodable {
        var version: Int
        var id: UUID
        var replyPort: String?
    }

    /// Decodes a message, or tells the sender why it could not (a newer or older client).
    private func decode<Body: Codable & Sendable>(_ data: Data, as _: Body.Type) -> IPCEnvelope<Body>? {
        do {
            return try IPCEnvelope<Body>.decode(data)
        } catch {
            if let header = try? JSONCoding.wireDecoder().decode(Header.self, from: data), let port = header.replyPort {
                let reply = ReplySender(port: port, id: header.id)
                reply.send(.refused(EsclopError.wrap(error)))
            }
            return nil
        }
    }

    private func receiveJob(_ data: Data) {
        guard let envelope = decode(data, as: OptimisationJob.self), let replyPort = envelope.replyPort else { return }
        let reply = ReplySender(port: replyPort, id: envelope.id)
        let job = envelope.body
        reply.send(.accepted)
        let handler = handler
        // Registered under the lock before the task can finish or a stop can look for it.
        lock.lock()
        defer { lock.unlock() }
        if stoppedEarly.remove(job.id) != nil {
            reply.send(.finished)
            return
        }
        jobs[job.id] = Task { [weak self] in
            do {
                try await handler.perform(job) { reply.send(AppEvent($0)) }
                reply.send(.finished)
            } catch where Task.isCancelled || error is CancellationError || (error as? EsclopError) == .cancelled {
                // Stopped: the client keeps what finished before the stop.
                reply.send(.finished)
            } catch {
                reply.send(.refused(EsclopError.wrap(error)))
            }
            self?.finishJob(job.id)
        }
    }

    private func finishJob(_ id: UUID) {
        lock.lock()
        jobs[id] = nil
        lock.unlock()
    }

    private func receiveStop(_ data: Data) {
        guard let envelope = decode(data, as: StopRequest.self) else { return }
        lock.lock()
        let tasks = envelope.body.ids.compactMap { jobs[$0] }
        // A stop can overtake its job (different ports): remember it for when the job arrives.
        for id in envelope.body.ids where jobs[id] == nil { stoppedEarly.insert(id) }
        if stoppedEarly.count > 1000 { stoppedEarly.removeAll() }
        lock.unlock()
        tasks.forEach { $0.cancel() }
        let handler = handler
        Task { await handler.stop(envelope.body) }
    }

    private func receiveSettings(_ data: Data) {
        guard let envelope = decode(data, as: SettingsCall.self), let replyPort = envelope.replyPort else { return }
        let reply = ReplySender(port: replyPort, id: envelope.id)
        let handler = handler
        Task {
            do {
                reply.send(.settings(try await handler.settings(envelope.body.command, origin: envelope.body.origin)))
            } catch {
                reply.send(.refused(EsclopError.wrap(error)))
            }
        }
    }

    private func receiveControl(_ data: Data) {
        guard let envelope = decode(data, as: ControlCommand.self), let replyPort = envelope.replyPort else { return }
        let reply = ReplySender(port: replyPort, id: envelope.id)
        let handler = handler
        Task {
            switch envelope.body {
            case .status:
                reply.send(.status(await handler.status()))
            case let .recentResults(limit):
                reply.send(.results(await handler.recentResults(limit: limit)))
            case .quit:
                reply.send(.done)
                reply.flush()
                await handler.quit()
            }
        }
    }
}

/// Sends replies for one exchange, in order, without blocking the caller.
final class ReplySender: @unchecked Sendable {
    private let port: String
    private let id: UUID
    private let queue: DispatchQueue

    init(port: String, id: UUID) {
        self.port = port
        self.id = id
        self.queue = DispatchQueue(label: "esclop.reply.\(id.uuidString)")
    }

    func send(_ event: AppEvent) {
        let port = port
        let id = id
        queue.async {
            // A client that went away (Ctrl-C, crash) is not the app's problem.
            guard let data = try? IPCEnvelope(id: id, body: event).encoded() else { return }
            try? RemoteMessagePort.send(data, to: port, timeout: 10)
        }
    }

    /// Waits until everything queued so far has been handed to the port.
    func flush() { queue.sync {} }
}

extension EsclopError {
    /// Any error as an `EsclopError`, keeping its message.
    public static func wrap(_ error: Error) -> EsclopError {
        if let error = error as? EsclopError { return error }
        if error is CancellationError { return .cancelled }
        return .other(String(describing: error))
    }
}
