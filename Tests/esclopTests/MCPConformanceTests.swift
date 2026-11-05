// SPDX-License-Identifier: GPL-3.0-or-later
//
// End-to-end: launches the built `esclop mcp serve` and speaks newline-delimited JSON-RPC to it
// over stdio, as an agent would. Scripts/test.sh builds the binary first and passes its path in
// ESCLOP_TEST_BINARY.

import EsclopCore
import Foundation
import Testing

/// The `esclop` executable under test.
func esclopBinary() throws -> URL {
    let fm = FileManager.default
    if let path = ProcessInfo.processInfo.environment["ESCLOP_TEST_BINARY"], fm.isExecutableFile(atPath: path) {
        return URL(fileURLWithPath: path)
    }
    var candidates = Bundle.allBundles.filter { $0.bundlePath.hasSuffix(".xctest") }
        .map { $0.bundleURL.deletingLastPathComponent().appendingPathComponent("esclop") }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    candidates.append(root.appendingPathComponent(".build/debug/esclop"))
    guard let found = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) else {
        throw TestFailure("No esclop binary. Run Scripts/test.sh, or `swift build --product esclop` first.")
    }
    return found
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A running `esclop mcp serve` with line-at-a-time access to its stdout.
final class ServerProcess: @unchecked Sendable {
    let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSCondition()
    private var buffer = Data()
    private var lines: [String] = []
    private(set) var allLines: [String] = []
    private var closed = false
    private var eofCallbacks = 0
    let support: URL

    init(binary: URL) throws {
        support = FileManager.default.temporaryDirectory.appendingPathComponent("esclop-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        process.executableURL = binary
        process.arguments = ["mcp", "serve"]
        var environment = ProcessInfo.processInfo.environment
        environment["ESCLOP_SUPPORT_DIR"] = support.path
        environment["ESCLOP_NO_APP"] = "1"
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // Each handler clears itself at end of file. Foundation calls a handler again and again
        // for a pipe at EOF, so one left in place spins a thread for the rest of the run.
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.receive(data)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
                self?.countEOF()
            }
        }
        try process.run()
    }

    private func receive(_ data: Data) {
        lock.lock()
        defer { lock.broadcast(); lock.unlock() }
        if data.isEmpty { closed = true; eofCallbacks += 1; return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex ..< newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex ... newline)
            lines.append(line)
            allLines.append(line)
        }
    }

    private func countEOF() {
        lock.lock(); eofCallbacks += 1; lock.unlock()
    }

    /// How many times a handler has been called at end of file, both streams together.
    var endOfFileCallbacks: Int {
        lock.lock(); defer { lock.unlock() }
        return eofCallbacks
    }

    func send(_ line: String) {
        stdin.fileHandleForWriting.write(Data((line + "\n").utf8))
    }

    func send(_ message: [String: Any]) throws {
        send(String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self))
    }

    func nextLine(timeout: TimeInterval = 20) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock()
        defer { lock.unlock() }
        while lines.isEmpty, !closed {
            if !lock.wait(until: deadline) { return nil }
        }
        return lines.isEmpty ? nil : lines.removeFirst()
    }

    /// Sends a request and returns the response with the same id, skipping notifications.
    func request(_ id: Int, _ method: String, _ params: [String: Any]? = nil) throws -> [String: Any] {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        try send(message)
        while let line = nextLine() {
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                throw TestFailure("stdout carried a non-object line: \(line)")
            }
            if object["method"] != nil, object["id"] == nil { continue } // a notification
            guard (object["id"] as? Int) == id else { throw TestFailure("expected id \(id), got \(line)") }
            return object
        }
        throw TestFailure("no response to \(method) within the timeout")
    }

    func callTool(_ id: Int, _ name: String, _ arguments: [String: Any] = [:]) throws -> [String: Any] {
        let response = try request(id, "tools/call", ["name": name, "arguments": arguments])
        guard let result = response["result"] as? [String: Any] else { throw TestFailure("\(name) failed: \(response)") }
        return result
    }

    func closeInputAndWait(timeout: TimeInterval = 10) -> Int32? {
        try? stdin.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        guard !process.isRunning else { process.terminate(); return nil }
        return process.terminationStatus
    }

    deinit {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: support)
    }
}

