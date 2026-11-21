// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pipelines in the app do what their file says: the clipboard and drop-zone triggers run them,
// `hideResult` keeps the floating result away, the hotkey is registered, and every step that
// needs the app reaches it (through a fake desktop, so no app opens).

import AppKit
import EsclopCore
import EsclopIPC
import EsclopOptimisers
import EsclopPipelines
@testable import EsclopAppKit
import Foundation
import KeyboardShortcuts
import os
import Testing
import UniformTypeIdentifiers

@MainActor
@Suite struct PipelineTriggerTests {
    func save(_ text: String, name: String, in harness: Harness) throws {
        try harness.model.service.context.pipelines.save(PipelineParser.parse(text, name: name))
    }

    /// The pipeline ran: its run log is the result's steps.
    func ranPipeline(_ result: OptimisationResult?) -> Bool {
        result?.steps.contains { $0.hasPrefix("copyToClipboard") } ?? false
    }

    @Test func aCopyRunsTheClipboardPipeline() async throws {
        let harness = Harness()
        try save("---\ntriggers: clipboard\n---\n[image]\noptimise -> copyToClipboard(format: markdown)", name: "Clip", in: harness)
        let file = harness.temp.png("copied.png")
        harness.model.handleClipboard(harness.copy(files: [file]))
        #expect(await eventually { harness.model.cards.first?.result != nil })
        let result = try #require(harness.model.cards.first?.result)
        #expect(ranPipeline(result), "\(result.steps)")
        await harness.clipboardSettles()
        #expect(harness.pasteboard.string(forType: .string)?.hasPrefix("![copied](") == true, "the step's copy, not the put-back result")
        #expect(Clipboard.isOwnWrite(harness.pasteboard), "marked, so the watcher leaves it")

        // A kind the pipeline has no steps for gets the plain optimisation.
        let pdf = harness.temp.file("copied.pdf")
        harness.model.handleClipboard(harness.copy(files: [pdf]))
        #expect(await eventually { harness.model.cards.count == 2 && harness.model.cards.last?.result != nil })
        #expect(!ranPipeline(harness.model.cards.last?.result))
    }

    @Test func aClipboardPipelineLeavesTheCopiedFileAsItWas() async throws {
        let harness = Harness()
        try save("---\ntriggers: clipboard\n---\noptimise", name: "Clip", in: harness)
        let file = harness.temp.png("photo.png")
        let bytes = try Data(contentsOf: file)
        harness.model.handleClipboard(harness.copy(files: [file]))
        #expect(await eventually { harness.model.cards.first?.result != nil })
        let result = try #require(harness.model.cards.first?.result)
        #expect(try Data(contentsOf: file) == bytes, "copying is not a request to change the original")
        #expect(result.output.standardizedFileURL != file.standardizedFileURL)
        // The pipeline's result takes the original's place on the clipboard.
        #expect(await eventually { harness.pasteboard.string(forType: .string) == result.output.path })
    }

    @Test func copiedByMatchesTheAppTheCopyCameFrom() async throws {
        let harness = Harness()
        try save("---\ntriggers: clipboard\n---\nif(copiedBy: Preview) -> copyToClipboard", name: "Clip", in: harness)
        func copied() -> Bool { harness.model.cards.last?.result?.steps.contains { $0.hasPrefix("copyToClipboard") && $0.contains("done") } ?? false }
        harness.model.handleClipboard(harness.copy(image: pngData(), app: "com.apple.Preview"))
        #expect(await eventually { harness.model.cards.count == 1 && harness.model.cards[0].result != nil })
        #expect(copied(), "\(harness.model.cards[0].result?.steps ?? [])")
        harness.model.handleClipboard(harness.copy(image: pngData(width: 32), app: "com.example.Other"))
        #expect(await eventually { harness.model.cards.count == 2 && harness.model.cards[1].result != nil })
        #expect(!copied())
    }

