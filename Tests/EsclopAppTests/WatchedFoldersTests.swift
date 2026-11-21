// SPDX-License-Identifier: GPL-3.0-or-later

import CoreServices
import EsclopCore
import EsclopIPC
import EsclopPipelines
@testable import EsclopAppKit
import Foundation
import Testing

/// What a new file in a watched folder gets, without a file system.
@MainActor
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

    /// G5: a folder's formats to skip and its ignore file leave files alone, pipelines' too.
    @Test func aFolderSkipsItsFormatsAndWhatItsIgnoreFileNames() {
        let ruled = [WatchTarget(folder: folder, kinds: [.image, .video], pipeline: "web", pipelineKinds: [.video], rules: FolderRules(folder: "/watched", skipFormats: ["GIF", ".heic"]))]
        #expect(decide("a.gif", in: ruled) == .skip(.skippedFormat))
        #expect(decide("a.HEIC", in: ruled) == .skip(.skippedFormat))
        #expect(decide("a.png", in: ruled) == .optimise(.image))
        let jpegs = [WatchTarget(folder: folder, kinds: [.image], rules: FolderRules(folder: "/watched", skipFormats: ["jpg"]))]
        #expect(decide("a.jpeg", in: jpegs) == .skip(.skippedFormat), "jpg names the type")
        #expect(WatchPlan.decide(folder.appendingPathComponent("a.mov"), targets: ruled, size: 100_000, isMarked: false, justWritten: false, ignored: true, limits: limits) == .skip(.ignored))
    }

    @Test func ignorePatternsWorkAsGitignoreDoes() {
        let patterns = ["# exports", "", "*.tmp.png", "draft-*", "!draft-final.png", "/Screen Recording*", "**/raw?.mov", "build/"]
        for name in ["a.tmp.png", "draft-1.png", "DRAFT-2.PNG", "Screen Recording 2026.mov", "raw1.mov"] {
            #expect(IgnoreFile.ignores(name, patterns: patterns), "\(name)")
        }
        for name in ["a.png", "draft-final.png", "raw12.mov", "build"] {
            #expect(!IgnoreFile.ignores(name, patterns: patterns), "\(name)")
        }
    }

    @Test func pixelLimitsUseTheLongerSide() {
        let rules = FolderRules(folder: "/watched", minPixels: 200, maxPixels: 4000)
        #expect(rules.skip(longerSide: 64) == .tooFewPixels)
        #expect(rules.skip(longerSide: 5000) == .tooManyPixels)
        #expect(rules.skip(longerSide: 1920) == nil)
        #expect(rules.skip(longerSide: nil) == nil, "an unknown size passes")
        #expect(FolderRules(folder: "/watched").skip(longerSide: 1) == nil)
    }

    /// The setting holds one JSON object per folder; an edit replaces that folder's entry, an
    /// emptied one goes, and the targets carry each folder's rules.
    @Test func rulesAreStoredPerFolder() throws {
        let settings = TestSettings()
        var list = FolderRules.replacing(FolderRules(folder: "~/Desktop", skipFormats: ["gif"]), in: ["not json"])
        list = FolderRules.replacing(FolderRules(folder: "/watched", minPixels: 100), in: list)
        list = FolderRules.replacing(FolderRules(folder: "~/Desktop", maxPixels: 900), in: list)
        #expect(list.count == 3 && list[0] == "not json")
        try EsclopSettings.watchedFolderRules.set(list, in: settings.store)
        #expect(FolderRules.all(in: settings.store) == [FolderRules(folder: "/watched", minPixels: 100), FolderRules(folder: "~/Desktop", maxPixels: 900)])
        #expect(FolderRules.replacing(FolderRules(folder: "/watched"), in: list).count == 2, "an empty entry goes")
        try EsclopSettings.imageDirs.set(["/watched"], in: settings.store)
        try EsclopSettings.enableAutomaticImageOptimisations.set(true, in: settings.store)
        let target = try #require(WatchPlan.targets(settings: settings.store, pipelines: []).first { $0.folder == WatchPlan.canonical("/watched") })
        #expect(target.rules?.minPixels == 100)
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
        #expect(FolderRow.problem(.unreadable)?.contains("Files & Folders") == true)
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
        #expect(settled == .steady)
        #expect(finished.isSet, "the wait ended only once the writer stopped")
        #expect(FileSettle.snapshot(file)?.size == 21000)
        try await writer.value
    }

    /// A network copy that stalls for 0.7 s between writes is not taken for a finished file.
    @Test func aCopyThatStallsIsStillWaitedFor() async throws {
        let temp = TempDir()
        let file = temp.file("export.mov", bytes: 1000)
        let finished = Flag()
        // The copier is another process: its own thread, so a loaded cooperative pool cannot
        // hold the second write past the 1.5 s the wait asks for (it once came 13 s late on CI).
        Thread {
            Thread.sleep(forTimeInterval: 0.7)
            if let handle = try? FileHandle(forWritingTo: file) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(repeating: 0x41, count: 1000))
                try? handle.close()
            }
            finished.set()
        }.start()
        // Two still checks 150 ms apart would take the stall for the end.
        let settled = await FileSettle.wait(for: file, interval: .milliseconds(150))
        #expect(settled == .steady)
        #expect(finished.isSet, "the wait outlasted the stall")
        #expect(FileSettle.snapshot(file)?.size == 2000)
    }

    /// A file moved in with an old date is complete: the checks alone settle it.
    @Test func aFileThatArrivesCompleteTakesTheChecksAlone() async throws {
        let temp = TempDir()
        let file = temp.file("moved.png")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: file.path)
        #expect(await FileSettle.wait(for: file, interval: .milliseconds(20), quiet: 600) == .steady)
    }

    /// A clock that moves only when the wait sleeps.
    final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: Date
        init(_ start: Date) { time = start }
        var now: Date { lock.withLock { time } }
        func sleep(_ duration: Duration) { lock.withLock { time += Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18 } }
    }

    /// G6b on a fake clock: a file that arrived whole settles after the two checks (0.6 s, as
    /// before the quiet time came in); one written a moment ago waits until it is 1.5 s old
    /// (the next check after, 1.8 s, when the float sum falls just short).
    @Test func aWholeFileTakesTheChecksAndAGrowingOneWaitsForQuiet() async throws {
        let temp = TempDir()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        for (whole, expected) in [(true, 0.59 ... 0.61), (false, 1.49 ... 1.81)] {
            let file = temp.file("shot-\(whole).png")
            try FileManager.default.setAttributes([.modificationDate: start], ofItemAtPath: file.path)
            let clock = FakeClock(start)
            let settled = await FileSettle.wait(for: file, quiet: whole ? 0 : FileSettle.quiet, now: { clock.now }, sleep: { clock.sleep($0) })
            #expect(settled == .steady)
            #expect(expected.contains(clock.now.timeIntervalSince(start)), "whole \(whole): \(clock.now.timeIntervalSince(start)) s")
        }
    }

    /// What counts as arriving whole, on fixed times.
    @Test func arrivingWholeIsARenameAScreenshotOrAnOldDate() {
        let seen = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(FileSettle.arrivedWhole(renamed: true, isScreenshot: false, modified: seen, firstSeen: seen), "renamed into place")
        #expect(FileSettle.arrivedWhole(renamed: false, isScreenshot: true, modified: seen, firstSeen: seen), "a screenshot by folder and name")
        #expect(FileSettle.arrivedWhole(renamed: false, isScreenshot: false, modified: seen - 1, firstSeen: seen), "a second old when first seen")
        #expect(!FileSettle.arrivedWhole(renamed: false, isScreenshot: false, modified: seen - 0.3, firstSeen: seen), "written a moment ago")
        #expect(!FileSettle.arrivedWhole(renamed: false, isScreenshot: false, modified: nil, firstSeen: seen))
        let created = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified)
        #expect(!FolderWatcher.isRenamedIntoPlace(created))
        #expect(FolderWatcher.isRenamedIntoPlace(FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemRenamed)))
        #expect(!FolderWatcher.isRenamedIntoPlace(created | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)), "renamed, then written")
        // The screenshot rule: an image named as macOS names them, in its screenshot folder.
        #expect(WatchedFolders.isScreenshot(URL(fileURLWithPath: "/shots/Screenshot 2026-11-20 at 18.00.00.png"), kind: .image, folder: "/shots", screenshots: "/shots"))
        #expect(!WatchedFolders.isScreenshot(URL(fileURLWithPath: "/shots/export.png"), kind: .image, folder: "/shots", screenshots: "/shots"))
        #expect(!WatchedFolders.isScreenshot(URL(fileURLWithPath: "/elsewhere/Screenshot 1.png"), kind: .image, folder: "/elsewhere", screenshots: "/shots"))
    }

    @Test func aFileThatGoesAwayDoesNotSettle() async {
        let temp = TempDir()
        let file = temp.file("a.png")
        try? FileManager.default.removeItem(at: file)
        #expect(await FileSettle.wait(for: file, interval: .milliseconds(20)) == .unsettled)
    }

    @Test func anEmptyFileDoesNotSettle() async {
        let temp = TempDir()
        let file = temp.file("a.png", bytes: 0)
        #expect(await FileSettle.wait(for: file, interval: .milliseconds(20), timeout: .milliseconds(300)) == .unsettled)
    }

    /// W7: a still file L'Esclop may not open says so at once, instead of waiting out the timeout.
    @Test func aFileThatCannotBeOpenedIsUnreadable() async throws {
        let temp = TempDir()
        let file = temp.file("locked.png")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        // Measured against the timeout, not a guess at "at once": under a full run's load the
        // 20 ms checks took up to 14 s on a CI runner.
        let clock = ContinuousClock()
        let started = clock.now
        let timeout = Duration.seconds(60)
        #expect(await FileSettle.wait(for: file, interval: .milliseconds(20), timeout: timeout) == .unreadable)
        #expect(clock.now - started < timeout, "no wait for the timeout")
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
        let harness: Harness
        let folder: URL
        let folders: WatchedFolders
        var store: PipelineStore

        init(pipelines: [Pipeline] = [], delay: Duration = .zero, alsoWatching extra: [String] = []) throws {
            harness = Harness(delay: delay)
            folder = harness.temp.url.appendingPathComponent("Shots", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Only these folders: the defaults would also watch the real Desktop for videos.
            try EsclopSettings.imageDirs.set([folder.path] + extra, in: harness.settings.store)
            for (_, _, list) in WatchPlan.lists where list.key != EsclopSettings.imageDirs.key { try list.set([], in: harness.settings.store) }
            try EsclopSettings.enableAutomaticImageOptimisations.set(true, in: harness.settings.store)
            store = PipelineStore(directory: EsclopLocations(support: harness.temp.url.appendingPathComponent("support", isDirectory: true)).pipelines, useTrash: false)
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            for pipeline in pipelines { _ = try store.save(pipeline) }
            let store = store
            folders = WatchedFolders(model: harness.model, pipelines: { (try? store.list()) ?? [] })
            folders.burstWindow = .milliseconds(300)
            folders.settle = { await FileSettle.wait(for: $0, interval: .milliseconds(100), quiet: $1 ? 0 : FileSettle.quiet) }
            folders.refresh()
        }

        /// A file written in one go, the way screencapture saves a screenshot.
        func land(_ name: String, bytes: Int = 100_000, in other: URL? = nil) -> URL {
            let file = (other ?? folder).appendingPathComponent(name)
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

    /// G5 end to end: the ignore file, a skipped format and the pixel limits leave their files
    /// alone; the file that passes them all is optimised.
    @Test func aFoldersRulesLeaveTheirFilesAlone() async throws {
        let rig = try Rig()
        let rules = FolderRules(folder: rig.folder.path, skipFormats: ["gif"], minPixels: 100)
        // Real PNGs of a few hundred bytes: the size limit would leave them alone first.
        try EsclopSettings.minImageSizeKB.set(0, in: rig.harness.settings.store)
        try EsclopSettings.watchedFolderRules.set([String(decoding: try JSONEncoder().encode(rules), as: UTF8.self)], in: rig.harness.settings.store)
        try "# test\nignored-*\n".write(to: rig.folder.appendingPathComponent(".esclopignore"), atomically: true, encoding: .utf8)
        rig.folders.refresh()
        try pngData(width: 64, height: 64).write(to: rig.folder.appendingPathComponent("tiny.png"), options: .atomic)
        _ = rig.land("ignored-shot.png")
        _ = rig.land("anim.gif")
        try pngData(width: 300, height: 200).write(to: rig.folder.appendingPathComponent("wide.png"), options: .atomic)
        #expect(await eventually { rig.harness.model.recent.count == 1 })
        try await Task.sleep(for: .seconds(2))
        #expect(rig.harness.requests.requests.map { $0.sources.first?.lastPathComponent } == ["wide.png"])
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

    /// W1: a burst in one folder leaves the same kind in another folder alone.
    @Test func aBurstInOneFolderDoesNotSkipAnotherFolder() async throws {
        let other = TempDir()
        let rig = try Rig(alsoWatching: [other.url.path])
        rig.folders.burstWindow = .seconds(1)
        for index in 1 ... 5 { _ = rig.land("unzipped \(index).png") }
        _ = rig.land("Screenshot.png", in: other.url)
        #expect(await eventually { rig.harness.model.recent.count == 1 })
        #expect(rig.harness.model.recent.first?.source.lastPathComponent == "Screenshot.png")
        #expect(rig.harness.model.cards.contains { if case .notice = $0.phase { return true } else { return false } })
        try await Task.sleep(for: .seconds(1))
        #expect(rig.harness.requests.requests.count == 1, "only the other folder's screenshot")
        rig.folders.stop()
    }

    /// W2: a watched folder renamed away is missing at once, and watched again when it is back;
    /// one that did not exist yet is watched as soon as it is created.
    @Test func aRenamedOrNewFolderIsNoticed() async throws {
        let parent = TempDir()
        let later = parent.url.appendingPathComponent("Later", isDirectory: true)
        let rig = try Rig(alsoWatching: [later.path])
        // By path: a folder's URL loses its trailing slash while the folder is not there.
        func status(_ folder: URL) -> FolderStatus? { rig.folders.statuses.first { $0.key.path == WatchPlan.canonical(folder.path).path }?.value }
        #expect(status(rig.folder) == .watching)
        #expect(status(later) == .missing)
        let moved = rig.harness.temp.url.appendingPathComponent("Shots old", isDirectory: true)
        try FileManager.default.moveItem(at: rig.folder, to: moved)
        #expect(await eventually(.seconds(10)) { status(rig.folder) == .missing }, "the rename is seen")
        #expect(rig.harness.model.watchedFolderCount == 0)
        try FileManager.default.moveItem(at: moved, to: rig.folder)
        #expect(await eventually(.seconds(10)) { status(rig.folder) == .watching }, "and the way back")
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        #expect(await eventually(.seconds(10)) { status(later) == .watching })
        _ = rig.land("new.png", in: later)
        #expect(await eventually { rig.harness.model.recent.count == 1 }, "a file in the new folder is optimised")
        rig.folders.stop()
    }

    /// W3: when FSEvents refuses the stream, nothing claims to be watched.
    @Test func aStreamThatCannotStartIsNotWatching() throws {
        let tooLong = "/" + Array(repeating: "x", count: 600).joined(separator: "/")
        let rig = try Rig(alsoWatching: [tooLong])
        #expect(rig.folders.isWatching == false)
        #expect(rig.folders.statuses[WatchPlan.canonical(rig.folder.path)] == .notWatching)
        #expect(rig.harness.model.watchedFolderCount == 0)
        #expect(FolderRow.problem(.notWatching) != nil, "the Settings row says so")
        #expect(FolderWatcher { _, _ in }.start([URL(fileURLWithPath: tooLong)]) == false)
    }

    /// W4: events for a file that is already on its way, while its job runs, start nothing more.
    @Test func aRepeatedEventDuringTheJobRunsOneJob() async throws {
        let rig = try Rig(delay: .seconds(2))
        let file = rig.land("Screenshot.png")
        #expect(await eventually { !rig.harness.model.cards.isEmpty }, "the job started")
        for _ in 0 ..< 3 {
            rig.folders.received([file])
            try await Task.sleep(for: .milliseconds(300))
        }
        #expect(await eventually { rig.harness.model.recent.count == 1 })
        try await Task.sleep(for: .seconds(1))
        #expect(rig.harness.requests.requests.count == 1)
        #expect(rig.folders.inFlight.isEmpty, "released once the job is done")
        rig.folders.stop()
    }

    /// W5: one file still being written does not hold back the others of its burst.
    @Test func aSlowFileDoesNotHoldAFastOne() async throws {
        let rig = try Rig()
        let slow = rig.folder.appendingPathComponent("Download.png")
        FileManager.default.createFile(atPath: slow.path, contents: Data(repeating: 0x41, count: 10000))
        _ = rig.land("Screenshot.png")
        let handle = try FileHandle(forWritingTo: slow)
        var fastDoneWhileSlowGrew = false
        for _ in 0 ..< 40 {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(repeating: 0x41, count: 1000))
            try await Task.sleep(for: .milliseconds(60))
            if rig.harness.model.recent.contains(where: { $0.source.lastPathComponent == "Screenshot.png" }) { fastDoneWhileSlowGrew = true }
        }
        try handle.close()
        #expect(fastDoneWhileSlowGrew)
        #expect(await eventually { rig.harness.model.recent.count == 2 }, "the slow one too, once it stopped")
        rig.folders.stop()
    }

    /// W6: the "too many" notice optimises them after all.
    @Test func tooManyFilesCanBeOptimisedAnyway() async throws {
        let rig = try Rig()
        rig.folders.burstWindow = .seconds(1)
        for index in 1 ... 5 { _ = rig.land("copied \(index).png") }
        #expect(await eventually {
            rig.harness.model.cards.contains { if case .notice = $0.phase { return true } else { return false } }
        })
        let notice = try #require(rig.harness.model.cards.first { if case .notice = $0.phase { return true } else { return false } })
        #expect(notice.presentation.actions == [.optimiseAnyway, .dismiss])
        rig.harness.model.perform(.optimiseAnyway, on: notice)
        #expect(!rig.harness.model.cards.contains { $0.id == notice.id }, "the notice goes")
        #expect(await eventually { rig.harness.requests.requests.count == 5 })
        #expect(rig.harness.requests.requests.allSatisfy { $0.origin == .watchedFolder })
        rig.folders.stop()
    }

    /// Two bursts at once: neither notice takes the other's action away.
    @Test func twoTooLargeBurstsKeepBothActions() async throws {
        let other = TempDir()
        let rig = try Rig(alsoWatching: [other.url.path])
        let landed = (1 ... 5).flatMap { [rig.land("a \($0).png"), rig.land("b \($0).png", in: other.url)] }
        // In one go: under load FSEvents reported part of a burst after the window closed, so
        // neither part was too large.
        rig.folders.received(landed)
        func actions() -> [ResultCard] { rig.harness.model.cards.filter { $0.noticeAction != nil } }
        #expect(await eventually { actions().count == 2 })
        rig.harness.model.notice("Paused", "Press again to resume.")
        #expect(actions().count == 2, "a plain notice leaves them")
        rig.folders.stop()
    }

    /// A batch-sized burst shares one batch window, also in a pipeline's folder (as a drop on a
    /// preset zone does), and bursts that close together share it.
    @Test func burstsShareOneBatchAlsoInAPipelinesFolder() async throws {
        let piped = TempDir()
        let other = TempDir()
        let out = TempDir()
        let pipeline = Pipeline(
            name: "copy out", triggers: [.folder(piped.url.path)],
            sections: [PipelineSection(kind: .image, steps: [.copy(to: out.url.path)])]
        )
        // Jobs hold until cancelled: an instant engine finished the first burst's batch before
        // the second burst opened one.
        let rig = try Rig(pipelines: [pipeline], delay: .seconds(3600), alsoWatching: [other.url.path])
        let piping = (1 ... 4).map { piped.url.appendingPathComponent("p \($0).png") }
        for file in piping { try pngData().write(to: file, options: .atomic) }
        // In one go too: under load FSEvents can split these four as it can the bursts below.
        rig.folders.received(piping)
        #expect(await eventually { (try? FileManager.default.contentsOfDirectory(atPath: out.url.path).count) == 4 })
        #expect(rig.harness.model.batch?.rows.count == 4, "a pipeline burst shares one batch")
        #expect(rig.harness.model.cards.isEmpty)
        #expect(await eventually { rig.harness.model.batch?.isRunning == false })
        let landed = (1 ... 4).flatMap { [rig.land("a \($0).png"), rig.land("b \($0).png", in: other.url)] }
        // Handed over in one go, before the stream reports them: FSEvents can report part of a
        // burst 0.3 s later, as late as the test's burst window.
        rig.folders.received(landed)
        #expect(await eventually { rig.harness.model.batch?.rows.count == 8 }, "two bursts at once, one batch")
        rig.harness.model.batch?.cancelAll()
        rig.folders.stop()
    }

    /// "Show floating results" off: a batch-sized burst goes to Recent only, with no batch window.
    @Test func aBurstOpensNoBatchWithFloatingResultsOff() async throws {
        let rig = try Rig()
        try EsclopSettings.showFloatingResults.set(false, in: rig.harness.settings.store)
        let landed = (1 ... rig.harness.model.batchThreshold).map { rig.land("q \($0).png") }
        rig.folders.received(landed)
        #expect(await eventually { rig.harness.model.recent.count == landed.count })
        #expect(rig.harness.model.batch == nil && rig.harness.model.cards.isEmpty)
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

/// P4: watching does not read inside a folder until a file lands, and a refusal is final until
/// the lists change.
@MainActor @Suite(.serialized) struct WatchedFoldersAccessTests {
    @Test func startingToWatchDoesNotReadInsideTheFolder() throws {
        let rig = try WatchedFoldersTests.Rig()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rig.folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.folder.path) }
        rig.folders.refresh()
        #expect(rig.folders.statuses[WatchPlan.canonical(rig.folder.path)] == .watching, "only the folder itself is looked at")
        #expect(FolderStatus.check(rig.folder) == .unreadable, "the Settings row still finds out")
        rig.folders.stop()
    }

    @Test func aRefusalTakesTheFolderOutQuietly() async throws {
        let rig = try WatchedFoldersTests.Rig()
        // Landed while the folder's own stream is off. FSEvents still reports a write to a stream
        // that starts before it has handled that write, so a witness stream waits until it has;
        // after that the folder is unreadable, the stream skips a path it cannot see, and only
        // the calls below hand the file over.
        rig.folders.stop()
        let seen = Flag()
        let witness = FolderWatcher { files, _ in
            if files.contains(where: { $0.lastPathComponent == "shot.png" }) { seen.set() }
        }
        witness.start([rig.folder])
        let file = rig.land("shot.png")
        #expect(await eventually { seen.isSet })
        witness.stop()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rig.folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.folder.path) }
        rig.folders.refresh()
        rig.folders.received([file])
        let folder = WatchPlan.canonical(rig.folder.path)
        #expect(rig.folders.denied == [folder])
        #expect(rig.folders.statuses[folder] == .unreadable)
        #expect(rig.harness.model.watchedFolderCount == 0)
        #expect(!rig.harness.model.cards.contains { if case .notice = $0.phase { return true } else { return false } }, "no notice")
        rig.folders.received([file])
        rig.folders.refresh()
        #expect(rig.folders.statuses[folder] == .unreadable, "no new attempt on a plain refresh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.folder.path)
        rig.folders.refresh(retryDenied: true)
        #expect(rig.folders.statuses[folder] == .watching, "the lists changed: it is tried again")
        // Watched again: a new file goes on, the refused one does not come back with it.
        let next = rig.land("next.png")
        #expect(await eventually { !rig.harness.requests.requests.isEmpty })
        #expect(rig.harness.requests.requests.flatMap(\.sources).map(\.lastPathComponent) == [next.lastPathComponent])
        rig.folders.stop()
    }

    @Test func permissionErrorsAreRecognised() {
        #expect(WatchedFolders.isDenied(CocoaError(.fileReadNoPermission)))
        #expect(WatchedFolders.isDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        #expect(WatchedFolders.isDenied(NSError(domain: NSCocoaErrorDomain, code: 260, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])))
        #expect(!WatchedFolders.isDenied(CocoaError(.fileReadNoSuchFile)))
    }
}
