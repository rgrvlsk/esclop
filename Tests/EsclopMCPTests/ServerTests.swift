// SPDX-License-Identifier: GPL-3.0-or-later

import EsclopCore
import EsclopIPC
@testable import EsclopMCP
import Foundation
import MCP
import Testing

/// A connected client and server over the SDK's in-memory transport.
struct Session {
    let client: Client
    let server: Server
    let engine: FakeEngine
    let temp: TempDir

    enum Elicit: Sendable {
        case unsupported
        case answer([String: Value])
        case decline
        case never
    }

    static func start(_ elicit: Elicit = .unsupported, allow: [AgentPermission] = [], timeout: TimeInterval = 5) async throws -> Session {
        let temp = TempDir()
        let engine = FakeEngine()
        let service = makeService(temp, origin: .mcp, allow: allow, engine: engine)
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = try await EsclopMCPServer(service: service, elicitationTimeout: timeout).start(transport: serverTransport)
        var capabilities = Client.Capabilities()
        if case .unsupported = elicit {} else { capabilities.elicitation = .init() }
        let client = Client(name: "esclop-tests", version: "1", capabilities: capabilities)
        await client.withElicitationHandler { _ in
            switch elicit {
            case let .answer(content): return CreateElicitation.Result(action: .accept, content: content)
            case .decline: return CreateElicitation.Result(action: .decline)
            case .never, .unsupported:
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return CreateElicitation.Result(action: .cancel)
            }
        }
        _ = try await client.connect(transport: clientTransport)
        return Session(client: client, server: server, engine: engine, temp: temp)
    }

    /// The text blocks of a tool result and its error flag.
    func call(_ name: String, _ arguments: [String: Value] = [:]) async throws -> (text: String, json: String, isError: Bool) {
        let (content, isError) = try await client.callTool(name: name, arguments: arguments)
        let texts = content.compactMap { item -> String? in
            if case let .text(text, _, _) = item { return text }
            return nil
        }
        return (texts.first ?? "", texts.dropFirst().first ?? "", isError ?? false)
    }

    func stop() async {
        await client.disconnect()
        await server.stop()
    }
}

@Suite(.serialized) struct MCPServerInMemory {
    static let expectedTools: Set<String> = [
        "esclop_optimise", "esclop_convert", "esclop_downscale", "esclop_crop", "esclop_fit_under_size", "esclop_strip_metadata",
        "esclop_crop_pdf", "esclop_uncrop_pdf", "esclop_pipeline_list", "esclop_pipeline_show", "esclop_pipeline_write",
        "esclop_pipeline_delete", "esclop_pipeline_run", "esclop_pipeline_attach", "esclop_pipeline_detach", "esclop_pipeline_preset",
        "esclop_settings_schema", "esclop_settings_get", "esclop_settings_set", "esclop_status", "esclop_start_app",
        "esclop_stop_app", "esclop_recent_results", "esclop_restore_backup", "esclop_logs",
    ]

    @Test func listsEveryTool() async throws {
        let session = try await Session.start()
        defer { Task { await session.stop() } }
        let (tools, _) = try await session.client.listTools()
        #expect(Set(tools.map(\.name)) == Self.expectedTools)
    }

    @Test func elicitationFillsAMissingFormat() async throws {
        let session = try await Session.start(.answer(["format": "webp"]))
        defer { Task { await session.stop() } }
        let file = session.temp.file("a.png")
        let result = try await session.call("esclop_convert", ["paths": .array([.string(file.path)])])
        #expect(!result.isError, "\(result.text)")
        #expect(session.engine.calls == ["convert:webp"])
        #expect(result.json.contains("\"savedPercent\""))
    }

    @Test func declinedElicitationChangesNothing() async throws {
        let session = try await Session.start(.decline)
        defer { Task { await session.stop() } }
        let result = try await session.call("esclop_downscale", ["paths": .string(session.temp.file("a.png").path)])
        #expect(result.isError)
        #expect(result.text.contains("declined"))
        #expect(session.engine.calls.isEmpty)
    }

