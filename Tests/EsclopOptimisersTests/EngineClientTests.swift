// SPDX-License-Identifier: GPL-3.0-or-later
import EsclopCore
@testable import EsclopOptimisers
import Foundation
import Testing

@Suite struct EngineClientTests {
    func client() async throws -> EngineClient {
        EngineClient(executable: try await FakeEngine.shared.executable())
    }

    @Test func helloReportsCapabilities() async throws {
        let client = try await client()
        defer { Task { await client.shutdown() } }
        let caps = try await client.capabilities()
        #expect(caps.version == "fake-1")
        #expect(caps.supports("png.optimise"))
        #expect(!caps.supports("fit"))
        #expect(caps.canEncode("jpeg"))
        #expect(caps.canEncode("jpg"))
        #expect(!caps.canEncode("webp"))
    }

    @Test func repliesMayArriveOutOfOrder() async throws {
        let client = try await client()
        defer { Task { await client.shutdown() } }
        _ = try await client.call("sleep", params: ["seconds": 0.0]) // child started
        let order = LockedOrder()
        async let slow: Void = { _ = try await client.call("sleep", params: ["seconds": 4.0]); order.append("slow") }()
        try await Task.sleep(nanoseconds: 50_000_000)
        async let fast: Void = { _ = try await client.call("sleep", params: ["seconds": 0.05]); order.append("fast") }()
        _ = try await (slow, fast)
        #expect(order.values == ["fast", "slow"])
    }

