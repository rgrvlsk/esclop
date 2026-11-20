// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import EsclopCore
@testable import EsclopIPC
import Foundation
import PDFKit
import Testing

@Suite struct Executor {
    @Test func routesEveryOperationToTheEngine() async throws {
        let temp = TempDir()
        let file = temp.file("a.png")
        let engine = FakeEngine()
        let executor = JobExecutor(engine: engine)
        let operations: [(JobOperation, String)] = [
            (.optimise, "optimise"), (.convert(.webp), "convert:webp"), (.downscale(0.5), "downscale:0.5"),
            (.crop(CropSize(width: 10, height: 20)), "crop:10x20"), (.fit(underBytes: 99), "fit:99"), (.stripMetadata, "strip"),
        ]
        for (operation, expected) in operations {
            let report = await executor.run(OptimisationJob(request: OptimisationRequest(sources: [file], origin: .cli), operation: operation))
            #expect(report.failures.isEmpty)
            #expect(engine.calls.last == expected)
        }
    }

    @Test func reportsEachFileAndKeepsGoing() async {
        let temp = TempDir()
        let good = temp.file("good.png")
        let missing = temp.url.appendingPathComponent("missing.png")
        let events = EventLog()
        let report = await JobExecutor(engine: FakeEngine()).run(
            OptimisationJob(request: OptimisationRequest(sources: [missing, good], origin: .cli), operation: .optimise)
        ) { events.add($0) }
        #expect(report.results.map(\.source) == [good])
        #expect(report.failures == [FileFailure(source: missing, error: .fileNotFound(missing.path))])
        #expect(events.kinds == ["failure", "progress", "result"])
    }

    @Test func unavailableEngineSaysSo() async {
        let temp = TempDir()
        let report = await JobExecutor(engine: UnavailableEngine()).run(
            OptimisationJob(request: OptimisationRequest(sources: [temp.file("a.png")], origin: .cli), operation: .optimise)
        )
        #expect(report.failures.first?.error == .toolMissing("engine"))
    }

    @Test func pipelinesNeedARunner() async {
        let temp = TempDir()
        let report = await JobExecutor(engine: FakeEngine()).run(
            OptimisationJob(request: OptimisationRequest(sources: [temp.file("a.png")], origin: .cli), operation: .pipeline("x"))
        )
        #expect(report.failures.first?.error.code == "toolMissing")
    }

    @Test func badFactorsAreRefused() async {
        let temp = TempDir()
        let report = await JobExecutor(engine: FakeEngine()).run(
            OptimisationJob(request: OptimisationRequest(sources: [temp.file("a.png")], origin: .cli), operation: .downscale(3))
        )
        #expect(report.failures.first?.error.code == "invalidArgument")
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func add(_ event: JobEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .progress: events.append("progress")
        case .result: events.append("result")
        case .failure: events.append("failure")
        }
    }
    var kinds: [String] { lock.lock(); defer { lock.unlock() }; return events }
}

/// IPC and MCP place files by the engines' rule (one owner): in place never replaces an
/// unrelated sibling, and the agent gate checks the file the engine will write.
@Suite struct OutputPlanning {
    @Test func plansLikeTheEngines() throws {
        let temp = TempDir()
        let png = temp.file("IMG.png")
        try Data("unrelated".utf8).write(to: temp.url.appendingPathComponent("IMG.jpg"))
        let inPlace = try OutputPlanner.destination(for: png, location: .inPlace, suffix: "x", extension: "jpg")
        #expect(inPlace.lastPathComponent == "IMG 2.jpg")
        #expect(try OutputPlanner.destination(for: png, location: .inPlace, suffix: "x") == png)
        let planned = OutputPlanner.plannedFile(for: png, location: .path("out/"), operation: .convert(.webp))
        #expect(planned == OutputLocation.path("out/").destination(for: png, extension: "webp"))
        #expect(planned?.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == png.deletingLastPathComponent().standardizedFileURL)
    }
}

