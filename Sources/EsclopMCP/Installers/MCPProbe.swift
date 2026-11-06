// SPDX-License-Identifier: GPL-3.0-or-later
//
// Starts the MCP server the way an agent does (the command and arguments written into its
// config), speaks the opening of a session over stdio — initialize, initialized, tools/list,
// esclop_status — and reports what came back. The Settings window's "Test" button and its tests
// use it; `Scripts/mcp-smoke.sh` is the shell version.

import EsclopCore
import EsclopIPC
import Foundation

public struct MCPProbeReport: Sendable, Equatable {
    public var serverName: String
    public var serverVersion: String
    public var protocolVersion: String
    public var toolCount: Int
    /// Whether jobs from this server would run in the app (`app`) or in its own process.
    public var route: String?
    public var appRunning: Bool?
    public var elapsed: Duration

    public init(serverName: String, serverVersion: String, protocolVersion: String, toolCount: Int, route: String?, appRunning: Bool?, elapsed: Duration) {
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.protocolVersion = protocolVersion
        self.toolCount = toolCount
        self.route = route
        self.appRunning = appRunning
        self.elapsed = elapsed
    }

    /// "esclop-mcp 0.1.0 answered in 180 ms: protocol 2025-11-25, 24 tools, jobs run in the app."
    public var summary: String {
        let ms = Int((Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15).rounded())
        var text = "\(serverName) \(serverVersion) answered in \(ms) ms: protocol \(protocolVersion), \(toolCount) tools"
        switch route {
        case "app"?: text += ", jobs run in the app"
        case let other?: text += ", jobs run \(other)"
        case nil: break
        }
        return text + "."
    }
}

public enum MCPProbe {
    public static let protocolVersion = "2025-11-25"

    public static func run(_ command: ServerCommand, environment: [String: String]? = nil, timeout: Duration = .seconds(10)) async throws -> MCPProbeReport {
        guard FileManager.default.isExecutableFile(atPath: command.command) else {
            throw EsclopError.invalidArgument("\(command.command) is not an executable file. Install the esclop command line or connect the agent again")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.command)
        process.arguments = command.args
        if let environment { process.environment = environment }
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A server that exits early must not take the caller down: writing to its closed stdin
        // raises SIGPIPE, which kills a process by default. This pipe reports EPIPE instead.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let started = ContinuousClock.now
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        func send(_ line: String) throws {
            try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
        }
        try send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(protocolVersion)","capabilities":{},"clientInfo":{"name":"esclop-settings-test","version":"\#(EsclopVersion.string)"}}}"#)

        let reader = Task<MCPProbeReport, any Error> {
            var initialize: JSONValue?
            var tools: JSONValue?
            for try await line in output.fileHandleForReading.bytes.lines {
                let message = JSONValue(parsing: line)
                // Only responses count: a request echoed back, or a notification, is not an answer.
                guard message["method"] == nil, message["result"] != nil || message["error"] != nil else { continue }
                if let error = message["error"]?["message"]?.stringValue {
                    throw EsclopError.other("The server refused the request: \(error)")
                }
                switch message["id"]?.intValue {
                case 1?:
                    initialize = message["result"]
                    try send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
                    try send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
                case 2?:
                    tools = message["result"]
                    try send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"esclop_status","arguments":{}}}"#)
                case 3?:
                    let status = message["result"]?["structuredContent"]
                    return MCPProbeReport(
                        serverName: initialize?["serverInfo"]?["name"]?.stringValue ?? "?",
                        serverVersion: initialize?["serverInfo"]?["version"]?.stringValue ?? "?",
                        protocolVersion: initialize?["protocolVersion"]?.stringValue ?? "?",
                        toolCount: tools?["tools"]?.arrayValue?.count ?? 0,
                        route: status?["route"]?.stringValue,
                        appRunning: status?["app"]?["running"]?.boolValue,
                        elapsed: ContinuousClock.now - started
                    )
                default:
                    continue
                }
            }
            throw EsclopError.other("The server closed the connection before answering\(initialize == nil ? "" : " the tool list")")
        }
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            reader.cancel()
            process.terminate()
        }
        defer { watchdog.cancel() }
        do {
            return try await reader.value
        } catch {
            if !watchdog.isCancelled, ContinuousClock.now - started >= timeout {
                throw EsclopError.other("The server did not answer within \(timeout.components.seconds) s")
            }
            throw error
        }
    }
}