@Suite(.serialized) struct MCPConformance {
    /// A readability handler that is not cleared at end of file is called again and again, so
    /// every server that exits would leave two threads spinning for the rest of the run. One
    /// server per core is enough to take every CPU, after which GCD stops serving its
    /// non-overcommit queues: Vision's smart crop waited there for ever and hung CI.
    @Test(.timeLimit(.minutes(1))) func serversThatExitLeaveNoHandlerSpinning() throws {
        let binary = try esclopBinary()
        let servers = try (0 ..< ProcessInfo.processInfo.activeProcessorCount).map { _ in try ServerProcess(binary: binary) }
        for server in servers { #expect(server.closeInputAndWait() == 0) }
        Thread.sleep(forTimeInterval: 0.3) // both pipes have reached end of file
        let settled = servers.map(\.endOfFileCallbacks)
        Thread.sleep(forTimeInterval: 0.5)
        let later = servers.map(\.endOfFileCallbacks)
        #expect(settled.allSatisfy { $0 <= 2 }, "end-of-file callbacks per server: \(settled)")
        #expect(later == settled, "handlers still running after end of file: \(settled) then \(later)")
    }

    @Test func initializeListCallAndShutDown() throws {
        let server = try ServerProcess(binary: try esclopBinary())

        // initialize
        let initialize = try server.request(1, "initialize", [
            "protocolVersion": "2025-11-25",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "conformance", "version": "1"],
        ])
        #expect(initialize["jsonrpc"] as? String == "2.0")
        let result = try #require(initialize["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-11-25")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "esclop-mcp")
        let capabilities = try #require(result["capabilities"] as? [String: Any])
        #expect(capabilities["tools"] != nil && capabilities["resources"] != nil && capabilities["prompts"] != nil)
        #expect((result["instructions"] as? String)?.isEmpty == false)
        try server.send(["jsonrpc": "2.0", "method": "notifications/initialized"])

        // tools/list
        let list = try server.request(2, "tools/list")
        let tools = try #require((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names.count == 25)
        #expect(names.isSuperset(of: ["esclop_optimise", "esclop_status", "esclop_settings_schema", "esclop_pipeline_write"]))
        for tool in tools {
            #expect((tool["inputSchema"] as? [String: Any])?["type"] as? String == "object")
        }

        // esclop_status
        let status = try server.callTool(3, "esclop_status")
        #expect(status["isError"] as? Bool != true)
        let statusContent = try #require(status["content"] as? [[String: Any]])
        #expect(statusContent.first?["type"] as? String == "text")
        let structured = try #require(status["structuredContent"] as? [String: Any])
        #expect(structured["route"] as? String == "in-process")
        #expect((structured["mcpClient"] as? [String: Any])?["name"] as? String == "conformance")

        // esclop_settings_schema
        let schema = try server.callTool(4, "esclop_settings_schema")
        let settings = try #require((schema["structuredContent"] as? [String: Any])?["settings"] as? [[String: Any]])
        #expect(settings.contains { $0["key"] as? String == "allowOverwriteOriginals" })

        // A pipeline round trip in the temporary support folder.
        let file = server.support.appendingPathComponent("pipelines/e2e web.pipeline")
        let write = try server.callTool(5, "esclop_pipeline_write", ["name": "e2e web", "steps": "crop(longEdge: 1600) -> convert(to: webp)"])
        #expect(write["isError"] as? Bool != true, "\(write)")
        #expect(FileManager.default.fileExists(atPath: file.path))
        let show = try server.callTool(6, "esclop_pipeline_show", ["name": "e2e web"])
        let shown = try #require((show["content"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(shown.contains("convert(to: webp)"))
        let delete = try server.callTool(7, "esclop_pipeline_delete", ["name": "e2e web"])
        #expect(delete["isError"] as? Bool != true)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let gone = try server.callTool(8, "esclop_pipeline_show", ["name": "e2e web"])
        #expect(gone["isError"] as? Bool == true)

        // Errors keep the framing.
        let unknown = try server.request(9, "no/such/method")
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
        let ping = try server.request(10, "ping")
        #expect(ping["result"] != nil)

        // Every line on stdout was one JSON-RPC message.
        for line in server.allLines {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            #expect(object?["jsonrpc"] as? String == "2.0", "\(line)")
        }

        #expect(server.closeInputAndWait() == 0, "exits cleanly when the client closes stdin")
    }

    @Test func callsInFlightStillAnswerAfterStdinCloses() throws {
        let server = try ServerProcess(binary: try esclopBinary())
        _ = try server.request(1, "initialize", ["protocolVersion": "2025-11-25", "capabilities": [String: Any](), "clientInfo": ["name": "t", "version": "1"]])
        try server.send(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "esclop_pipeline_list", "arguments": [String: Any]()]])
        let status = server.closeInputAndWait()
        let line = try #require(server.nextLine(timeout: 1))
        let response = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(response["id"] as? Int == 2)
        #expect(status == 0)
    }
}
