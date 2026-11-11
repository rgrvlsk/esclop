// SPDX-License-Identifier: GPL-3.0-or-later

import EsclopCore
@testable import EsclopIPC
import Foundation
import Testing

@Suite struct EnvelopeRoundTrips {
    static let operations: [JobOperation] = [
        .optimise, .convert(.webp), .convert(.gifVideo), .downscale(0.5),
        .crop(CropSize(width: 1200, height: 630, smart: true)), .crop(CropSize(aspectRatio: "16:9")),
        .fit(underBytes: 2_000_000), .stripMetadata, .pipeline("to-webp"), .pipeline("crop(width: 10) -> convert(to: png)"),
        .cropPDF(PDFCropSpec(aspectRatio: 0.75, extend: true)), .uncropPDF,
    ]

    @Test(arguments: operations)
    func jobs(_ operation: JobOperation) throws {
        let request = OptimisationRequest(
            sources: [URL(fileURLWithPath: "/tmp/a b.png"), URL(fileURLWithPath: "/tmp/ü.mov")], origin: .mcp,
            quality: CompressionQuality(tier: .custom, factor: 42), format: .avif, downscale: 0.25,
            crop: CropSize(longEdge: 800), targetBytes: 1000, stripMetadata: true, removeAudio: true, playbackSpeed: 2,
            videoEncoder: .hevcVideoToolbox, pdfDPI: 150, location: .path("~/out/%f.%e"), pipeline: "p", showResultUI: false
        )
        let job = OptimisationJob(request: request, operation: operation)
        #expect(try roundTrips(job))
        let decoded = try IPCEnvelope<OptimisationJob>.decode(try IPCEnvelope(body: job).encoded()).body
        #expect(decoded.operation == operation)
        #expect(decoded.request.id == request.id)
        #expect(decoded.request.location == .path("~/out/%f.%e"))
        #expect(decoded.request.origin == .mcp)
    }

    @Test func locations() throws {
        for location in [OutputLocation.inPlace, .sameFolder, .temporary, .path("/x")] {
            var request = OptimisationRequest(sources: [], origin: .cli)
            request.location = location
            let decoded = try IPCEnvelope<OptimisationJob>.decode(try IPCEnvelope(body: OptimisationJob(request: request, operation: .optimise)).encoded())
            #expect(decoded.body.request.location == location)
        }
    }

    @Test func controlMessages() throws {
        #expect(try roundTrips(StopRequest(ids: [UUID(), UUID()], remove: true)))
        for command in [SettingsCommand.schema(query: nil), .schema(query: "pdf"), .get(key: "a"), .set(key: "a", value: "true")] {
            #expect(try roundTrips(SettingsCall(command: command, origin: .mcp)))
        }
        for command in [ControlCommand.status, .recentResults(limit: 5), .quit] {
            #expect(try roundTrips(command))
        }
    }

    static let errors: [EsclopError] = [
        .unsupportedFile("x"), .fileNotFound("y"), .toolMissing("ffmpeg"), .toolFailed(tool: "ffmpeg", exitCode: 3, stderr: "boom"),
        .alreadySmaller, .cancelled, .notPermitted("no"), .invalidPipeline("bad"), .invalidArgument("arg"), .appNotRunning, .other("x"),
    ]

    @Test(arguments: errors)
    func failures(_ error: EsclopError) throws {
        let event = AppEvent.failure(FileFailure(source: URL(fileURLWithPath: "/tmp/a.png"), error: error))
        #expect(try roundTrips(event))
        guard case let .failure(decoded) = try IPCEnvelope<AppEvent>.decode(try IPCEnvelope(body: event).encoded()).body else {
            Issue.record("not a failure"); return
        }
        #expect(decoded.error == error)
        #expect(try roundTrips(AppEvent.refused(error)))
    }