@Suite struct PDFTools {
    @Test func cropSetsTheCropBoxAndUncropRestoresIt() async throws {
        let temp = TempDir()
        let pdf = temp.pdf("doc.pdf", pages: [CGSize(width: 600, height: 600), CGSize(width: 800, height: 400)])
        var request = OptimisationRequest(sources: [pdf], origin: .cli, location: .sameFolder)
        let executor = JobExecutor(engine: FakeEngine(), backups: temp.url.appendingPathComponent("backups"))
        let cropped = await executor.run(OptimisationJob(request: request, operation: .cropPDF(PDFCropSpec(aspectRatio: 0.75))))
        let output = try #require(cropped.results.first?.output)
        #expect(output.lastPathComponent == "doc-cropped.pdf")
        let document = try #require(PDFDocument(url: output))
        let square = document.page(at: 0)!.bounds(for: .cropBox)
        #expect(abs(square.width / square.height - 0.75) < 0.01)
        #expect(abs(square.midX - 300) < 0.5)
        // A landscape page gets the ratio turned to 4:3.
        let wide = document.page(at: 1)!.bounds(for: .cropBox)
        #expect(abs(wide.width / wide.height - 4.0 / 3.0) < 0.01)
        #expect(wide.height == 400)

        request.sources = [output]
        request.location = .inPlace
        let restored = await executor.run(OptimisationJob(request: request, operation: .uncropPDF))
        #expect(restored.results.first?.output == output)
        #expect(restored.results.first?.backup != nil, "in place keeps a backup")
        #expect(BackupStore(root: temp.url.appendingPathComponent("backups")).entries().count == 1, "with its manifest, so retention prunes it")
        let back = try #require(PDFDocument(url: output))
        #expect(back.page(at: 0)!.bounds(for: .cropBox) == CGRect(x: 0, y: 0, width: 600, height: 600))
    }

    @Test func extendPadsInsteadOfCutting() throws {
        let rect = PDFPageTools.cropRect(media: CGRect(x: 0, y: 0, width: 600, height: 600), rotation: 0, spec: PDFCropSpec(aspectRatio: 0.75, extend: true))
        #expect(rect.width == 600)
        #expect(abs(rect.height - 800) < 0.01)
        #expect(abs(rect.minY + 100) < 0.01)
    }

    @Test func signedPDFsAreNotCroppedOrUncropped() async throws {
        let temp = TempDir()
        let pdf = temp.url.appendingPathComponent("contract.pdf")
        try signedPDF(at: pdf)
        let before = try Data(contentsOf: pdf)
        let executor = JobExecutor(engine: FakeEngine(), backups: temp.url.appendingPathComponent("backups"))
        for operation in [JobOperation.cropPDF(PDFCropSpec(aspectRatio: 0.75)), .uncropPDF] {
            let report = await executor.run(OptimisationJob(request: OptimisationRequest(sources: [pdf], origin: .cli, location: .inPlace), operation: operation))
            #expect(report.failures.first?.error.description == PDFSignature.reason, "\(operation)")
        }
        #expect(try Data(contentsOf: pdf) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path).filter { $0 != "backups" } == ["contract.pdf"])
    }

    @Test func notAPDF() async {
        let temp = TempDir()
        let report = await JobExecutor(engine: FakeEngine()).run(
            OptimisationJob(request: OptimisationRequest(sources: [temp.file("a.png")], origin: .cli), operation: .uncropPDF)
        )
        #expect(report.failures.first?.error.code == "unsupportedFile")
    }
}

@Suite struct PermissionGate {
    func job(_ location: OutputLocation, _ operation: JobOperation = .optimise) -> OptimisationJob {
        OptimisationJob(request: OptimisationRequest(sources: [], origin: .mcp, location: location), operation: operation)
    }

    @Test func cliIsNeverGated() throws {
        let policy = AgentPolicy(origin: .cli, permissions: InMemorySettingsProvider())
        try policy.check(job(.inPlace), pipelineUsesScripts: true)
        try policy.checkSettingsChange(AgentPermission.allowRunScripts.descriptor)
        try policy.checkRestore(deleteBackup: true)
        #expect(policy.defaultLocation == .inPlace)
    }

