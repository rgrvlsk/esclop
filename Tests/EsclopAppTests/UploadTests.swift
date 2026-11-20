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

    private static let shared = Task.detached { try await launch() }

    /// Awaited, not waited for: the start would otherwise hold one of the cooperative pool's
    /// threads (three on a CI runner) for that half minute, and every other test's sleeps and
    /// timeouts would end late.
    private static func launch() async throws -> S3TestServer {
        let started = try await ProcessRunner.run(
            executable: root.appendingPathComponent("Scripts/s3-test-server.sh"), arguments: ["start"],
            options: ProcessOptions(environment: ["ESCLOP_S3_OWNER": String(ProcessInfo.processInfo.processIdentifier)], timeout: 600)
        )
        guard let json = try JSONSerialization.jsonObject(with: started.stdout) as? [String: Any] else {
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

/// A port on 127.0.0.1 that takes connections and their bytes (the kernel queues them) and never
/// answers.
struct SilentServer {
    let port: UInt16
    private let socket: Int32

    init() throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, length) == 0 && listen(socket, 4) == 0 && getsockname(socket, $0, &length) == 0
            }
        }
        guard socket >= 0, bound else { close(socket); throw EsclopError.other("no local port: \(String(cString: strerror(errno)))") }
        self.socket = socket
        port = UInt16(bigEndian: address.sin_port)
    }

    func stop() { close(socket) }
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

    @Test func theTestUploadChecksTheLinkOpensWithoutKeys() async throws {
        let server = try await S3TestServer.start()
        defer { server.stop() }
        let temp = TempDir()
        let file = temp.file("private.png")
        let target = server.target()
        let link = try await S3Uploader().upload(file, to: target, key: target.key(for: file), credentials: server.keys)
        // The bucket is private: its own address does not open for the people the link goes to.
        await #expect(throws: EsclopError.self) { try await S3Uploader().checkLink(link) }
        // The test upload removes its file afterwards.
        try await S3Uploader().delete(target.key(for: file), from: target, credentials: server.keys)
        await #expect(throws: EsclopError.self) { try await server.read(target.key(for: file)) }
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
        // A server that never answers: within the session's 60 s timeout the upload can only end
        // by being stopped, however long other suites hold the main actor (a real server finished
        // all 60 MB first).
        let server = try SilentServer()
        defer { server.stop() }
        let temp = TempDir()
        let file = temp.file("big.mov", bytes: 4_000_000)
        let target = UploadTarget(name: "Silent", endpoint: "http://127.0.0.1:\(server.port)", bucket: "b", region: "us-east-1", path: "%f.%e")
        let keys = UploadCredentials(accessKeyID: "key", secret: "secret")
        let (sending, sent) = AsyncStream<Void>.makeStream()
        let task = Task {
            defer { sent.finish() }
            return try await S3Uploader().upload(file, to: target, key: "big.mov", credentials: keys) { _ in sent.yield() }
        }
        // Stopped once bytes are on their way, so the stop lands mid-upload.
        for await _ in sending { break }
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

    @Test func aBatchUploadsEveryResultAndEachRowSaysSo() async throws {
        let server = try await S3TestServer.start()
        defer { server.stop() }
        let harness = harness(server)
        try EsclopSettings.uploadAutomatically.set(["dropZone"], in: harness.settings.store)
        try EsclopSettings.batchWindowFrom.set(2, in: harness.settings.store)
        harness.model.optimiseDropped((1 ... 4).map { harness.temp.png("batch-\($0).png") }, harder: false)
        let batch = try #require(harness.model.batch)
        func uploaded(_ row: BatchRow) -> Bool { if case .uploaded = row.upload { true } else { false } }
        #expect(await eventually(.seconds(30)) { batch.rows.count == 4 && batch.rows.allSatisfy(uploaded) })
        #expect(harness.model.cards.isEmpty)
        #expect(BatchPresentation.status(of: batch.rows[0]) == Strings.text("Uploaded · link copied"))
        // Every link at once, one per line in row order, not only the last one.
        let links = batch.rows.compactMap { row -> String? in if case let .uploaded(link, _) = row.upload { link.absoluteString } else { nil } }
        #expect(await eventually { harness.pasteboard.string(forType: .string) == links.joined(separator: "\n") })
    }

    @Test func aJobFromTheCommandLineUploadsThroughTheApp() async throws {
        let server = try await S3TestServer.start()
        defer { server.stop() }
        let harness = harness(server)
        var job = harness.job(harness.temp.png("cli.png"), origin: .cli)
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
        var job = harness.job(harness.temp.png("p.png"))
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
    /// no extension (a key), not a key or text renamed to a media extension, not an empty file,
    /// not a link named like a photo that points at one. A PNG named .jpg is media. The person
    /// uploads what they like.
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
        let renamed = temp.url.appendingPathComponent("renamed.png")
        try FileManager.default.createSymbolicLink(at: renamed, withDestinationURL: temp.file("id_ed25519.png"))
        let pretenders = ["png", "mp4", "pdf", "mp3", "svg"].map { temp.file("key.\($0)") } + ["png", "mp4", "pdf", "mp3", "svg"].map { ext in
            let url = temp.url.appendingPathComponent("notes.\(ext)")
            try? "Notes, not media\n".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let empty = temp.url.appendingPathComponent("empty.png")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        for file in [temp.file("notes.txt"), key, disguised, renamed, empty] + pretenders {
            #expect(throws: EsclopError.self, "\(file.lastPathComponent) is refused") { try policy.check(job(file)) }
            do { try policy.check(job(file)) } catch let error as EsclopError {
                guard case let .notPermitted(message) = error else { Issue.record("not notPermitted: \(error)"); continue }
                #expect(message.contains("only images, videos, PDFs and audio"))
            }
        }
        try policy.check(job(temp.png("photo.png")))
        try policy.check(job(temp.png("really-a-png.jpg")))
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

    @Test func anAutomaticLinkNeverReplacesWhatWasCopiedMeanwhile() async {
        let harness = Harness()
        let link = URL(string: "https://files.example.com/a.png")!
        let since = await harness.model.clipboard.run { $0.changeCount() }
        // L'Esclop's own automatic write in between (a pipeline's copy) does not count as a copy.
        await harness.model.copyToClipboard(text: "own", automatic: true)
        #expect(await harness.model.copyToClipboard(links: [link], since: since))
        #expect(harness.pasteboard.string(forType: .string) == link.absoluteString)
        // The person copies something: the next automatic link stays off the clipboard.
        let before = await harness.model.clipboard.run { $0.changeCount() }
        harness.pasteboard.clearContents()
        harness.pasteboard.setString("mine", forType: .string)
        #expect(await harness.model.copyToClipboard(links: [link], since: before) == false)
        #expect(harness.pasteboard.string(forType: .string) == "mine")
        // Nor when L'Esclop then puts that newer copy's result back over it.
        let result = harness.temp.png("newer.png")
        harness.model.holdOnClipboard([result], at: harness.pasteboard.changeCount)
        harness.pasteboard.clearContents()
        harness.pasteboard.writeObjects([result] as [NSURL])
        harness.model.holdOnClipboard([result], at: harness.pasteboard.changeCount)
        await harness.model.putBackOnClipboard([(result, result)])
        #expect(await harness.model.copyToClipboard(links: [link], since: before) == false)
        // Nor over a Copy the person asked for.
        let start = await harness.model.clipboard.run { $0.changeCount() }
        harness.model.writeClipboard(files: [result])
        #expect(await harness.model.copyToClipboard(links: [link], since: start) == false)
        // Copy Link, which the person asks for, always writes.
        #expect(await harness.model.copyToClipboard(links: [link]))
    }

    @Test func aBatchCopiesItsLinksWhenTheLastUploadFails() async throws {
        let harness = Harness()
        try EsclopSettings.uploadTargets.set(UploadTarget.encode([UploadTarget(name: "Fake", endpoint: "https://s3.example.invalid", bucket: "b")]), in: harness.settings.store)
        try EsclopSettings.uploadAutomatically.set(["dropZone"], in: harness.settings.store)
        try EsclopSettings.batchWindowFrom.set(2, in: harness.settings.store)
        harness.model.uploader = SlowLastUploader()
        harness.model.optimiseDropped(["a.png", "b.png", "last.png"].map(harness.temp.png), harder: false)
        let batch = try #require(harness.model.batch)
        #expect(await eventually { batch.rows.count == 3 && batch.rows.allSatisfy { if case .uploading = $0.upload { false } else { $0.upload != nil } } })
        #expect(await eventually { harness.pasteboard.string(forType: .string) == "https://files.example.com/a.png\nhttps://files.example.com/b.png" })
    }

    /// A copy made while the file was being optimised stays: the automatic link is measured
    /// against the clipboard as the job started, and the card says the link is ready, not copied.
    @Test func anAutomaticLinkKeepsACopyMadeDuringTheJob() async throws {
        let gate = WorkGate(limit: 1)
        let harness = Harness(gate: gate)
        try EsclopSettings.uploadTargets.set(UploadTarget.encode([UploadTarget(name: "Fake", endpoint: "https://s3.example.invalid", bucket: "b")]), in: harness.settings.store)
        try EsclopSettings.uploadAutomatically.set(["dropZone"], in: harness.settings.store)
        harness.model.uploader = SlowLastUploader()
        await gate.acquire()
        let job = Task { await harness.model.run(harness.job(harness.temp.png("video.png"))) }
        #expect(await eventually { harness.model.cards.count == 1 })
        // The job has read the clipboard and waits for its turn; the person copies some text.
        try await Task.sleep(for: .milliseconds(200))
        await harness.clipboardSettles()
        harness.pasteboard.clearContents()
        harness.pasteboard.setString("mine", forType: .string)
        await gate.release()
        _ = await job.value
        let card = try #require(harness.model.cards.first)
        #expect(await eventually { if case .uploaded = card.upload { true } else { false } })
        #expect(harness.pasteboard.string(forType: .string) == "mine")
        #expect(card.presentation.capsule == .status(symbol: "link", text: Strings.text("Uploaded · link ready")))
        #expect(card.presentation.headline == Strings.text("Link ready"))
        // Nothing copied during the next one: its link goes on the clipboard.
        await harness.model.run(harness.job(harness.temp.png("next.png")))
        let next = try #require(harness.model.cards.last)
        #expect(await eventually { if case .uploaded = next.upload { true } else { false } })
        #expect(harness.pasteboard.string(forType: .string) == "https://files.example.com/next.png")
        #expect(next.presentation.capsule == .status(symbol: "link", text: Strings.text("Uploaded · link copied")))
    }

    /// The pipeline editor's Run on several files is one batch; its pipeline's upload steps put
    /// their links on the clipboard together when it ends, and never over a newer copy.
    @Test func aPipelinesLinksGoTogetherAndNeverOverANewerCopy() async throws {
        let gate = WorkGate(limit: 1)
        let harness = Harness(gate: gate)
        harness.model.uploader = SlowLastUploader()
        try EsclopSettings.batchWindowFrom.set(2, in: harness.settings.store)
        try harness.model.service.context.pipelines.save(PipelineParser.parse("upload(to: \"Fake\")", name: "Share"))
        harness.model.runPipeline("Share", on: ["a.png", "b.png", "c.png"].map(harness.temp.png))
        let batch = try #require(harness.model.batch)
        #expect(await eventually { batch.rows.count == 3 && !batch.isRunning })
        #expect(harness.model.cards.isEmpty, "one batch, not a card per file")
        let expected = Set(["a", "b", "c"].map { "https://files.example.com/\($0).png" })
        #expect(await eventually { Set(harness.pasteboard.string(forType: .string)?.split(separator: "\n").map(String.init) ?? []) == expected })
        // A copy made while the next file waits keeps its place.
        await gate.acquire()
        harness.model.runPipeline("Share", on: [harness.temp.png("d.png")])
        #expect(await eventually { harness.model.cards.count == 1 })
        try await Task.sleep(for: .milliseconds(200))
        await harness.clipboardSettles()
        harness.pasteboard.clearContents()
        harness.pasteboard.setString("mine", forType: .string)
        await gate.release()
        #expect(await eventually { harness.model.cards.first?.result != nil })
        await harness.clipboardSettles()
        #expect(harness.pasteboard.string(forType: .string) == "mine")
    }

    /// Uploads at once, except `last.png`, which fails after the others are done.
    struct SlowLastUploader: FileUploading {
        func upload(_ file: URL, to target: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
            guard file.lastPathComponent != "last.png" else {
                try await Task.sleep(for: .milliseconds(300))
                throw EsclopError.other("The upload target did not answer.")
            }
            return URL(string: "https://files.example.com/\(file.lastPathComponent)")!
        }
    }

    @Test func aPublicLinkNeedsItsPathAndR2NeedsAPublicLink() {
        var target = UploadTarget(name: "R2", endpoint: "https://account.r2.cloudflarestorage.com", bucket: "pictures", region: "auto")
        #expect(target.problem == nil)
        #expect(target.linkWarning != nil, "R2's endpoint never serves the copied link")
        target.publicURL = "https://files.example.com/latest.png"
        #expect(target.problem != nil, "every upload would copy the same address")
        target.publicURL = "https://files.example.com/{path}"
        #expect(target.problem == nil && target.linkWarning == nil)
        #expect(UploadTarget(name: "S3", endpoint: "https://s3.eu-west-1.amazonaws.com", bucket: "b").linkWarning == nil)
    }

    @Test func aFileOverFiveGigabytesIsRefusedBeforeItGoes() async throws {
        let temp = TempDir()
        let file = temp.file("huge.mov", bytes: 0)
        // Sparse: no disk is used.
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(S3Uploader.largestPut) + 1)
        try handle.close()
        let target = UploadTarget(name: "Nowhere", endpoint: "https://s3.example.invalid", bucket: "b")
        let keys = UploadCredentials(accessKeyID: "AKIDEXAMPLE", secret: "x")
        await #expect(throws: EsclopError.invalidArgument(Strings.format("%@ is larger than 5 GB, the most L’Esclop can upload in one go.", "huge.mov"))) {
            try await S3Uploader().upload(file, to: target, key: "huge.mov", credentials: keys)
        }
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