    @Test func replies() throws {
        let events: [AppEvent] = [
            .accepted, .finished, .done,
            .progress(OptimisationProgress(requestID: UUID(), source: URL(fileURLWithPath: "/tmp/a"), fraction: -1, message: "x")),
            .result(sampleResult()),
            .settings(.descriptors(AgentPermission.allCases.map(\.descriptor))),
            .settings(.value(key: "k", value: ["a": [1, 2.5, "s", true, .null]])),
            .status(AppStatus(version: "1", pid: 42, activeJobs: 3)),
            .results([sampleResult("a.png"), sampleResult("b.jpg")]),
        ]
        for event in events { #expect(try roundTrips(event)) }

        // Dates and sizes survive exactly.
        guard case let .result(decoded) = try IPCEnvelope<AppEvent>.decode(try IPCEnvelope(body: AppEvent.result(sampleResult())).encoded()).body else {
            Issue.record("not a result"); return
        }
        #expect(decoded.startedAt == sampleResult().startedAt)
        #expect(decoded.savedBytes == 1500)
        #expect(decoded.backup?.path == "/tmp/backup-a.png")
    }

    @Test func versionMismatchIsRefused() throws {
        var envelope = IPCEnvelope(body: ControlCommand.status)
        envelope.version = 99
        #expect(throws: EsclopError.self) { try IPCEnvelope<ControlCommand>.decode(try envelope.encoded()) }
    }

    @Test func garbageIsRefused() {
        #expect(throws: (any Error).self) { try IPCEnvelope<OptimisationJob>.decode(Data("{\"nope\":1}".utf8)) }
    }

    @Test func portNames() {
        let ports = IPCPorts.default
        #expect(ports.request == "dev.esclop.app.request")
        #expect(ports.stop == "dev.esclop.app.stop")
        #expect(ports.settings == "dev.esclop.app.settings")
        #expect(ports.control == "dev.esclop.app.control")
        let reply = ports.reply(UUID())
        #expect(reply.hasPrefix("dev.esclop.app.reply."))
        #expect(reply.utf8.count < 128)
    }
}

// MARK: - Live client and server

/// An app stand-in: emits progress, then a result or failure per file.
final class FakeHandler: AppRequestHandler, @unchecked Sendable {
    let settings = InMemorySettingsProvider()
    let lock = NSLock()
    var stopped: [UUID] = []
    var quitCalled = false
    enum Speed { case fast, slowCancellable, slowStubborn }
    let speed: Speed

    init(speed: Speed = .fast) { self.speed = speed }

    func perform(_ job: OptimisationJob, events: @escaping @Sendable (JobEvent) -> Void) async throws {
        if job.request.origin == .mcp, job.request.location == .inPlace {
            throw EsclopError.notPermitted("in place")
        }
        for source in job.request.sources {
            switch speed {
            case .fast: break
            case .slowCancellable: try await Task.sleep(nanoseconds: 5_000_000_000)
            case .slowStubborn:
                // Like a crashed app: no cancellation, no reply.
                await withCheckedContinuation { done in DispatchQueue.global().asyncAfter(deadline: .now() + 5) { done.resume() } }
            }
            events(.progress(OptimisationProgress(requestID: job.id, source: source, fraction: 0.5)))
            if source.lastPathComponent.hasPrefix("missing") {
                events(.failure(FileFailure(source: source, error: .fileNotFound(source.path))))
            } else {
                events(.result(OptimisationResult(source: source, output: source, kind: .image, bytesBefore: 10, bytesAfter: 4, startedAt: Date(), finishedAt: Date())))
            }
        }
    }

    func stop(_ request: StopRequest) async {
        lock.lock(); stopped += request.ids; lock.unlock()
    }

    func settings(_ command: SettingsCommand, origin: RequestOrigin) async throws -> SettingsReply {
        switch command {
        case let .schema(query): return .descriptors(settings.search(query))
        case let .get(key): return .value(key: key, value: try settings.value(forKey: key))
        case let .set(key, value):
            if origin == .mcp { throw EsclopError.notPermitted("agents cannot") }
            return .value(key: key, value: try settings.setValue(value, forKey: key))
        }
    }

