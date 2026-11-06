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
        let back = try #require(PDFDocument(url: output))
        #expect(back.page(at: 0)!.bounds(for: .cropBox) == CGRect(x: 0, y: 0, width: 600, height: 600))
    }

    @Test func extendPadsInsteadOfCutting() throws {
        let rect = PDFPageTools.cropRect(media: CGRect(x: 0, y: 0, width: 600, height: 600), rotation: 0, spec: PDFCropSpec(aspectRatio: 0.75, extend: true))
        #expect(rect.width == 600)
        #expect(abs(rect.height - 800) < 0.01)
        #expect(abs(rect.minY + 100) < 0.01)
    }

    @Test func exportsPages() throws {
        let temp = TempDir()
        let pdf = temp.pdf("doc.pdf", pages: [CGSize(width: 100, height: 200), CGSize(width: 100, height: 200), CGSize(width: 100, height: 200)])
        let written = try PDFPageTools().exportPages(pdf, pages: [1, 3], format: .png, dpi: 144, into: temp.url.appendingPathComponent("pages"))
        #expect(written.map(\.lastPathComponent) == ["doc-1.png", "doc-3.png"])
        let image = try #require(CGImageSourceCreateWithURL(written[0] as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == 200)
        #expect(image.height == 400)
        #expect(throws: EsclopError.self) { try PDFPageTools().exportPages(pdf, pages: [9], format: .png, dpi: 72, into: temp.url) }
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
        let suite = "dev.esclop.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let provider = RegistrySettingsProvider(store: SettingsStore(suiteName: suite))
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
        let log = ResultsLog(url: temp.url.appendingPathComponent("r.jsonl"), keep: 3)
        let first = sampleResult("1.png"), second = sampleResult("2.png")
        log.append([first, second])
        log.append([first])
        #expect(log.recent(limit: 10).map(\.id) == [first.id, second.id])
        log.append((0 ..< 10).map { sampleResult("\($0).png") })
        #expect(log.recent(limit: 100).count <= 6)
    }
}