    /// A pipeline's hotkey runs on what is on the clipboard now: `if(copiedBy:)` matches the
    /// app the clipboard watcher saw the copy come from, also when it left the copy alone.
    @Test func aHotkeyRunKnowsTheAppTheCopyCameFrom() async throws {
        let harness = Harness()
        try save("if(copiedBy: Preview) -> copyToClipboard", name: "Keys", in: harness)
        let pipeline = try harness.model.service.context.pipelines.load("Keys")
        let keeper = harness.model.clipboard
        let watcher = ClipboardWatcher(
            pasteboard: harness.pasteboard, policy: ClipboardPolicy(factory: harness.model.factory),
            frontmostApp: { "com.apple.Preview" }, onCopy: { keeper.noteCopy($0) }, onAction: { _ in }
        )
        _ = watcher.poll()
        harness.pasteboard.clearContents()
        harness.pasteboard.setData(pngData(), forType: .png)
        _ = watcher.poll()
        harness.model.runOnClipboard(pipeline)
        #expect(await eventually { harness.model.cards.count == 1 && harness.model.cards[0].result != nil })
        let steps = harness.model.cards[0].result?.steps ?? []
        #expect(steps.contains { $0.hasPrefix("copyToClipboard") && $0.contains("done") }, "\(steps)")
    }

    @Test func aLateFailureKeepsItsResultAndStepInTheAppsReport() async throws {
        let harness = Harness()
        try save("optimise -> openWith(app: NoSuchApp123)", name: "Late", in: harness)
        var job = harness.job(harness.temp.png("late.png"))
        job.operation = .pipeline("Late")
        let report = await harness.model.run(job)
        let partial = try #require(report.results.first, "the optimised file is reported")
        #expect(partial.backup != nil)
        #expect(report.failures.first?.step?.hasPrefix("openWith") == true, "\(report.failures)")
    }

    @Test func finderRunsAPipelineLikeAPlainFinderOptimisation() async throws {
        let harness = Harness()
        let pipeline = try PipelineParser.parse("---\ntriggers: rightClick\n---\noptimise", name: "Web")
        try harness.model.service.context.pipelines.save(pipeline)
        let services = FinderServices(model: harness.model, pipelines: { [pipeline] })
        let files = (1 ... harness.model.batchThreshold).map { harness.temp.png("finder-\($0).png") }
        services.handle(.runPipeline, files: files)
        #expect(harness.model.batch?.origin == .finder, "many files go to one batch window")
        #expect(harness.model.batch?.rows.count == files.count)
        #expect(harness.model.cards.isEmpty)
        #expect(await eventually { harness.requests.requests.count == files.count })
        #expect(harness.requests.requests.allSatisfy { $0.origin == .finder })
    }

    @Test func copiedPixelsRunTheClipboardPipeline() async throws {
        let harness = Harness()
        try save("---\ntriggers: clipboard\n---\noptimise -> copyToClipboard", name: "Clip", in: harness)
        harness.model.handleClipboard(harness.copy(image: pngData()))
        #expect(await eventually { harness.model.cards.first?.result != nil })
        #expect(ranPipeline(harness.model.cards.first?.result))
    }

    @Test func aDropRunsTheDropZonePipelineAndHarderDoesNot() async throws {
        let harness = Harness()
        try save("---\ntriggers: dropZone\n---\noptimise -> copyToClipboard", name: "Drop", in: harness)
        harness.model.optimiseDropped([harness.temp.png("a.png")], harder: false)
        #expect(await eventually { harness.model.cards.first?.result != nil })
        #expect(ranPipeline(harness.model.cards.first?.result))
        harness.model.optimiseDropped([harness.temp.png("b.png")], harder: true)
        #expect(await eventually { harness.model.cards.count == 2 && harness.model.cards.last?.result != nil })
        #expect(!ranPipeline(harness.model.cards.last?.result))
        #expect(harness.requests.requests.last?.quality == .aggressive)
    }

    @Test func aQuietPipelineShowsNoResult() async throws {
        let harness = Harness()
        try save("---\ntriggers: dropZone\nhideResult: true\n---\noptimise", name: "Quiet", in: harness)
        harness.model.optimiseDropped([harness.temp.png("a.png")], harder: false)
        #expect(await eventually { harness.model.recent.count == 1 })
        #expect(harness.model.cards.isEmpty, "no floating result")
        // Many files: no batch window either.
        try EsclopSettings.batchWindowFrom.set(2, in: harness.settings.store)
        harness.model.optimiseDropped((1 ... 3).map { harness.temp.png("many-\($0).png") }, harder: false)
        #expect(await eventually { harness.model.recent.count == 4 })
        #expect(harness.model.batch == nil && harness.model.cards.isEmpty)
        // A watched folder's run is quiet too.
        try save("---\ntriggers: folder(\"~/Nowhere\")\nhideResult: true\n---\noptimise", name: "Folder", in: harness)
        await harness.model.runPipeline("Folder", onWatched: harness.temp.png("new.png"))
        #expect(await eventually { harness.model.recent.count == 5 })
        #expect(harness.model.cards.isEmpty)
    }