    func status() async -> AppStatus { AppStatus(version: "test", pid: getpid(), activeJobs: 0) }
    func recentResults(limit: Int) async -> [OptimisationResult] { Array([sampleResult("a.png"), sampleResult("b.png")].prefix(limit)) }
    func quit() async { lock.lock(); quitCalled = true; lock.unlock() }
}

@Suite(.serialized) struct LiveIPC {
    func ports() -> IPCPorts { IPCPorts(prefix: "dev.esclop.test.\(UUID().uuidString.prefix(8))") }

    @Test func appNotRunning() async throws {
        let client = AppClient(ports: ports())
        #expect(!client.isAppRunning)
        await #expect(throws: EsclopError.appNotRunning) {
            _ = try await client.perform(OptimisationJob(request: OptimisationRequest(sources: [], origin: .cli), operation: .optimise))
        }
        await #expect(throws: EsclopError.appNotRunning) { _ = try await client.status() }
        #expect(throws: EsclopError.appNotRunning) { try client.stop([UUID()]) }
    }

    @Test func jobStreamsProgressAndResults() async throws {
        let ports = ports()
        let server = AppServer(handler: FakeHandler(), ports: ports)
        try server.start()
        defer { server.stop() }
        let client = AppClient(ports: ports)
        #expect(client.isAppRunning)

        let files = [URL(fileURLWithPath: "/tmp/one.png"), URL(fileURLWithPath: "/tmp/missing.png"), URL(fileURLWithPath: "/tmp/two.png")]
        let counter = Counter()
        let report = try await client.perform(OptimisationJob(request: OptimisationRequest(sources: files, origin: .cli), operation: .optimise)) { _ in counter.add() }
        #expect(report.route == "app")
        #expect(report.results.map(\.source.lastPathComponent) == ["one.png", "two.png"])
        #expect(report.failures.map(\.error) == [.fileNotFound("/tmp/missing.png")])
        #expect(counter.value == 3)
    }

