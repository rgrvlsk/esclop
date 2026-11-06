// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Settings window's live test against the real `esclop mcp serve`.

import EsclopMCP
import Foundation
import Testing

@Suite struct MCPProbeTests {
    func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["ESCLOP_NO_APP"] = "1"
        environment["ESCLOP_SUPPORT_DIR"] = FileManager.default.temporaryDirectory.appendingPathComponent("esclop-probe-\(UUID().uuidString)").path
        return environment
    }

    @Test func handshakeWithTheRealServer() async throws {
        let binary = try esclopBinary()
        let report = try await MCPProbe.run(ServerCommand(command: binary.path), environment: environment())
        #expect(report.serverName == "esclop-mcp")
        #expect(report.protocolVersion == MCPProbe.protocolVersion)
        #expect(report.toolCount >= 20, "every esclop_* tool is listed")
        #expect(report.route == "in-process", "ESCLOP_NO_APP keeps jobs in the server")
        #expect(report.appRunning != nil, "the app may or may not run on this Mac; the server says which")
        #expect(report.summary.contains("answered in"))
    }

    @Test func aMissingBinaryIsExplained() async {
        await #expect(throws: (any Error).self) {
            _ = try await MCPProbe.run(ServerCommand(command: "/nonexistent/esclop"))
        }
    }

    @Test func aServerThatNeverAnswersTimesOut() async throws {
        // `cat` reads the request and never answers in JSON-RPC.
        let started = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            _ = try await MCPProbe.run(ServerCommand(command: "/bin/cat", args: []), timeout: .seconds(1))
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func aServerThatExitsIsReported() async {
        await #expect(throws: (any Error).self) {
            _ = try await MCPProbe.run(ServerCommand(command: "/usr/bin/true", args: []))
        }
    }
}