    @Test func aPipelineHotkeyIsRegisteredAndRunsOnTheClipboard() async throws {
        let harness = Harness()
        try save("---\nhotkey: ctrl+alt+shift+cmd+f19\n---\noptimise -> copyToClipboard", name: "Hotkey test", in: harness)
        let pipeline = try harness.model.service.context.pipelines.load("Hotkey test")
        Hotkeys.register([pipeline], model: harness.model)
        defer { Hotkeys.register([], model: harness.model) }
        #expect(KeyboardShortcuts.getShortcut(for: Hotkeys.name(for: "Hotkey test")) == .init(.f19, modifiers: [.control, .option, .shift, .command]))
        Hotkeys.register([], model: harness.model)
        #expect(KeyboardShortcuts.getShortcut(for: Hotkeys.name(for: "Hotkey test")) == nil, "taken back when the pipeline changes")

        harness.pasteboard.clearContents()
        harness.pasteboard.writeObjects([harness.temp.png("held.png")] as [NSURL])
        harness.model.runOnClipboard(pipeline)
        #expect(await eventually { harness.model.cards.first?.result != nil })
        #expect(ranPipeline(harness.model.cards.first?.result))
    }

    @Test func hotkeysReadAsWritten() {
        #expect(Hotkeys.shortcut("ctrl+alt+cmd+b") == .init(.b, modifiers: [.control, .option, .command]))
        #expect(Hotkeys.shortcut("Shift + Cmd + 7") == .init(.seven, modifiers: [.shift, .command]))
        #expect(Hotkeys.shortcut("⌃⌥ + space") == nil, "modifiers are separate parts")
        #expect(Hotkeys.shortcut("b") == nil, "a global key needs a modifier")
        #expect(Hotkeys.shortcut("ctrl+b+c") == nil)
        #expect(Hotkeys.shortcut("ctrl+nope") == nil)
    }

    @Test func aForkShowsAsAResultOfItsOwn() async throws {
        let harness = Harness()
        try save("fork -> optimise", name: "Fork", in: harness)
        let file = harness.temp.png("f.png")
        var job = harness.job(file)
        job.operation = .pipeline("Fork")
        await harness.model.run(job)
        #expect(harness.model.cards.count == 2, "the pipeline's result and the fork")
        let fork = try #require(harness.model.cards.compactMap(\.result).first { $0.steps == ["fork"] })
        #expect(fork.source == file && fork.output != file)
        #expect(FileManager.default.fileExists(atPath: fork.output.path))
    }
}

/// The app host's steps, each through a fake desktop.
@MainActor
@Suite struct AppPipelineHostTests {
    final class FakeDesktop: PipelineDesktop {
        struct Calls { var texts: [String] = []; var images: [UTType] = []; var opened: [(URL, URL)] = []; var forks: [URL] = [] }
        let calls = OSAllocatedUnfairLock(initialState: Calls())
        let apps: [String: URL]
        let installedIDs: Set<String>

        init(apps: [String: URL] = [:], installed: Set<String> = []) {
            self.apps = apps
            installedIDs = installed
        }

        func copy(text: String) async { calls.withLock { $0.texts.append(text) } }
        func copy(imageData: Data, type: UTType) async { calls.withLock { $0.images.append(type) } }
        func app(named name: String, toOpen file: URL) async -> URL? { apps[name] }
        func installed(_ bundleIDs: [String]) async -> [URL] {
            bundleIDs.filter(installedIDs.contains).map { URL(fileURLWithPath: "/Applications/\($0).app") }
        }
        func open(_ file: URL, with app: URL) async throws { calls.withLock { $0.opened.append((file, app)) } }
        func presentFork(_ file: URL) async { calls.withLock { $0.forks.append(file) } }
    }

    let temp = TempDir()

    func host(_ desktop: FakeDesktop?) -> AppPipelineHost {
        AppPipelineHost(uploader: nil, desktop: desktop) { _ in }
    }

    func perform(_ action: PipelineHostAction, on desktop: FakeDesktop?, file: URL? = nil) async throws -> PipelineHostOutcome {
        try await host(desktop).perform(action, file: file ?? temp.png("p.png"), options: PipelineRunOptions())
    }