    @Test func refusalIsThrown() async throws {
        let ports = ports()
        let server = AppServer(handler: FakeHandler(), ports: ports)
        try server.start()
        defer { server.stop() }
        await #expect(throws: EsclopError.notPermitted("in place")) {
            _ = try await AppClient(ports: ports).perform(OptimisationJob(request: OptimisationRequest(sources: [URL(fileURLWithPath: "/tmp/a.png")], origin: .mcp), operation: .optimise))
        }
    }

    @Test func settingsStatusAndResults() async throws {
        let ports = ports()
        let handler = FakeHandler()
        let server = AppServer(handler: handler, ports: ports)
        try server.start()
        defer { server.stop() }
        let client = AppClient(ports: ports)

        guard case let .descriptors(all) = try await client.settings(.schema(query: "scripts"), origin: .cli) else { Issue.record("no schema"); return }
        #expect(all.map(\.key) == ["allowRunScripts"])
        guard case let .value(_, set) = try await client.settings(.set(key: "allowRunScripts", value: "yes"), origin: .cli) else { Issue.record("no value"); return }
        #expect(set == .bool(true))
        guard case let .value(_, got) = try await client.settings(.get(key: "allowRunScripts"), origin: .cli) else { Issue.record("no value"); return }
        #expect(got == .bool(true))
        await #expect(throws: EsclopError.notPermitted("agents cannot")) { _ = try await client.settings(.set(key: "allowRunScripts", value: "no"), origin: .mcp) }

        #expect(try await client.status().pid == getpid())
        #expect(try await client.recentResults(limit: 1).count == 1)
    }

    @Test func stopReachesTheApp() async throws {
        let ports = ports()
        let handler = FakeHandler(speed: .slowCancellable)
        let server = AppServer(handler: handler, ports: ports)
        try server.start()
        defer { server.stop() }
        let client = AppClient(ports: ports)
        let job = OptimisationJob(request: OptimisationRequest(sources: [URL(fileURLWithPath: "/tmp/slow.png")], origin: .cli), operation: .optimise)
        let started = Date()
        let task = Task { try await client.perform(job) }
        try await Task.sleep(nanoseconds: 300_000_000)
        try client.stop([job.id])
        let report = try await task.value
        #expect(Date().timeIntervalSince(started) < 4, "the job's task was cancelled")
        #expect(report.results.isEmpty)
        try await Task.sleep(nanoseconds: 200_000_000)
        handler.lock.lock(); defer { handler.lock.unlock() }
        #expect(handler.stopped == [job.id])
    }

    @Test func vanishedAppIsDetected() async throws {
        let ports = ports()
        let server = AppServer(handler: FakeHandler(speed: .slowStubborn), ports: ports)
        try server.start()
        let client = AppClient(ports: ports)
        let job = OptimisationJob(request: OptimisationRequest(sources: [URL(fileURLWithPath: "/tmp/slow.png")], origin: .cli), operation: .optimise)
        let task = Task { try await client.perform(job) }
        try await Task.sleep(nanoseconds: 300_000_000)
        server.stop()
        // Accepted before it vanished: reported, and not mistaken for "never started".
        do {
            _ = try await task.value
            Issue.record("expected an error")
        } catch let error as EsclopError {
            #expect(error != .appNotRunning)
            #expect(error.description.contains("quit while working"))
        }
    }

    @Test func versionMismatchIsRefusedNotIgnored() async throws {
        let ports = ports()
        let server = AppServer(handler: FakeHandler(), ports: ports)
        try server.start()
        defer { server.stop() }
        let id = UUID()
        let replyName = ports.reply(id)
        let (stream, continuation) = AsyncStream<AppEvent>.makeStream()
        let listener = try LocalMessagePort(name: replyName) { data in
            if let envelope = try? IPCEnvelope<AppEvent>.decode(data) { continuation.yield(envelope.body) }
        }
        defer { listener.invalidate() }
        var envelope = IPCEnvelope(id: id, replyPort: replyName, body: ControlCommand.status)
        envelope.version = 99
        try RemoteMessagePort.send(try envelope.encoded(), to: ports.control)
        for await event in stream {
            guard case let .refused(error) = event else { Issue.record("expected a refusal"); break }
            #expect(error.description.contains("version"))
            break
        }
    }

    @Test func silentAppTimesOutOnAcceptance() async throws {
        let ports = ports()
        // A port that takes messages and never answers, like an app on another protocol.
        let mute = try LocalMessagePort(name: ports.request) { _ in }
        defer { mute.invalidate() }
        var client = AppClient(ports: ports)
        client.acceptTimeout = 0.6
        await #expect(throws: EsclopError.self) {
            _ = try await client.perform(OptimisationJob(request: OptimisationRequest(sources: [], origin: .cli), operation: .optimise))
        }
    }

    @Test func secondServerCannotTakeThePorts() throws {
        let ports = ports()
        let first = AppServer(handler: FakeHandler(), ports: ports)
        try first.start()
        defer { first.stop() }
        #expect(throws: EsclopError.self) { try AppServer(handler: FakeHandler(), ports: ports).start() }
    }

    @Test func quit() async throws {
        let ports = ports()
        let handler = FakeHandler()
        let server = AppServer(handler: handler, ports: ports)
        try server.start()
        let client = AppClient(ports: ports)
        // The fake does not exit, so stop the ports as the app would on terminate.
        let stopper = Task { try await Task.sleep(nanoseconds: 300_000_000); server.stop() }
        try await client.quit(timeout: 5)
        _ = try await stopper.value
        handler.lock.lock(); defer { handler.lock.unlock() }
        #expect(handler.quitCalled)
        #expect(!client.isAppRunning)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

extension JobOperation: CustomTestStringConvertible {
    public var testDescription: String { name }
}

extension EsclopError: CustomTestStringConvertible {
    public var testDescription: String { code }
}
