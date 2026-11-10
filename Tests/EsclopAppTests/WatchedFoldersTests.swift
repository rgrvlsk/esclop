// SPDX-License-Identifier: GPL-3.0-or-later

import EsclopCore
import EsclopIPC
import EsclopPipelines
@testable import EsclopAppKit
import Foundation
import Testing

/// What a new file in a watched folder gets, without a file system.
@Suite struct WatchPlanTests {
    let folder = URL(fileURLWithPath: "/watched")
    var targets: [WatchTarget] { [WatchTarget(folder: folder, kinds: [.image, .video])] }
    let limits: (MediaKind) -> (min: Int, max: Int) = { _ in (min: 1000, max: 10_000_000) }

    func decide(_ name: String, in targets: [WatchTarget]? = nil, size: Int = 100_000, marked: Bool = false, justWritten: Bool = false) -> WatchDecision {
        WatchPlan.decide(
            folder.appendingPathComponent(name), targets: targets ?? self.targets, size: size, isMarked: marked,
            justWritten: justWritten, limits: limits
        )
    }

    @Test func aNewScreenshotIsOptimised() {
        #expect(decide("Screenshot 2026-11-10 at 10.15.00.png") == .optimise(.image))
        #expect(decide("Screen Recording.mov") == .optimise(.video))
    }

    @Test func hiddenTemporaryAndPartialFilesAreLeftAlone() {
        for name in [".Screenshot.png", ".DS_Store", "~$draft.png", "photo.png.download", "clip.mov.crdownload", "a.png.part"] {
            #expect(decide(name) == .skip(.hidden), "\(name)")
        }
    }

    @Test func onlyTheKindsTheListsAskFor() {
        #expect(decide("report.pdf") == .skip(.notWatched), "PDFs are not watched in this folder")
        #expect(decide("notes.txt") == .skip(.unsupported))
    }

