// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EsclopCore
import EsclopIPC
import EsclopMCP
import EsclopPipelines
@testable import EsclopAppKit
import Foundation
import Security
import SwiftUI
import Testing

/// A local S3 server (moto, with signatures checked), started by Scripts/s3-test-server.sh.
struct S3TestServer {
    let endpoint: String
    let bucket: String
    let keys: UploadCredentials
    let pid: Int32

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// One server for the whole test run (a start takes half a minute on a CI runner), started off
    /// the main actor and stopped when the test process ends. Tests use their own keys in it.
    static func start() async throws -> S3TestServer {
        try await shared.value
    }

    private static let shared = Task.detached { try launch() }

    private static func launch() throws -> S3TestServer {
        let process = Process()
        process.executableURL = root.appendingPathComponent("Scripts/s3-test-server.sh")
        process.arguments = ["start"]
        var environment = ProcessInfo.processInfo.environment
        environment["ESCLOP_S3_OWNER"] = String(ProcessInfo.processInfo.processIdentifier)
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EsclopError.other("the S3 test server did not start")
        }
        return S3TestServer(
            endpoint: json["endpoint"] as! String, bucket: json["bucket"] as! String,
            keys: UploadCredentials(accessKeyID: json["accessKeyID"] as! String, secret: json["secret"] as! String),
            pid: Int32(json["pid"] as! Int)
        )
    }

    /// The server outlives each test: it goes when the test process does.
    func stop() {}

    func target(_ name: String = "Local", publicURL: String = "") -> UploadTarget {
        UploadTarget(name: name, endpoint: endpoint, bucket: bucket, region: "us-east-1", path: "tests/%f.%e", publicURL: publicURL)
    }

    /// Reads an object back with a signed GET, as the person's browser would through a public link.
    func read(_ key: String) async throws -> Data {
        let url = target().objectURL(key: key)!
        var request = URLRequest(url: url)
        let empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let headers = S3Signer.sign(method: "GET", url: url, headers: ["host": S3Signer.hostHeader(url)], payloadHash: empty,
                                    accessKey: keys.accessKeyID, secret: keys.secret, region: "us-east-1", date: Date())
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw EsclopError.fileNotFound(key) }
        return data
    }
}

/// Uploads against a real S3 server on this Mac: the signature, the link, progress, refusal and
/// cancellation, then the app's paths (a card, an automatic upload, a job from the command line or
/// an agent, a pipeline step).
@MainActor @Suite(.serialized) struct UploadTests {
    static func settings(with target: UploadTarget) -> TestSettings {
        let settings = TestSettings()
        try? EsclopSettings.uploadTargets.set(UploadTarget.encode([target]), in: settings.store)
        return settings
    }

    @Test func aFileGoesUpAndItsLinkPointsAtIt() async throws {
        let server = try await S3TestServer.start()
        defer { server.stop() }
        let temp = TempDir()
        let file = temp.file("photo one.png", bytes: 300_000)
        let target = server.target()
        let fractions = Fractions()
        let link = try await S3Uploader().upload(file, to: target, key: target.key(for: file), credentials: server.keys) { fractions.add($0) }
        #expect(link.absoluteString == "\(server.endpoint)/\(server.bucket)/tests/photo%20one.png")
        #expect(try await server.read("tests/photo one.png") == Data(contentsOf: file), "the bytes arrived whole")
        #expect(fractions.values.last == 1)
        #expect(fractions.values == fractions.values.sorted(), "progress only goes forward")
        // A public link template is what is copied.
        let cdn = server.target(publicURL: "https://files.example.com/{path}")
        #expect(cdn.link(key: "tests/photo one.png")?.absoluteString == "https://files.example.com/tests/photo%20one.png")
    }