    @Test func agentsGetSafeDefaults() {
        let policy = AgentPolicy(origin: .mcp, permissions: InMemorySettingsProvider())
        #expect(policy.defaultLocation == .sameFolder)
        #expect(throws: EsclopError.self) { try policy.check(job(.inPlace)) }
        #expect(throws: Never.self) { try policy.check(job(.sameFolder)) }
        #expect(throws: EsclopError.self) { try policy.check(job(.sameFolder), pipelineUsesScripts: true) }
        #expect(throws: EsclopError.self) { try policy.checkAutomationChange() }
        #expect(throws: EsclopError.self) { try policy.checkRestore(deleteBackup: false) }
        #expect(throws: EsclopError.self) { try policy.checkPipelineWrite(replacing: true, usesScripts: false) }
        #expect(throws: Never.self) { try policy.checkPipelineWrite(replacing: false, usesScripts: false) }
        #expect(throws: Never.self) { try policy.checkPipelineDelete(automatic: false) }
        #expect(throws: EsclopError.self) { try policy.checkPipelineDelete(automatic: true) }
    }

    @Test func outputPathsCannotOverwriteExistingFiles() throws {
        let temp = TempDir()
        let source = temp.file("a.png")
        let existing = temp.file("out/a.webp")
        let policy = AgentPolicy(origin: .mcp, permissions: InMemorySettingsProvider())
        func job(_ template: String, _ operation: JobOperation = .convert(.webp)) -> OptimisationJob {
            OptimisationJob(request: OptimisationRequest(sources: [source], origin: .mcp, location: .path(template)), operation: operation)
        }
        #expect(throws: EsclopError.self) { try policy.check(job(existing.path)) }
        #expect(throws: EsclopError.self) { try policy.check(job(temp.url.appendingPathComponent("out").path + "/")) }
        #expect(throws: EsclopError.self) { try policy.check(job("%d/%f.%e", .optimise)) }
        #expect(throws: Never.self) { try policy.check(job(temp.url.appendingPathComponent("new").path + "/")) }
        #expect(throws: Never.self) { try policy.check(job("%d/%f-small.%e", .optimise)) }
        let two = OptimisationJob(request: OptimisationRequest(sources: [source, temp.file("b.png")], origin: .mcp, location: .path(temp.url.path + "/one.webp")), operation: .convert(.webp))
        #expect(throws: EsclopError.self) { try policy.check(two) }
        let allowed = AgentPolicy(origin: .mcp, permissions: InMemorySettingsProvider(values: ["allowOverwriteOriginals": true]))
        #expect(throws: Never.self) { try allowed.check(job(existing.path)) }
    }

    @Test func permissionsOpenEachDoor() {
        let all = InMemorySettingsProvider(values: Dictionary(uniqueKeysWithValues: AgentPermission.allCases.map { ($0.rawValue, JSONValue.bool(true)) }))
        let policy = AgentPolicy(origin: .mcp, permissions: all)
        #expect(policy.defaultLocation == .inPlace)
        #expect(throws: Never.self) { try policy.check(self.job(.inPlace), pipelineUsesScripts: true) }
        #expect(throws: Never.self) { try policy.checkRestore(deleteBackup: true) }
        #expect(throws: Never.self) { try policy.checkAutomationChange() }
    }

    @Test func agentsCanNeverGrantThemselvesPermissions() {
        let all = InMemorySettingsProvider(values: Dictionary(uniqueKeysWithValues: AgentPermission.allCases.map { ($0.rawValue, JSONValue.bool(true)) }))
        let policy = AgentPolicy(origin: .mcp, permissions: all)
        for permission in AgentPermission.allCases {
            #expect(throws: EsclopError.self) { try policy.checkSettingsChange(permission.descriptor) }
        }
    }

    @Test func refusalsNameTheSwitch() {
        let policy = AgentPolicy(origin: .mcp, permissions: InMemorySettingsProvider())
        do {
            try policy.check(job(.inPlace))
            Issue.record("expected a refusal")
        } catch let EsclopError.notPermitted(message) {
            #expect(message.contains("allowOverwriteOriginals"))
            #expect(message.contains("Settings → Agents and MCP"))
            #expect(message.contains("esclop://settings/agents/allowOverwriteOriginals"), "a link the person can click")
        } catch {
            Issue.record("wrong error \(error)")
        }
    }
}

@Suite struct Parsing {
    @Test func byteSizes() throws {
        #expect(try ByteSize.parse("2MB") == 2_000_000)
        #expect(try ByteSize.parse("500 kb") == 500_000)
        #expect(try ByteSize.parse("1.5MiB") == 1_572_864)
        #expect(try ByteSize.parse("300000") == 300_000)
        #expect(try ByteSize.parse("2m") == 2_000_000)
        #expect(throws: EsclopError.self) { try ByteSize.parse("big") }
        #expect(throws: EsclopError.self) { try ByteSize.parse("2 parsecs") }
        #expect(ByteSize.format(512) == "512 B")
        #expect(ByteSize.format(340_000) == "340 KB")
        #expect(ByteSize.format(1_234_567) == "1.2 MB")
    }

