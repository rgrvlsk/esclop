// SPDX-License-Identifier: GPL-3.0-or-later
//
// `esclop mcp serve`: the MCP server over stdio, on the official MCP Swift SDK. stdout carries
// JSON-RPC only; diagnostics go to stderr.

import EsclopCore
import EsclopIPC
import Foundation
import MCP

/// What the client said about itself at `initialize`.
public actor ClientState {
    public struct Snapshot: Sendable {
        public var name: String
        public var version: String
        public var elicitation: Bool
    }

    private var snapshot = Snapshot(name: "", version: "", elicitation: false)

    public init() {}

    func record(_ info: Client.Info, _ capabilities: Client.Capabilities) {
        // An empty `"elicitation": {}` means form mode, per the 2025-11-25 spec.
        let elicitation = capabilities.elicitation.map { $0.form != nil || $0.url == nil } ?? false
        snapshot = Snapshot(name: info.name, version: info.version, elicitation: elicitation)
    }

    public var current: Snapshot { snapshot }
}

/// Counts tool calls in flight, so `serve` can let them finish after the client closes stdin.
actor InFlight {
    private var count = 0
    func enter() { count += 1 }
    func leave() { count -= 1 }
    var isIdle: Bool { count == 0 }
}

public struct EsclopMCPServer: Sendable {
    public static let name = "esclop-mcp"

    public let service: EsclopService
    public let elicitationTimeout: TimeInterval

    public init(service: EsclopService, elicitationTimeout: TimeInterval = 120) {
        self.service = service
        self.elicitationTimeout = elicitationTimeout
    }

    public static let instructions = """
    L'Esclop makes images, videos, PDFs and audio smaller and converts, crops and resizes them, on this Mac.

    - Every tool takes local paths (absolute, ~/..., or file:// URLs). Lists of files and folders are fine.
    - The person decides what agents may do. By default L'Esclop never overwrites an original: results are \
    written next to it and the output path comes back in the result. esclop_status shows what is allowed. \
    When a tool is refused with notPermitted, tell the person which switch it names; do not work around it.
    - "Smaller" can mean compression (esclop_optimise, same pixels), resolution (esclop_downscale), a byte \
    limit (esclop_fit_under_size) or a format (esclop_convert to webp/avif). If the person's words do not \
    say which, ask them before calling.
    - Some tools ask the person directly (elicitation) when a choice is missing. If the client cannot show \
    the question, the tool fails with the options: ask in the chat and call again with the answer.
    - Pipelines are saved step sequences in a small DSL; the write_pipeline prompt has the reference. \
    Attaching a pipeline to a folder or the clipboard makes L'Esclop process files automatically from then \
    on: say so before attaching.
    """

    /// Starts a server on `transport` (stdio in production, in-memory in tests).
    public func start(transport: any Transport) async throws -> Server {
        try await start(transport: transport, inFlight: InFlight())
    }

    func start(transport: any Transport, inFlight: InFlight) async throws -> Server {
        let server = Server(
            name: Self.name, version: EsclopVersion.string, title: "esclop", instructions: Self.instructions,
            capabilities: .init(
                prompts: .init(listChanged: false),
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )
        let client = ClientState()
        await register(on: server, client: client, inFlight: inFlight)
        try await server.start(transport: transport) { info, capabilities in
            await client.record(info, capabilities)
            log("client \(info.name) \(info.version)")
        }
        return server
    }

    /// Serves stdin/stdout until the client closes stdin and every call has answered.
    public func serveStdio() async throws {
        let inFlight = InFlight()
        log("serving on stdio (esclop \(EsclopVersion.string))")
        let server = try await start(transport: StdioTransport(), inFlight: inFlight)
        await server.waitUntilCompleted()
        // stdin closed. Calls already running still answer: the transport keeps writing.
        let deadline = Date().addingTimeInterval(3600)
        while !(await inFlight.isIdle), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        await server.stop()
    }

    func register(on server: Server, client: ClientState, inFlight: InFlight) async {
        let service = service
        let timeout = elicitationTimeout
        let elicitor = Elicitor(
            supported: { await client.current.elicitation },
            request: { [weak server] message, schema in
                guard let server else { throw ToolFailure("The server stopped") }
                return try await server.requestElicitation(message: message, requestedSchema: schema)
            },
            timeout: timeout
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: ToolCatalog.all.map(\.tool))
        }

        await server.withMethodHandler(CallTool.self) { params in
            await inFlight.enter()
            defer { Task { await inFlight.leave() } }
            guard let spec = ToolCatalog.byName[params.name] else {
                return ToolOutput("Unknown tool \(params.name). Tools: \(ToolCatalog.all.map(\.tool.name).joined(separator: ", "))", isError: true).result
            }
            let call = ToolCall(
                name: params.name, arguments: ToolArguments(params.arguments), service: service,
                elicitor: elicitor, client: await client.current
            )
            do {
                return try await spec.run(call).result
            } catch let failure as ToolFailure {
                return ToolOutput(failure.message, structured: ["error": .string(failure.message), "code": .string(failure.code)], isError: true).result
            } catch {
                let wrapped = EsclopError.wrap(error)
                return ToolOutput(wrapped.description, structured: ["error": .string(wrapped.description), "code": .string(wrapped.code)], isError: true).result
            }
        }

        await server.withMethodHandler(ListResources.self) { _ in
            ListResources.Result(resources: MCPResources.list(service: service))
        }
        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            ListResourceTemplates.Result(templates: MCPResources.templates)
        }
        await server.withMethodHandler(ReadResource.self) { params in
            ReadResource.Result(contents: try await MCPResources.read(params.uri, service: service))
        }

        await server.withMethodHandler(ListPrompts.self) { _ in
            ListPrompts.Result(prompts: MCPPrompts.all)
        }
        await server.withMethodHandler(GetPrompt.self) { params in
            try MCPPrompts.get(params.name, arguments: params.arguments ?? [:])
        }
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[esclop-mcp] \(message)\n".utf8))
}