    @Test func onlyFilesDirectlyInTheFolder() {
        #expect(WatchPlan.decide(
            folder.appendingPathComponent("exports/a.png"), targets: targets, size: 100_000, isMarked: false, justWritten: false, limits: limits
        ) == .skip(.notWatched))
    }

    @Test func optimisedOrJustWrittenFilesAreNotOptimisedAgain() {
        #expect(decide("a.png", marked: true) == .skip(.alreadyOptimised))
        #expect(decide("a.png", justWritten: true) == .skip(.justWritten))
    }

    @Test func sizeLimitsApplyToThePlainOptimisation() {
        #expect(decide("a.png", size: 0) == .skip(.empty))
        #expect(decide("a.png", size: 500) == .skip(.tooSmall))
        #expect(decide("a.png", size: 20_000_000) == .skip(.tooLarge))
    }

    @Test func aPipelineRunsInsteadForTheKindsItHasStepsFor() {
        let target = WatchTarget(folder: folder, kinds: [.image, .video], pipeline: "web", pipelineKinds: [.image])
        #expect(decide("a.png", in: [target]) == .pipeline("web", .image))
        #expect(decide("a.png", in: [target], size: 500) == .pipeline("web", .image), "the pipeline decides what is too small")
        #expect(decide("a.mov", in: [target]) == .optimise(.video), "no video steps: the plain optimisation")
        #expect(decide("a.png", in: [target], marked: true) == .skip(.alreadyOptimised))
    }

    @Test func targetsComeFromTheListsAndThePipelineTriggers() throws {
        let settings = TestSettings()
        try EsclopSettings.imageDirs.set(["~/Desktop", "/tmp/shots"], in: settings.store)
        try EsclopSettings.videoDirs.set(["~/Desktop"], in: settings.store)
        try EsclopSettings.enableAutomaticPDFOptimisations.set(false, in: settings.store)
        try EsclopSettings.pdfDirs.set(["/tmp/papers"], in: settings.store)
        let images = PipelineSection(kind: .image, steps: [.optimise()])
        let pipelines = [
            Pipeline(name: "zeta", triggers: [.folder("/tmp/shots")], sections: [images]),
            Pipeline(name: "alpha", triggers: [.folder("/tmp/shots"), .clipboard], sections: [images]),
            Pipeline(name: "drop", triggers: [.folder("/tmp/drop")], sections: [PipelineSection(steps: [.optimise()])]),
        ]
        let targets = WatchPlan.targets(settings: settings.store, pipelines: pipelines)
        let desktop = WatchPlan.canonical("~/Desktop")
        #expect(targets.map(\.folder) == [desktop, WatchPlan.canonical("/tmp/shots"), WatchPlan.canonical("/tmp/drop")], "one entry per folder; PDFs are off")
        #expect(targets[0].kinds == [.image, .video] && targets[0].pipeline == nil)
        #expect(targets[1].pipeline == "alpha", "the first pipeline by name wins a folder")
        #expect(targets[1].pipelineKinds == [.image])
        #expect(targets[2].kinds.isEmpty && targets[2].pipelineKinds == Set(MediaKind.allCases), "an any-file pipeline watches its folder for every kind")
    }

    @Test func aBurstLargerThanTheCountIsTooLarge() throws {
        let settings = TestSettings()
        #expect(WatchPlan.countLimit(.image, settings: settings.store) == 4, "Clop's counts")
        #expect(WatchPlan.countLimit(.video, settings: settings.store) == 1)
        #expect(WatchPlan.countLimit(.pdf, settings: settings.store) == 2)
        #expect(WatchPlan.countLimit(.audio, settings: settings.store) == 2)
        let files = (1 ... 5).map { URL(fileURLWithPath: "/w/\($0).png") }
        #expect(Burst(kind: .image, files: Array(files.prefix(4)), limit: 4).isTooLarge == false)
        #expect(Burst(kind: .image, files: files, limit: 4).isTooLarge)
    }

    @Test func theMenuSaysHowManyFoldersAreWatched() {
        #expect(MenuContent.foldersLine(count: 0, paused: false) == nil)
        #expect(MenuContent.foldersLine(count: 1, paused: false) == "Watching 1 folder")
        #expect(MenuContent.foldersLine(count: 3, paused: false) == "Watching 3 folders")
        #expect(MenuContent.foldersLine(count: 3, paused: true) == nil, "the menu already says it is paused")
        let ca = Locale(identifier: "ca_ES")
        #expect(Strings.format("Watching %d folders", 3, locale: ca) == "Vigilant 3 carpetes")
    }

    @Test func aFolderThatIsNotThereIsMissing() {
        let temp = TempDir()
        #expect(FolderStatus.check(temp.url) == .watching)
        #expect(FolderStatus.check(temp.url.appendingPathComponent("gone")) == .missing)
        #expect(FolderStatus.check(temp.file("a.png")) == .missing, "a file is not a folder")
    }

    @Test func aFolderTheAppCannotReadSaysSo() throws {
        let temp = TempDir()
        let locked = temp.url.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        #expect(FolderStatus.check(locked) == .unreadable)
        #expect(FolderRow.problem(.unreadable)?.contains("Files and Folders") == true)
        #expect(FolderRow.problem(.missing) != nil)
        #expect(FolderRow.problem(.watching) == nil)
    }
}