    @Test func theClipboardStepsCopy() async throws {
        let desktop = FakeDesktop()
        try FileManager.default.createDirectory(at: temp.url.appendingPathComponent("blog"), withIntermediateDirectories: true)
        let file = temp.png("blog/p.png")
        _ = try await perform(.copyToClipboard(format: .path, relativeTo: nil), on: desktop, file: file)
        _ = try await perform(.copyToClipboard(format: .markdown, relativeTo: temp.url.path), on: desktop, file: file)
        _ = try await perform(.copyToClipboard(format: .imageData, relativeTo: nil), on: desktop, file: file)
        let calls = desktop.calls.withLock { $0 }
        #expect(calls.texts == [file.path, "![p](blog/p.png)"])
        #expect(calls.images == [.png])
        guard case .unavailable = try await perform(.copyToClipboard(format: .imageData, relativeTo: nil), on: desktop, file: temp.file("a.pdf")) else {
            Issue.record("a PDF is not image data")
            return
        }
    }

    @Test func openWithOpensTheNamedAppOrFails() async throws {
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        let desktop = FakeDesktop(apps: ["Preview": preview])
        let outcome = try await perform(.open(app: "Preview"), on: desktop)
        #expect(outcome == .handled(nil))
        #expect(desktop.calls.withLock { $0.opened.map(\.1) } == [preview])
        await #expect(throws: EsclopError.self) { try await perform(.open(app: "NoSuchApp123"), on: desktop) }
        await #expect(throws: EsclopError.self, "a path is not an app name") { try await perform(.open(app: "../Preview"), on: FakeDesktop(apps: ["../Preview": preview])) }
    }

    @Test func shelfAndUploadAppsGetTheFileWhenInstalled() async throws {
        let desktop = FakeDesktop(installed: ["at.EternalStorms.Yoink-setapp", "net.mkswap.Dropshare5", "com.Ebullioscopic.Atoll"])
        #expect(try await perform(.shelve(app: "yoink"), on: desktop) == .handled(nil))
        #expect(try await perform(.shelve(app: "atoll"), on: desktop) == .handled(nil))
        #expect(try await perform(.upload(app: "dropshare"), on: desktop) == .handled(nil))
        #expect(desktop.calls.withLock { $0.opened.map(\.1.lastPathComponent) } == ["at.EternalStorms.Yoink-setapp.app", "com.Ebullioscopic.Atoll.app", "net.mkswap.Dropshare5.app"])
        #expect(try await perform(.shelve(app: "dockside"), on: desktop) == .unavailable("Dockside is not installed."))
        // Every shelf app the language names has bundle ids, and the Share tab offers them.
        #expect(Set(AppPipelineHost.shelves.map(\.name)) == Set(EsclopPipelines.shelfApps))
        #expect(AppModel.shelfApps.contains("com.Ebullioscopic.Atoll"))
    }

    /// Dropshare from Setapp: either of its bundle ids, or the app found by its name, as Clop does.
    @Test func dropshareFromSetappIsFound() async throws {
        let setapp = FakeDesktop(installed: ["net.mkswap.Dropshare-setapp"])
        #expect(try await perform(.upload(app: "dropshare"), on: setapp) == .handled(nil))
        #expect(setapp.calls.withLock { $0.opened.map(\.1.lastPathComponent) } == ["net.mkswap.Dropshare-setapp.app"])
        let byName = URL(fileURLWithPath: "/Applications/Setapp/Dropshare.app")
        let named = FakeDesktop(apps: ["Dropshare": byName])
        #expect(try await perform(.upload(app: "dropshare"), on: named) == .handled(nil))
        #expect(named.calls.withLock { $0.opened.map(\.1) } == [byName])
        #expect(try await perform(.upload(app: "dropshare"), on: FakeDesktop()) == .unavailable("Dropshare is not installed."))
    }

    @Test func aForkIsPresentedAndSharingSaysWhyNot() async throws {
        let desktop = FakeDesktop()
        let file = temp.png("fork.png")
        _ = try await perform(.presentFork, on: desktop, file: file)
        #expect(desktop.calls.withLock { $0.forks } == [file])
        guard case let .unavailable(reason) = try await perform(.copyLinkForSending(expiration: nil), on: desktop) else {
            Issue.record("sending a link has no service")
            return
        }
        #expect(reason.contains("upload(to:)"))
    }

    @Test func anAgentsRunReachesNoDesktop() async throws {
        #expect(try await perform(.copyToClipboard(format: .path, relativeTo: nil), on: nil) == .unavailable("needs the esclop app"))
        #expect(try await perform(.presentFork, on: nil) == .unavailable("needs the esclop app"))
    }
}