    @Test func errorsMapToEsclopErrors() async throws {
        let client = try await client()
        defer { Task { await client.shutdown() } }
        await #expect(throws: EsclopError.unsupportedFile("unknown op frobnicate")) {
            try await client.call("frobnicate")
        }
        await #expect(throws: EsclopError.fileNotFound("missing input")) {
            try await client.call("png.optimise", input: URL(fileURLWithPath: "/nonexistent.png"), output: URL(fileURLWithPath: "/tmp/x.png"))
        }
        #expect(EngineClient.mapError(code: "already_smaller", message: "") == .alreadySmaller)
        #expect(EngineClient.mapError(code: "invalid_params", message: "bad") == .invalidArgument("bad"))
        #expect(EngineClient.mapError(code: "decode", message: "broken file") == .toolFailed(tool: "esclop-engine", exitCode: -1, stderr: "decode: broken file"))
        // With the input's kind known, a file the engine cannot read is a damaged file of that kind.
        #expect(EngineClient.mapError(code: "decode", message: "the cross-reference table misplaces object 5", kind: .pdf) == .unreadable(kind: .pdf))
        #expect(EngineClient.mapError(code: "decode", message: "bad", kind: .image) == .unreadable(kind: .image))
        // The engine's reason for leaving a file as it is becomes the message.
        let signed = "Signed PDFs are left as they are, so their signatures stay valid."
        #expect(EngineClient.mapError(code: "unsupported", message: "signed: /ByteRange", kind: .pdf, reason: signed) == .leftAsIs(signed))
        #expect(EngineClient.mapError(code: "unsupported", message: "not a PDF") == .unsupportedFile("not a PDF"))
    }

    @Test func progressEventsReachTheCaller() async throws {
        let client = try await client()
        defer { Task { await client.shutdown() } }
        let folder = try Harness.folder()
        let input = folder.appendingPathComponent("in.png")
        try Fixture.png(input)
        let fractions = Fractions()
        let reply = try await client.call("png.optimise", input: input, output: folder.appendingPathComponent("out.png"), params: ["lossy": true]) {
            fractions.add($0)
        }
        #expect(fractions.values == [0.5])
        #expect(reply.bytesAfter ?? .max < reply.bytesBefore ?? 0)
        #expect(reply.width == 320)
        #expect(reply.format == "png")
    }

    @Test func cancellationStopsWaitingAndTheClientKeepsWorking() async throws {
        let client = try await client()
        defer { Task { await client.shutdown() } }
        let started = Date()
        let task = Task { try await client.call("sleep", params: ["seconds": 30]) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        await #expect(throws: EsclopError.cancelled) { try await task.value }
        // The call sleeps 30 s; anything well below that proves cancellation stopped the wait.
        #expect(Date().timeIntervalSince(started) < 15)
        let reply = try await client.call("sleep", params: ["seconds": 0.01])
        #expect(reply.raw["slept"] != nil)
    }

    @Test func aTimedOutRequestFailsAndAStuckWorkerIsFreed() async throws {
        let client = EngineClient(executable: try await FakeEngine.shared.executable(), cancelGrace: 1, watchedOps: ["sleep"])
        defer { Task { await client.shutdown() } }
        _ = try await client.call("sleep", params: ["seconds": 0.0])
        let first = await client.childProcessIdentifier
        let started = Date()
        // A request that times out but stops when cancelled keeps the child.
        await #expect(throws: EsclopError.self) { try await client.call("sleep", params: ["seconds": 30], timeout: 0.3) }
        #expect(Date().timeIntervalSince(started) < 5)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(await client.childProcessIdentifier == first)
        // One that ignores the cancel holds its worker: after the grace the child is replaced.
        do {
            try await client.call("sleep", params: ["seconds": 30, "stuck": true], timeout: 0.3)
            Issue.record("no timeout")
        } catch let EsclopError.toolFailed(_, _, stderr) {
            #expect(stderr.contains("within 0.3 s"))
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(await client.childProcessIdentifier == nil)
        let reply = try await client.call("sleep", params: ["seconds": 0.01])
        #expect(reply.raw["slept"] != nil)
        #expect(await client.childProcessIdentifier != first)
    }

    @Test func timeQueuedDoesNotCountAndNothingRunningIsKilled() async throws {
        // Two workers, six jobs of 0.6 s, each allowed 1 s once started: the last ones wait
        // 1.2 s in the queue and must still finish, with the same child throughout.
        let client = EngineClient(executable: try await FakeEngine.shared.executable(), environment: ["FAKE_ENGINE_WORKERS": "2"], cancelGrace: 1, watchedOps: ["sleep"])
        defer { Task { await client.shutdown() } }
        _ = try await client.call("sleep", params: ["seconds": 0.0])
        let pid = await client.childProcessIdentifier
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 6 {
                group.addTask { _ = try await client.call("sleep", params: ["seconds": 0.6], timeout: 1) }
            }
            try await group.waitForAll()
        }
        #expect(await client.childProcessIdentifier == pid)
    }

    @Test func cancellingAQueuedRequestRestartsNothing() async throws {
        // One worker, held by a request that ignores cancels; a queued one is cancelled. The
        // engine answers it at once, so the child is not restarted for it.
        let client = EngineClient(executable: try await FakeEngine.shared.executable(), environment: ["FAKE_ENGINE_WORKERS": "1"], cancelGrace: 1, watchedOps: ["sleep"])
        defer { Task { await client.shutdown() } }
        _ = try await client.call("sleep", params: ["seconds": 0.0])
        let pid = await client.childProcessIdentifier
        let busy = Task { try await client.call("sleep", params: ["seconds": 30, "stuck": true]) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let queued = Task { try await client.call("sleep", params: ["seconds": 0.1]) }
        try await Task.sleep(nanoseconds: 300_000_000)
        queued.cancel()
        await #expect(throws: EsclopError.cancelled) { try await queued.value }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(await client.childProcessIdentifier == pid, "restarted for a request that never ran")
        busy.cancel()
    }

    @Test func cancellingAnOpThatDoesNotCheckForItRestartsNothing() async throws {
        // A long encode (here a request that ignores cancels) of an op outside the watched set,
        // like AVIF: cancelled, it fails at once, and the engine keeps running for the others.
        let client = EngineClient(executable: try await FakeEngine.shared.executable(), cancelGrace: 1)
        defer { Task { await client.shutdown() } }
        _ = try await client.call("sleep", params: ["seconds": 0.0])
        let pid = await client.childProcessIdentifier
        let slow = Task { try await client.call("sleep", params: ["seconds": 30, "stuck": true]) }
        try await Task.sleep(nanoseconds: 300_000_000)
        slow.cancel()
        await #expect(throws: EsclopError.cancelled) { try await slow.value }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(await client.childProcessIdentifier == pid, "the engine was restarted for an op that does not check for cancellation")
        let reply = try await client.call("sleep", params: ["seconds": 0.01])
        #expect(reply.raw["slept"] != nil)
        #expect(EngineClient.opsThatStopWhenCancelled == ["pdf.optimise"])
    }

    @Test func aCrashFailsTheRequestAndTheNextCallRestarts() async throws {
        let client = try await client()
        defer { Task { await client.shutdown() } }
        _ = try await client.capabilities()
        do {
            try await client.call("crash")
            Issue.record("crash should fail")
        } catch let EsclopError.toolFailed(tool, code, stderr) {
            #expect(tool == "esclop-engine")
            #expect(code == 3)
            #expect(stderr.contains("crashing on purpose"))
        }
        let caps = try await client.capabilities()
        #expect(caps.version == "fake-1")
    }

    @Test func missingEngineIsAToolMissingError() async throws {
        let client = EngineClient(locator: ToolLocator(searchDirectories: [], pathDirectories: []))
        #expect(!client.isInstalled)
        await #expect(throws: EsclopError.toolMissing("esclop-engine")) { try await client.capabilities() }
        #expect(await client.capabilitiesIfAvailable() == nil)
    }
}

final class Fractions: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func add(_ value: Double) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
}

@Suite struct EngineClientHelloTests {
    @Test func bareHelloRepliesNeverAnswerOtherRequests() async throws {
        let client = EngineClient(executable: try await FakeEngine.shared.executable(), environment: ["FAKE_ENGINE_BARE_HELLO": "1"])
        defer { Task { await client.shutdown() } }
        // Eleven calls first so ids sort differently as strings ("10" < "2").
        for _ in 0 ..< 10 { _ = try await client.call("sleep", params: ["seconds": 0.0]) }
        async let slow = client.call("sleep", params: ["seconds": 0.5])
        try await Task.sleep(nanoseconds: 50_000_000)
        let caps = try await client.capabilities()
        #expect(caps.version == "fake-1")
        let reply = try await slow
        #expect(reply.raw["slept"] == .double(0.5))
    }
}

final class LockedOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
