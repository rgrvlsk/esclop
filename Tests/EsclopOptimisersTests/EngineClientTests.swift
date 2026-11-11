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
        let client = EngineClient(executable: try await FakeEngine.shared.executable(), cancelGrace: 1)
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