/// Waiting for a file that is still being written.
@Suite struct FileSettleTests {
    /// A writer appends for a second; the wait ends only after it stopped.
    @Test func aFileStillBeingWrittenWaits() async throws {
        let temp = TempDir()
        let file = temp.file("recording.mov", bytes: 1000)
        let finished = Flag()
        let writer = Task.detached {
            let handle = try FileHandle(forWritingTo: file)
            for _ in 0 ..< 20 {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(repeating: 0x41, count: 1000))
                try await Task.sleep(for: .milliseconds(50))
            }
            try handle.close()
            finished.set()
        }
        let settled = await FileSettle.wait(for: file, interval: .milliseconds(150))
        #expect(settled)
        #expect(finished.isSet, "the wait ended only once the writer stopped")
        #expect(FileSettle.snapshot(file)?.size == 21000)
        try await writer.value
    }

    @Test func aFileThatGoesAwayDoesNotSettle() async {
        let temp = TempDir()
        let file = temp.file("a.png")
        try? FileManager.default.removeItem(at: file)
        #expect(await FileSettle.wait(for: file, interval: .milliseconds(20)) == false)
    }

    @Test func anEmptyFileDoesNotSettle() async {
        let temp = TempDir()
        let file = temp.file("a.png", bytes: 0)
        #expect(await FileSettle.wait(for: file, interval: .milliseconds(20), timeout: .milliseconds(300)) == false)
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// The watcher end to end: real FSEvents on a temporary folder, the test engine behind the model.
@MainActor @Suite(.serialized) struct WatchedFoldersTests {
    @MainActor struct Rig {
        let harness = Harness()
        let folder: URL
        let folders: WatchedFolders
        var store: PipelineStore

        init(pipelines: [Pipeline] = []) throws {
            folder = harness.temp.url.appendingPathComponent("Shots", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Only this folder: the defaults would also watch the real Desktop for videos.
            try EsclopSettings.imageDirs.set([folder.path], in: harness.settings.store)
            for (_, _, list) in WatchPlan.lists where list.key != EsclopSettings.imageDirs.key { try list.set([], in: harness.settings.store) }
            try EsclopSettings.enableAutomaticImageOptimisations.set(true, in: harness.settings.store)
            store = PipelineStore(directory: EsclopLocations(support: harness.temp.url.appendingPathComponent("support", isDirectory: true)).pipelines, useTrash: false)
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            for pipeline in pipelines { _ = try store.save(pipeline) }
            let store = store
            folders = WatchedFolders(model: harness.model, pipelines: { (try? store.list()) ?? [] })
            folders.burstWindow = .milliseconds(300)
            folders.settle = { await FileSettle.wait(for: $0, interval: .milliseconds(100)) }
            folders.refresh()
        }

        /// A file written in one go, the way screencapture saves a screenshot.
        func land(_ name: String, bytes: Int = 100_000) -> URL {
            let file = folder.appendingPathComponent(name)
            try? Data(repeating: 0x41, count: bytes).write(to: file, options: .atomic)
            return file
        }
    }

    @Test func aNewFileIsOptimisedOnceAndShowsAFloatingResult() async throws {
        let rig = try Rig()
        #expect(rig.folders.isWatching)
        #expect(rig.harness.model.watchedFolderCount == 1)
        let file = rig.land("Screenshot.png")
        #expect(await eventually { rig.harness.model.recent.count == 1 })
        let result = try #require(rig.harness.model.recent.first)
        #expect(result.source.lastPathComponent == file.lastPathComponent)
        #expect(rig.harness.requests.requests.first?.origin == .watchedFolder)
        #expect(rig.harness.model.cards.contains { $0.source.lastPathComponent == "Screenshot.png" }, "a floating result")
        // The engine rewrote the file in place, which is a new event for it; L'Esclop wrote it,
        // so it is not optimised again. Repeated events for one file count once too.
        rig.folders.received([file, file])
        try await Task.sleep(for: .seconds(2))
        #expect(rig.harness.requests.requests.count == 1, "nothing is optimised twice")
        rig.folders.stop()
    }

    @Test func aMarkedFileIsLeftAlone() async throws {
        let rig = try Rig()
        let file = rig.folder.appendingPathComponent("done.png")
        let staging = rig.harness.temp.file("staging/done.png")
        try OptimisedMark.set(staging, note: "test")
        try FileManager.default.moveItem(at: staging, to: file)
        let other = rig.land("new.png")
        #expect(await eventually { rig.harness.model.recent.count == 1 })
        try await Task.sleep(for: .seconds(1))
        #expect(rig.harness.requests.requests.map { $0.sources.first?.lastPathComponent } == [other.lastPathComponent])
        rig.folders.stop()
    }

    @Test func pauseStopsTheWatcher() async throws {
        let rig = try Rig()
        rig.harness.model.onPauseChange = { [folders = rig.folders] in folders.refresh() }
        rig.harness.model.setPaused(true)
        #expect(rig.folders.isWatching == false)
        #expect(rig.harness.model.watchedFolderCount == 0)
        _ = rig.land("while-paused.png")
        try await Task.sleep(for: .seconds(2))
        #expect(rig.harness.requests.requests.isEmpty, "paused: nothing is optimised")
        rig.harness.model.setPaused(false)
        #expect(rig.folders.isWatching)
        _ = rig.land("after.png")
        #expect(await eventually { rig.harness.model.recent.count == 1 })
        #expect(rig.harness.requests.requests.map { $0.sources.first?.lastPathComponent } == ["after.png"])
        rig.folders.stop()
    }

    @Test func tooManyFilesAtOnceAreSkippedWithANotice() async throws {
        let rig = try Rig()
        rig.folders.burstWindow = .seconds(1)
        rig.harness.model.hideDelayOverride = .seconds(600)
        for index in 1 ... 5 { _ = rig.land("copied \(index).png") }
        #expect(await eventually {
            rig.harness.model.cards.contains { if case .notice = $0.phase { return true } else { return false } }
        })
        let notice = try #require(rig.harness.model.cards.first { if case .notice = $0.phase { return true } else { return false } })
        if case let .notice(title, detail) = notice.phase {
            #expect(title == "More than 4 new images at once")
            #expect(detail.contains("Shots"))
        }
        try await Task.sleep(for: .seconds(1))
        #expect(rig.harness.requests.requests.isEmpty)
        rig.folders.stop()
    }

    @Test func aFileStillBeingWrittenWaitsBeforeItIsOptimised() async throws {
        let rig = try Rig()
        let file = rig.folder.appendingPathComponent("Recording.png")
        FileManager.default.createFile(atPath: file.path, contents: Data(repeating: 0x41, count: 10000))
        let handle = try FileHandle(forWritingTo: file)
        for _ in 0 ..< 15 {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(repeating: 0x41, count: 10000))
            try await Task.sleep(for: .milliseconds(80))
            #expect(rig.harness.requests.requests.isEmpty, "not while it grows")
        }
        try handle.close()
        #expect(await eventually { rig.harness.model.recent.count == 1 })
        #expect(rig.harness.model.recent.first?.bytesBefore == 160_000, "the whole file, once it stopped")
        rig.folders.stop()
    }

    @Test func aPipelineTriggerRunsThePipelineInstead() async throws {
        let out = TempDir()
        let rigFolder = TempDir()
        let pipeline = Pipeline(
            name: "Shots to web", triggers: [.folder(rigFolder.url.path)],
            sections: [PipelineSection(kind: .image, steps: [.copy(to: out.url.path)])]
        )
        let rig = try Rig(pipelines: [pipeline])
        try EsclopSettings.imageDirs.set([], in: rig.harness.settings.store)
        rig.folders.refresh()
        #expect(rig.folders.targets.map(\.pipeline) == ["Shots to web"])
        let file = rigFolder.url.appendingPathComponent("shot.png")
        try pngData().write(to: file, options: .atomic)
        let copied = out.url.appendingPathComponent("shot.png")
        #expect(await eventually { FileManager.default.fileExists(atPath: copied.path) }, "the pipeline's copy step ran")
        #expect(rig.harness.requests.requests.allSatisfy { $0.origin == .watchedFolder })
        rig.folders.stop()
    }

    @Test func savingAPipelineWithAFolderTriggerStartsWatchingIt() throws {
        let rig = try Rig()
        let other = TempDir()
        _ = try rig.store.save(Pipeline(name: "inbox", triggers: [.folder(other.url.path)], sections: [PipelineSection(steps: [.optimise()])]))
        rig.folders.refresh()
        #expect(rig.folders.targets.count == 2, "its own folder and the pipeline's")
        #expect(rig.harness.model.watchedFolderCount == 2)
        rig.folders.stop()
    }
}