    @Test func clientsWithoutElicitationGetTheOptions() async throws {
        let session = try await Session.start(.unsupported)
        defer { Task { await session.stop() } }
        let result = try await session.call("esclop_fit_under_size", ["paths": .array([.string(session.temp.file("a.png").path)])])
        #expect(result.isError)
        #expect(result.text.contains("does not support elicitation"))
        #expect(result.text.contains("maxSize"))
        #expect(result.json.contains("needsInput"))
    }

    @Test func agentsCannotOverwriteOrGrantThemselvesPermissions() async throws {
        let session = try await Session.start()
        defer { Task { await session.stop() } }
        let file = session.temp.file("a.png")
        let overwrite = try await session.call("esclop_optimise", ["paths": .array([.string(file.path)]), "location": "inPlace"])
        #expect(overwrite.isError)
        #expect(overwrite.text.contains("allowOverwriteOriginals"))
        let grant = try await session.call("esclop_settings_set", ["key": "allowOverwriteOriginals", "value": "true"])
        #expect(grant.isError)
        #expect(grant.text.contains("only be changed by the person"))
        // Without a location, the result goes next to the original.
        let ok = try await session.call("esclop_optimise", ["paths": .array([.string(file.path)])])
        #expect(!ok.isError, "\(ok.text)")
    }

    @Test func missingFilesAndBadArgumentsAreClear() async throws {
        let session = try await Session.start()
        defer { Task { await session.stop() } }
        let missing = try await session.call("esclop_optimise", ["paths": .array([.string(session.temp.url.appendingPathComponent("nope.png").path)])])
        #expect(missing.isError)
        #expect(missing.json.contains("fileNotFound"))
        let noPaths = try await session.call("esclop_optimise", [:])
        #expect(noPaths.isError)
        #expect(noPaths.text.contains("paths is required"))
        let unknown = try await session.call("esclop_teleport")
        #expect(unknown.isError)
    }

    @Test func pipelineRoundTrip() async throws {
        let session = try await Session.start()
        defer { Task { await session.stop() } }
        let write = try await session.call("esclop_pipeline_write", ["name": "web", "steps": "crop(longEdge: 1600) -> convert(to: webp)"])
        #expect(!write.isError, "\(write.text)")
        let bad = try await session.call("esclop_pipeline_write", ["name": "bad", "steps": "optimize"])
        #expect(bad.isError)
        #expect(bad.text.contains("optimise"))
        let list = try await session.call("esclop_pipeline_list")
        #expect(list.text.contains("web"))
        let show = try await session.call("esclop_pipeline_show", ["name": "web"])
        #expect(show.text.contains("convert(to: webp)"))
        let resource = try await session.client.readResource(uri: "esclop://pipelines/web")
        #expect(resource.contains { $0.text?.contains("webp") == true })
        let attach = try await session.call("esclop_pipeline_attach", ["pipeline": "web", "trigger": "clipboard"])
        #expect(attach.isError, "automations need permission")
        let delete = try await session.call("esclop_pipeline_delete", ["name": "web"])
        #expect(!delete.isError)
        #expect(try await session.call("esclop_pipeline_show", ["name": "web"]).isError)
    }