    @Test func ratiosAndCrops() throws {
        #expect(try AspectRatio.parse("16:9") == 16.0 / 9.0)
        #expect(try AspectRatio.parse("3x4") == 0.75)
        #expect(try AspectRatio.parse("0.5") == 0.5)
        #expect(abs(try AspectRatio.parse("a4") - 210.0 / 297.0) < 0.0001)
        #expect(try AspectRatio.parse("Kindle Paperwhite") == 1236.0 / 1648.0)
        #expect(throws: EsclopError.self) { try AspectRatio.parse("wide") }
        #expect(try AspectRatio.cropSize("1920x1080") == CropSize(width: 1920, height: 1080))
        #expect(try AspectRatio.cropSize("1600x") == CropSize(width: 1600))
        #expect(try AspectRatio.cropSize("x900") == CropSize(height: 900))
        #expect(try AspectRatio.cropSize("16:9", smart: true) == CropSize(aspectRatio: "16:9", smart: true))
        #expect(try AspectRatio.cropSize("1200", longEdge: true) == CropSize(longEdge: 1200))
        #expect(throws: EsclopError.self) { try AspectRatio.cropSize("big") }
    }

    @Test func paths() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(try PathInput.url("~/a.png") == home.appendingPathComponent("a.png").standardizedFileURL)
        #expect(try PathInput.url("file:///tmp/a%20b.png").path == "/tmp/a b.png")
        #expect(try PathInput.url("b.png", relativeTo: URL(fileURLWithPath: "/tmp")).path == "/tmp/b.png")
        #expect(try PathInput.url("'/tmp/q.png'").path == "/tmp/q.png")
        #expect(throws: EsclopError.self) { try PathInput.url("https://example.com/a.png") }
        #expect(throws: EsclopError.self) { try PathInput.url("  ") }
        #expect(PathInput.abbreviate(home.appendingPathComponent("x/y.png")) == "~/x/y.png")
    }

    @Test func folderExpansion() {
        let temp = TempDir()
        let a = temp.file("a.png"), b = temp.file("sub/b.jpg")
        _ = temp.file("notes.txt")
        #expect(PathInput.expand([temp.url], recursive: false) == [a.standardizedFileURL])
        #expect(Set(PathInput.expand([temp.url], recursive: true)) == Set([a.standardizedFileURL, b.standardizedFileURL]))
        #expect(PathInput.expand([temp.url], recursive: true, extensions: ["jpg"]) == [b.standardizedFileURL])
    }

    @Test func settingValues() throws {
        let bool = AgentPermission.allowRunScripts.descriptor
        #expect(try bool.parse("on") == .bool(true))
        #expect(throws: EsclopError.self) { try bool.parse("maybe") }
        let choice = SettingDescriptor(key: "k", title: "K", summary: "", type: .choice, defaultValue: "a", choices: ["webp", "avif"])
        #expect(try choice.parse("AVIF") == .string("avif"))
        #expect(throws: EsclopError.self) { try choice.parse("png") }
        let ranged = SettingDescriptor(key: "q", title: "Q", summary: "", type: .int, defaultValue: 1, minimum: 0, maximum: 100)
        #expect(try ranged.parse("42") == .int(42))
        #expect(throws: EsclopError.self) { try ranged.parse("101") }
        #expect(ranged.schema["type"] == "integer")
    }

    @Test func registryProviderUsesTheRegistry() throws {
        let store = SettingsStore(suiteName: "dev.esclop.tests.\(UUID().uuidString)")
        defer { store.removeAll() }
        let provider = RegistrySettingsProvider(store: store)
        #expect(!provider.isAllowed(.allowSettingsChanges))
        #expect(try provider.setValue("true", forKey: "allowSettingsChanges") == .bool(true))
        #expect(provider.isAllowed(.allowSettingsChanges))
        let all = provider.descriptors()
        #expect(all.count > 20, "every registry setting is listed")
        for permission in AgentPermission.allCases {
            let descriptor = try #require(all.first { $0.key == permission.rawValue })
            #expect(!descriptor.agentWritable)
            #expect(descriptor.type == .bool)
        }
        #expect(all.first { $0.key == "imageCompression" }?.agentWritable == true)
        #expect(throws: (any Error).self) { try provider.setValue("lots", forKey: "imageCompression") }
        #expect(throws: EsclopError.self) { try provider.value(forKey: "nope") }
    }

    @Test func summaries() {
        let summary = JobSummary(operation: "optimise", report: JobReport(results: [sampleResult("a.png"), sampleResult("b.png")], failures: [FileFailure(source: URL(fileURLWithPath: "/tmp/c.png"), error: .alreadySmaller)]))
        #expect(summary.savedPercent == 75)
        #expect(summary.text.contains("a.png 2.0 KB → 500 B (−75%) → /tmp/out-a.png"))
        #expect(summary.text.contains("✗ c.png: The file is already as small as it gets"))
        #expect(summary.text.contains("Total 4.0 KB → 1.0 KB (−75%) over 2 files"))
        #expect(summary.failures.first?.code == "alreadySmaller")
    }

    @Test func resultsLogDeduplicatesAndOrders() {
        let temp = TempDir()
        let log = ResultsLog(url: temp.url.appendingPathComponent("r.jsonl"), keep: 3, trimEvery: 1)
        let first = sampleResult("1.png"), second = sampleResult("2.png")
        log.append([first, second])
        log.append([first])
        #expect(log.recent(limit: 10).map(\.id) == [first.id, second.id])
        log.append((0 ..< 10).map { sampleResult("\($0).png") })
        #expect(log.recent(limit: 100).count <= 6)
    }

    /// Recent's Clear: no file name or path is left anywhere in the log, the CLI and MCP list
    /// nothing, and the saving still counts.
    @Test func clearingLeavesNoNameOrPathAndKeepsTheSaving() throws {
        let temp = TempDir()
        let url = temp.url.appendingPathComponent("r.jsonl")
        let log = ResultsLog(url: url)
        log.append([sampleResult("Holiday in Mallorca.png"), sampleResult("Secret plans.png")])
        let sizes = log.savings().map(\.bytesBefore)
        try log.redactAll()
        let text = try String(contentsOf: url, encoding: .utf8)
        for word in ["Holiday", "Mallorca", "Secret", "/tmp", "out-", "backup", ".png", "pngquant", "oxipng"] {
            #expect(!text.contains(word), "\(word) is still in the log")
        }
        #expect(log.recent(limit: 10).isEmpty, "the CLI and MCP list nothing")
        #expect(log.savings().map(\.bytesBefore) == sizes && log.savings().allSatisfy { $0.redacted == true }, "the saving stays")
        log.append([sampleResult("new.png")])
        #expect(log.recent(limit: 10).map(\.output.lastPathComponent) == ["out-new.png"], "what comes after is listed again")
    }

    @Test func theTrimKeepsTheLastEightDays() {
        let temp = TempDir()
        let log = ResultsLog(url: temp.url.appendingPathComponent("r.jsonl"), keep: 3, trimEvery: 1)
        var fresh = (0 ..< 8).map { sampleResult("\($0).png") }
        for index in fresh.indices { fresh[index].finishedAt = Date().addingTimeInterval(-Double(index) * 3600) }
        // The log is in the order results finish: the old ones first.
        log.append((0 ..< 8).map { sampleResult("old-\($0).png") })
        log.append(fresh.reversed())
        #expect(Set(log.savings().map(\.id)).isSuperset(of: fresh.map(\.id)), "the week's results stay for its saving")
        #expect(log.savings().count < 16, "old ones beyond the last three go")

        // All from this week: nothing can go, and the file is not rewritten on each append.
        let week = ResultsLog(url: temp.url.appendingPathComponent("w.jsonl"), keep: 2, trimEvery: 1)
        week.append(Array(fresh.prefix(5)))
        let written = try? FileManager.default.attributesOfItem(atPath: week.url.path)[.systemFileNumber] as? Int
        week.append([fresh[5]])
        #expect(week.savings().count == 6)
        #expect((try? FileManager.default.attributesOfItem(atPath: week.url.path)[.systemFileNumber] as? Int) == written, "appended in place, not replaced")
    }
    /// The trim reads the whole log: it runs on the first append in a process and then every
    /// `trimEvery` appends, not on each one.
    @Test func theTrimRunsOnASchedule() {
        let temp = TempDir()
        let log = ResultsLog(url: temp.url.appendingPathComponent("r.jsonl"), keep: 1, trimEvery: 3)
        func old(_ name: String) -> OptimisationResult { var result = sampleResult(name); result.finishedAt = .distantPast; return result }
        log.append((0 ..< 10).map { old("\($0).png") })
        #expect(log.savings().count == 1, "the first append trims")
        log.append([old("a.png")])
        log.append([old("b.png")])
        #expect(log.savings().count == 3, "the next ones only append")
        log.append([old("c.png")])
        #expect(log.savings().count == 1, "the third one trims again")
    }

    /// A log too small to need a trim is not read for one: each CLI run appends once, and would
    /// otherwise read the whole log every time.
    @Test func aSmallLogIsNotReadForATrim() throws {
        let temp = TempDir()
        let url = temp.url.appendingPathComponent("r.jsonl")
        // Thirty lines shorter than any real one: under the bound, though more than `keep * 2`.
        let tiny = Data(String(repeating: "{}\n", count: 30).utf8)
        try tiny.write(to: url)
        ResultsLog(url: url, keep: 10, trimEvery: 1).append([sampleResult()])
        #expect(try Data(contentsOf: url).prefix(tiny.count) == tiny, "left as it was")
    }

    /// A restored result, or one a re-run replaced, stops counting and leaves `recent`; it stays
    /// withdrawn after a clear.
    @Test func aWithdrawnResultNoLongerCountsOrLists() throws {
        let temp = TempDir()
        let log = ResultsLog(url: temp.url.appendingPathComponent("r.jsonl"))
        let first = sampleResult("a.png"), second = sampleResult("b.png")
        log.append([first, second])
        log.append([], withdrawing: [first])
        #expect(log.recent(limit: 10).map(\.id) == [second.id])
        #expect(log.savings().map(\.id) == [second.id])
        log.append([first])
        #expect(log.savings().map(\.id) == [second.id], "a batch that writes its results again at its end does not revive it")
        try log.redactAll()
        #expect(log.savings().map(\.id) == [second.id])
    }

    /// Lines carry where the request came from; lines written before 0.2 have no origin and
    /// still read.
    @Test func theOriginIsKeptAndOldLinesStillRead() throws {
        let temp = TempDir()
        let url = temp.url.appendingPathComponent("r.jsonl")
        let log = ResultsLog(url: url)
        var copied = sampleResult("copied.png")
        copied.origin = .clipboard
        log.append([copied])
        var old = try JSONSerialization.jsonObject(with: JSONCoding.wireEncoder().encode(sampleResult("old.png"))) as! [String: Any]
        old["origin"] = nil
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: old) + Data([0x0A]))
        try handle.close()
        #expect(log.recent(limit: 10).map(\.origin) == [nil, .clipboard])
    }

    /// Clear does not report success while the names are still on disk.
    @Test func clearFailsWhenTheLogCannotBeRead() throws {
        let temp = TempDir()
        let url = temp.url.appendingPathComponent("r.jsonl")
        let log = ResultsLog(url: url)
        log.append([sampleResult("Secret.png")])
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        #expect(throws: (any Error).self) { try log.redactAll() }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("Secret"))
        try FileManager.default.removeItem(at: url)
        try log.redactAll()
    }

    /// Without the lock, nothing writes or clears the log.
    @Test func nothingChangesWithoutTheLock() throws {
        let temp = TempDir()
        let url = temp.url.appendingPathComponent("r.jsonl")
        let log = ResultsLog(url: url)
        log.append([sampleResult("a.png")])
        let before = try Data(contentsOf: url)
        try FileManager.default.createDirectory(atPath: url.path + ".lock.tmp", withIntermediateDirectories: true)
        try FileManager.default.removeItem(atPath: url.path + ".lock")
        try FileManager.default.moveItem(atPath: url.path + ".lock.tmp", toPath: url.path + ".lock")
        log.append([sampleResult("b.png")])
        #expect(throws: (any Error).self) { try log.redactAll() }
        #expect(try Data(contentsOf: url) == before)
    }
}