    @Test func aWrongSecretIsRefusedAndTheFileStays() async throws {
        let server = try await S3TestServer.start()
        defer { server.stop() }
        let temp = TempDir()
        let file = temp.file("a.png")
        let wrong = UploadCredentials(accessKeyID: server.keys.accessKeyID, secret: "not-the-secret")
        do {
            _ = try await S3Uploader().upload(file, to: server.target(), key: "tests/a.png", credentials: wrong)
            Issue.record("a wrong secret was accepted")
        } catch let error as EsclopError {
            #expect(error.description.contains("SignatureDoesNotMatch"), "the service's reason: \(error)")
            #expect(!error.description.contains("not-the-secret"), "the secret is never in a message")
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func anUploadCanBeStopped() async throws {
        let server = try await S3TestServer.start()
        defer { server.stop() }
        let temp = TempDir()
        let file = temp.file("big.mov", bytes: 60_000_000)
        let task = Task { try await S3Uploader().upload(file, to: server.target(), key: "tests/big.mov", credentials: server.keys) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await #expect(throws: EsclopError.cancelled) { try await task.value }
    }

    // MARK: The app

    func harness(_ server: S3TestServer, keys: Bool = true) -> Harness {
        let harness = Harness()
        try? EsclopSettings.uploadTargets.set(UploadTarget.encode([server.target()]), in: harness.settings.store)
        let store = MemoryCredentialStore(keys ? ["Local": server.keys] : [:])
        harness.model.uploader = AppUploader(settings: harness.settings.store, credentials: store)
        return harness
    }

    @Test func aCardUploadsItsResultAndCopiesTheLink() async throws {
        let server = try await S3TestServer.start()
        defer { server.stop() }
        let harness = harness(server)
        await harness.model.run(harness.job(harness.temp.file("a.png")))
        let card = try #require(harness.model.cards.first)
        harness.model.perform(.upload, on: card)
        #expect(await eventually(.seconds(20)) { if case .uploaded = card.upload { true } else { false } })
        let link = try #require(card.link)
        #expect(harness.pasteboard.string(forType: .string) == link.absoluteString, "the link is on the clipboard")
        #expect(card.presentation.capsule == .status(symbol: "link", text: Strings.text("Uploaded · link copied")))
        #expect(card.presentation.actions.contains(.copyLink))
        #expect(try await server.read(UploadTarget.decode(EsclopSettings.uploadTargets.value(in: harness.settings.store))[0].key(for: card.shownFile)).count > 0)
    }

    @Test func aFailedUploadKeepsTheFileAndSaysWhy() async throws {
        let server = try await S3TestServer.start()
        defer { server.stop() }
        let harness = harness(server, keys: false)
        await harness.model.run(harness.job(harness.temp.file("a.png")))
        let card = try #require(harness.model.cards.first)
        harness.model.upload(card)
        #expect(await eventually(.seconds(10)) { if case .failed = card.upload { true } else { false } })
        guard case let .failed(message) = card.upload else { return }
        #expect(message.contains("Local"), "names the target whose keys are missing: \(message)")
        #expect(FileManager.default.fileExists(atPath: card.shownFile.path))
        #expect(card.presentation.actions.first == .retryUpload)
        // With the keys entered, Upload Again goes through.
        try (harness.model.uploader as! AppUploader).credentials.save(server.keys, for: "Local")
        harness.model.perform(.retryUpload, on: card)
        #expect(await eventually(.seconds(20)) { if case .uploaded = card.upload { true } else { false } })
    }

    @Test func resultsFromChosenSourcesUploadOnTheirOwn() async throws {
        let server = try await S3TestServer.start()
        defer { server.stop() }
        let harness = harness(server)
        try EsclopSettings.uploadAutomatically.set(["dropZone"], in: harness.settings.store)
        await harness.model.run(harness.job(harness.temp.file("dropped.png"), origin: .dropZone))
        let dropped = try #require(harness.model.cards.last)
        #expect(await eventually(.seconds(20)) { if case .uploaded = dropped.upload { true } else { false } })
        await harness.model.run(harness.job(harness.temp.file("chosen.png"), origin: .app))
        let chosen = try #require(harness.model.cards.last)
        try await Task.sleep(for: .milliseconds(300))
        #expect(chosen.upload == nil, "a source not in the setting does not upload")
    }

    @Test func aJobFromTheCommandLineUploadsThroughTheApp() async throws {
        let server = try await S3TestServer.start()
        defer { server.stop() }
        let harness = harness(server)
        var job = harness.job(harness.temp.file("cli.png"), origin: .cli)
        job.operation = .upload(target: "Local")
        let report = await harness.model.run(job)
        let link = try #require(report.results.first?.link)
        #expect(harness.pasteboard.string(forType: .string) == link.absoluteString)
        #expect(ResultSummary(report.results[0]).line.hasSuffix("→ \(link.absoluteString)"))
        // An agent needs the person's permission, and gets nothing without it.
        var agent = job
        agent.request.origin = .mcp
        let handler = AppIPCHandler(model: harness.model, terminate: {})
        await #expect(throws: EsclopError.self) { try await handler.perform(agent) { _ in } }
        try EsclopSettings.allowUploads.set(true, in: harness.settings.store)
        try await handler.perform(agent) { _ in }
    }

    @Test func aPipelineStepUploadsInTheApp() async throws {
        let server = try await S3TestServer.start()
        defer { server.stop() }
        let harness = harness(server)
        try harness.model.service.context.pipelines.save(PipelineParser.parse("upload(to: \"Local\")", name: "Share"))
        var job = harness.job(harness.temp.file("p.png"))
        job.operation = .pipeline("Share")
        let report = await harness.model.run(job)
        let result = try #require(report.results.first)
        #expect(result.steps.contains { $0.hasPrefix("upload") && $0.contains(server.endpoint) }, "the link is in the run log: \(result.steps)")
        #expect(harness.pasteboard.string(forType: .string)?.hasPrefix(server.endpoint) == true)
    }
}

/// Uploads without a server: where they are refused, and what never leaves the Keychain.
@MainActor @Suite struct UploadRulesTests {
    @Test func outsideTheAppAnUploadNeedsTheApp() async throws {
        let temp = TempDir()
        let executor = JobExecutor(engine: ShrinkingEngine(backups: temp.url, log: RequestLog()))
        let job = OptimisationJob(request: OptimisationRequest(sources: [temp.file("a.png")], origin: .cli), operation: .upload(target: nil))
        let report = await executor.run(job)
        #expect(report.failures.first?.error == .appNotRunning)
    }

    @Test func agentsMayUploadOnlyWhenThePersonAllowsIt() throws {
        let settings = TestSettings()
        let provider = RegistrySettingsProvider(store: settings.store)
        let job = OptimisationJob(request: OptimisationRequest(sources: [], origin: .mcp), operation: .upload(target: nil))
        let policy = AgentPolicy(origin: .mcp, permissions: provider)
        #expect(throws: EsclopError.self) { try policy.check(job) }
        let pipeline = OptimisationJob(request: OptimisationRequest(sources: [], origin: .mcp, location: .sameFolder), operation: .pipeline("x"))
        #expect(throws: EsclopError.self) { try policy.check(pipeline, pipelineUploads: true) }
        #expect(!EsclopSettings.allowUploads.defaultValue, "off until the person turns it on")
        try EsclopSettings.allowUploads.set(true, in: settings.store)
        try policy.check(job)
        try policy.check(pipeline, pipelineUploads: true)
        // The person and the command line are not agents.
        try AgentPolicy(origin: .cli, permissions: RegistrySettingsProvider(store: TestSettings().store)).check(job)
    }

    /// With uploads allowed, an agent still uploads only media: not a text file, not a file with
    /// no extension (a key), not a link named like a photo that points at one. The person can.
    @Test func agentsUploadOnlyImagesVideosPDFsAndAudio() async throws {
        let settings = TestSettings()
        try EsclopSettings.allowUploads.set(true, in: settings.store)
        let policy = AgentPolicy(origin: .mcp, permissions: RegistrySettingsProvider(store: settings.store))
        let temp = TempDir()
        let key = temp.file("id_ed25519")
        let disguised = temp.url.appendingPathComponent("photo.jpg")
        try FileManager.default.createSymbolicLink(at: disguised, withDestinationURL: key)
        func job(_ file: URL, origin: RequestOrigin = .mcp) -> OptimisationJob {
            OptimisationJob(request: OptimisationRequest(sources: [file], origin: origin), operation: .upload(target: nil))
        }
        for file in [temp.file("notes.txt"), key, disguised] {
            #expect(throws: EsclopError.self, "\(file.lastPathComponent) is refused") { try policy.check(job(file)) }
            do { try policy.check(job(file)) } catch let error as EsclopError {
                guard case let .notPermitted(message) = error else { Issue.record("not notPermitted: \(error)"); continue }
                #expect(message.contains("only images, videos, PDFs and audio"))
            }
        }
        try policy.check(job(temp.file("photo.png")))
        // The person's own uploads are not an agent's.
        try AgentPolicy(origin: .cli, permissions: RegistrySettingsProvider(store: settings.store)).check(job(key, origin: .cli))
        // The app applies the same rule to what an agent sends it.
        let harness = Harness()
        try EsclopSettings.allowUploads.set(true, in: harness.settings.store)
        let handler = AppIPCHandler(model: harness.model, terminate: {})
        await #expect(throws: EsclopError.self) { try await handler.perform(job(disguised)) { _ in } }
        // A pipeline's upload step uploads media only, whoever runs it.
        let host = AppPipelineHost(uploader: AppUploader(settings: settings.store, credentials: MemoryCredentialStore())) { _ in }
        let outcome = try await host.perform(.uploadTo(target: nil), file: key, options: PipelineRunOptions())
        guard case .unavailable = outcome else { Issue.record("the step uploaded a key: \(outcome)"); return }
    }

    @Test func damagedKeysAreNamedNotTakenForMissing() throws {
        let store = KeychainCredentialStore(service: "dev.esclop.app-tests.\(UUID().uuidString)")
        guard ProcessInfo.processInfo.environment["CI"] == nil else { return }
        defer { try? store.remove(for: "t") }
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: store.service, kSecAttrAccount as String: "t", kSecValueData as String: Data("not json".utf8)]
        #expect(SecItemAdd(item as CFDictionary, nil) == errSecSuccess)
        #expect(throws: EsclopError.self) { _ = try store.credentials(for: "t") }
    }

    @Test func keysGoToTheKeychainStoreNeverToTheSettings() throws {
        let settings = TestSettings()
        let model = SettingsViewModel(provider: RegistrySettingsProvider(store: settings.store), extraRows: [])
        let keychain = MemoryCredentialStore()
        model.uploads = UploadSettingsSupport(credentials: keychain) { _, _ in URL(string: "https://example.invalid")! }
        var draft = UploadTargetDraft(nil, keysSaved: false)
        draft.target = UploadTarget(name: "R2", endpoint: "https://account.r2.cloudflarestorage.com", bucket: "pics", region: "auto")
        #expect(draft.problem(others: []) != nil, "no keys yet")
        draft.accessKeyID = "AKIDEXAMPLE"
        draft.secret = "very-secret-value"
        #expect(draft.problem(others: []) == nil)
        try draft.save(model: model)
        #expect(try keychain.credentials(for: "R2")?.secret == "very-secret-value")
        // Nothing the command line, an agent or the settings file can read holds the secret.
        let stored = try RegistrySettingsProvider(store: settings.store).descriptor(forKey: "uploadTargets")
        let json = String(data: try JSONEncoder().encode(stored), encoding: .utf8) ?? ""
        #expect(json.contains("pics") && !json.contains("very-secret-value") && !json.contains("AKIDEXAMPLE"))
        let file = settings.store.defaults.dictionaryRepresentation().description
        #expect(!file.contains("very-secret-value"))
        // A rename moves the keys; removing the target removes them.
        var rename = UploadTargetDraft(model.uploadTargets[0], keysSaved: true)
        rename.target.name = "Cloudflare"
        try rename.save(model: model)
        #expect(try keychain.credentials(for: "R2") == nil)
        #expect(try keychain.credentials(for: "Cloudflare")?.accessKeyID == "AKIDEXAMPLE")
        UploadTargetList.remove(model.uploadTargets[0], model: model)
        #expect(model.uploadTargets.isEmpty)
        #expect(try keychain.credentials(for: "Cloudflare") == nil)
    }

    /// The Uploads pane in a window while its targets change under it: added, renamed (the
    /// default following), removed, and changed by another process.
    @Test func thePaneFollowsItsTargets() async throws {
        let settings = TestSettings()
        let model = SettingsViewModel(provider: RegistrySettingsProvider(store: settings.store), defaults: settings.store.defaults, extraRows: [])
        model.uploads = UploadSettingsSupport(credentials: MemoryCredentialStore()) { _, _ in URL(string: "https://example.invalid")! }
        model.pane = .uploads
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
        window.isReleasedWhenClosed = false
        window.setContentSize(CGSize(width: 800, height: 620))
        window.orderFrontRegardless()
        defer { window.close() }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(120))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        try await settle()
        var draft = UploadTargetDraft(nil, keysSaved: false)
        draft.target = UploadTarget(name: "A", endpoint: "https://s3.amazonaws.com", bucket: "a")
        draft.accessKeyID = "id"
        draft.secret = "secret"
        try draft.save(model: model)
        model.set("uploadTarget", to: .string("A"))
        try await settle()
        var rename = UploadTargetDraft(model.uploadTargets[0], keysSaved: true)
        rename.target.name = "B"
        try rename.save(model: model)
        try await settle()
        #expect(model.value("uploadTarget")?.stringValue == "B", "the default follows the rename")
        // Another process empties the list while the pane shows it.
        try EsclopSettings.uploadTargets.set([], in: settings.store)
        try await settle()
        #expect(await eventually(.seconds(5)) { model.uploadTargets.isEmpty })
        try await settle()
    }

    @Test func keysTravelOnlyOverHttpsExceptToThisMac() {
        #expect(UploadTarget(name: "a", endpoint: "http://files.example.com", bucket: "b").problem != nil)
        #expect(UploadTarget(name: "a", endpoint: "http://127.0.0.1:9000", bucket: "b").problem == nil)
        #expect(UploadTarget(name: "a", endpoint: "https://s3.amazonaws.com", bucket: "b").problem == nil)
        let virtual = UploadTarget(name: "a", endpoint: "https://s3.eu-west-1.amazonaws.com", bucket: "pics", pathStyle: false)
        #expect(virtual.objectURL(key: "x/y.png")?.absoluteString == "https://pics.s3.eu-west-1.amazonaws.com/x/y.png")
    }

    /// The real login Keychain. Not on CI: a runner's keychain can be locked, and writing to it
    /// then waits for a password prompt nobody answers.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil, "the runner's keychain may be locked"))
    func theKeychainStoreRoundTrips() throws {
        let store = KeychainCredentialStore(service: "dev.esclop.app-tests.\(UUID().uuidString)")
        defer { try? store.remove(for: "t") }
        #expect(try store.credentials(for: "t") == nil)
        try store.save(UploadCredentials(accessKeyID: "a", secret: "s"), for: "t")
        try store.save(UploadCredentials(accessKeyID: "a2", secret: "s2"), for: "t")
        #expect(try store.credentials(for: "t") == UploadCredentials(accessKeyID: "a2", secret: "s2"))
        try store.remove(for: "t")
        #expect(try store.credentials(for: "t") == nil)
    }

    @Test func theUploadStepReadsAndWritesAndExplains() throws {
        let pipeline = try PipelineParser.parse("optimise -> upload(to: \"R2\")", name: "x")
        #expect(pipeline[nil].last == .upload(target: "R2"))
        #expect(PipelineSerializer.serialize(pipeline).contains("upload(to: \"R2\")"))
        #expect(pipeline.usesUploads)
        #expect(try PipelineParser.parse("upload", name: "y")[nil] == [.upload(target: nil)])
        #expect(PipelineLanguage.describe(pipeline).contains("upload it to “R2”"))
    }
}

final class Fractions: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func add(_ value: Double) { lock.withLock { stored.append(value) } }
    var values: [Double] { lock.withLock { stored } }
}