    @Test func statusSchemaResourcesAndPrompts() async throws {
        let session = try await Session.start(.answer([:]))
        defer { Task { await session.stop() } }
        let status = try await session.call("esclop_status")
        #expect(status.json.contains("\"elicitation\" : true"))
        #expect(status.json.contains("\"allowRunScripts\" : false"))
        let schema = try await session.call("esclop_settings_schema", ["query": "scripts"])
        #expect(schema.text.contains("allowRunScripts"))
        let (resources, _) = try await session.client.listResources()
        #expect(Set(resources.map(\.uri)).isSuperset(of: ["esclop://results/recent", "esclop://settings"]))
        let settings = try await session.client.readResource(uri: "esclop://settings")
        #expect(settings.first?.text?.contains("allowSettingsChanges") == true)
        let (templates, _) = try await session.client.listResourceTemplates()
        #expect(templates.map(\.uriTemplate) == ["esclop://pipelines/{name}"])
        let (prompts, _) = try await session.client.listPrompts()
        #expect(Set(prompts.map(\.name)) == ["write_pipeline", "shrink_for"])
        let write = try await session.client.getPrompt(name: "write_pipeline", arguments: ["goal": "screenshots to webp"])
        guard case let .text(text) = write.messages.first?.content else { Issue.record("no text"); return }
        #expect(text.contains("screenshots to webp"))
        #expect(text.contains("convert"))
        let shrink = try await session.client.getPrompt(name: "shrink_for", arguments: ["platform": "app-store"])
        #expect(!shrink.messages.isEmpty)
        await #expect(throws: (any Error).self) { _ = try await session.client.getPrompt(name: "shrink_for", arguments: ["platform": "fax"]) }
    }
}

@Suite struct Elicitation {
    static let schema = MCP.Elicitation.RequestSchema(properties: ["x": ["type": "string"]])

    @Test func unansweredQuestionsTimeOut() async {
        let elicitor = Elicitor(supported: { true }, request: { _, _ in
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return CreateElicitation.Result(action: .cancel)
        }, timeout: 0.3)
        let started = Date()
        do {
            _ = try await elicitor.ask("Which?", schema: Self.schema, missing: "x", options: "a, b")
            Issue.record("expected a timeout")
        } catch let failure as ToolFailure {
            #expect(failure.message.contains("Nobody answered"))
            #expect(failure.message.contains("Pass x (a, b)"))
            #expect(failure.code == "needsInput")
        } catch {
            Issue.record("wrong error \(error)")
        }
        // The request sleeps 30 s; anything well below that proves the 0.3 s timeout fired.
        #expect(Date().timeIntervalSince(started) < 15)
    }

    @Test func outcomes() async throws {
        let accept = Elicitor(supported: { true }, request: { _, _ in CreateElicitation.Result(action: .accept, content: ["x": "a"]) }, timeout: 1)
        #expect(try await accept.ask("?", schema: Self.schema, missing: "x", options: "a")["x"] == "a")
        let cancel = Elicitor(supported: { true }, request: { _, _ in CreateElicitation.Result(action: .cancel) }, timeout: 1)
        await #expect(throws: ToolFailure.self) { _ = try await cancel.ask("?", schema: Self.schema, missing: "x", options: "a") }
        let failing = Elicitor(supported: { true }, request: { _, _ in throw MCPError.methodNotFound("nope") }, timeout: 1)
        await #expect(throws: ToolFailure.self) { _ = try await failing.ask("?", schema: Self.schema, missing: "x", options: "a") }
    }
}

@Suite struct Catalog {
    @Test func everyToolIsWellFormed() throws {
        for spec in ToolCatalog.all {
            let tool = spec.tool
            #expect(tool.name.hasPrefix("esclop_"))
            #expect((tool.description ?? "").count >= 80, "\(tool.name) explains itself")
            let schema = try #require(tool.inputSchema.objectValue)
            #expect(schema["type"] == "object")
            let properties = schema["properties"]?.objectValue ?? [:]
            for required in schema["required"]?.arrayValue ?? [] {
                #expect(properties[required.stringValue ?? ""] != nil, "\(tool.name) requires a declared property")
            }
            for (name, property) in properties {
                #expect(property.objectValue?["description"] != nil, "\(tool.name).\(name) has a description")
            }
        }
        #expect(Set(ToolCatalog.all.map(\.tool.name)) == MCPServerInMemory.expectedTools)
    }

    @Test func readOnlyToolsSaySo() {
        let readOnly = ToolCatalog.all.filter { $0.tool.annotations.readOnlyHint == true }.map(\.tool.name)
        #expect(Set(readOnly) == ["esclop_pipeline_list", "esclop_pipeline_show", "esclop_settings_schema", "esclop_settings_get", "esclop_status", "esclop_recent_results", "esclop_logs"])
    }
}
