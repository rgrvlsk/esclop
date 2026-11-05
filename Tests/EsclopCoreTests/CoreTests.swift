// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import EsclopCore

func scratchFolder(_ name: String = #function) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("esclop-tests", isDirectory: true)
        .appendingPathComponent("\(name.filter(\.isLetter))-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct ToolLocatorTests {
    @Test func esclopBinComesFirst() throws {
        let folder = try scratchFolder()
        let fake = folder.appendingPathComponent("gifsicle")
        try "#!/bin/sh\necho fake\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let locator = ToolLocator(environment: ["ESCLOP_BIN": folder.path, "PATH": "/usr/bin:/bin"])
        #expect(locator.locate(.gifsicle) == fake)
        #expect(locator.searchDirectories.first == folder)
    }

    @Test func installedCommandLineFindsItsLibexec() throws {
        let prefix = try scratchFolder()
        let bin = prefix.appendingPathComponent("bin", isDirectory: true)
        let elsewhere = prefix.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("esclop")
        try Data().write(to: executable)
        let link = elsewhere.appendingPathComponent("esclop")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        let expected = prefix.appendingPathComponent("libexec/esclop", isDirectory: true).resolvingSymlinksInPath().path
        #expect(ToolLocator.libexecDirectory(forExecutable: executable).path == expected)
        #expect(ToolLocator.libexecDirectory(forExecutable: link).path == expected)
    }

    @Test func missingToolsSayWhich() {
        let locator = ToolLocator(searchDirectories: [], pathDirectories: [])
        #expect(throws: EsclopError.toolMissing("ffmpeg")) { try locator.url(for: .ffmpeg) }
        #expect(throws: EsclopError.toolMissing("esclop-engine")) { try locator.url(for: .esclopEngine) }
    }

    @Test func toolSetIsTheBundledOne() {
        #expect(Set(Tool.allCases.map(\.rawValue)) == ["esclop-engine", "ffmpeg", "ffprobe", "gs", "gifsicle"])
    }
}

@Suite struct ProcessRunnerTests {
    @Test func capturesOutputAndLines() async throws {
        let lines = LockedArray()
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf 'a=1\\nb=2\\n'; echo oops >&2"],
            options: ProcessOptions(onStdoutLine: { lines.append($0) })
        )
        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "a=1\nb=2\n")
        #expect(result.stderrString.contains("oops"))
        #expect(lines.values == ["a=1", "b=2"])
    }

    @Test func failureCarriesStderr() async throws {
        await #expect(throws: EsclopError.toolFailed(tool: "sh", exitCode: 3, stderr: "broken")) {
            try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo broken >&2; exit 3"])
        }
    }

    @Test func acceptedExitCodes() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 99"],
            options: ProcessOptions(acceptedExitCodes: [0, 99])
        )
        #expect(result.exitCode == 99)
    }

    @Test func feedsStdin() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], options: ProcessOptions(stdin: Data("hello".utf8))
        )
        #expect(result.stdoutString == "hello")
    }

    // The child would run for a minute; the call must end long before that. The bounds are wide
    // because the caller resumes on the cooperative pool, which a loaded CI runner keeps busy.
    @Test(.timeLimit(.minutes(2))) func timesOut() async throws {
        let started = Date()
        do {
            try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"], options: ProcessOptions(timeout: 0.5))
            Issue.record("should have timed out")
        } catch let EsclopError.toolFailed(_, _, stderr) {
            #expect(stderr.contains("timed out after 0.5 s"))
        }
        #expect(Date().timeIntervalSince(started) < 20)
    }

    @Test(.timeLimit(.minutes(2))) func cancellingTheTaskKillsTheChild() async throws {
        let started = Date()
        let task = Task {
            try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"])
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        await #expect(throws: EsclopError.cancelled) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 20)
    }

    /// Twenty timeouts, cancellations and quick runs at once, next to a long-lived child (a slow
    /// compile in CI), must all finish in bounded time: none of them may wait for another.
    @Test(.timeLimit(.minutes(1))) func concurrentTimeoutsAndCancelsDoNotWaitForEachOther() async throws {
        let sleep = URL(fileURLWithPath: "/bin/sleep")
        let slow = Task { try await ProcessRunner.run(executable: sleep, arguments: ["20"]) }
        defer { slow.cancel() }
        try await Task.sleep(nanoseconds: 100_000_000)
        let started = Date()
        try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0 ..< 20 {
                group.addTask {
                    switch index % 3 {
                    case 0:
                        do {
                            try await ProcessRunner.run(executable: sleep, arguments: ["30"], options: ProcessOptions(timeout: 0.5))
                            return "timeout \(index): finished instead of timing out"
                        } catch let EsclopError.toolFailed(_, _, stderr) where stderr.contains("timed out") {
                            return "ok"
                        }
                    case 1:
                        let task = Task { try await ProcessRunner.run(executable: sleep, arguments: ["30"]) }
                        try await Task.sleep(nanoseconds: 200_000_000)
                        task.cancel()
                        do {
                            _ = try await task.value
                            return "cancel \(index): finished instead of cancelling"
                        } catch EsclopError.cancelled {
                            return "ok"
                        }
                    default:
                        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo \(index)"])
                        return result.stdoutString == "\(index)\n" ? "ok" : "echo \(index): \(result.stdoutString)"
                    }
                }
            }
            for try await outcome in group {
                #expect(outcome == "ok")
            }
        }
        // Each child is killed within about half a second; leave a wide margin for loaded CI.
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 15, "20 concurrent runs took \(elapsed) s")
    }

    /// A child that leaves a descendant behind (the way `xcrun` can) keeps its stdout open after
    /// it exits. The call must still end soon after the child does, and a timeout must still be one.
    @Test(.timeLimit(.minutes(1))) func descendantsHoldingThePipesDoNotHangTheCall() async throws {
        let sh = URL(fileURLWithPath: "/bin/sh")
        var started = Date()
        let result = try await ProcessRunner.run(executable: sh, arguments: ["-c", "sleep 30 & echo hi"])
        #expect(result.stdoutString == "hi\n")
        #expect(Date().timeIntervalSince(started) < 10)

        started = Date()
        do {
            try await ProcessRunner.run(executable: sh, arguments: ["-c", "sleep 30 & sleep 30"], options: ProcessOptions(timeout: 0.5))
            Issue.record("should have timed out")
        } catch let EsclopError.toolFailed(_, _, stderr) {
            #expect(stderr.contains("timed out"))
        }
        #expect(Date().timeIntervalSince(started) < 10)

        started = Date()
        let task = Task { try await ProcessRunner.run(executable: sh, arguments: ["-c", "sleep 30 & sleep 30"]) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        await #expect(throws: EsclopError.cancelled) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    /// CI's three cooperative threads were busy with CPU-bound tests; anything queued on
    /// `DispatchQueue.global()` (a timeout, a completion) waited until they finished. A timeout
    /// has to fire on time while the pool is busy, not after the child has already exited.
    /// The pool is kept busy for under a second: every test in the process shares it.
    @Test(.timeLimit(.minutes(1))) func timeoutsFireWhileTheCooperativePoolIsBusy() async throws {
        let run = Task {
            try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["0.5"], options: ProcessOptions(timeout: 0.1))
        }
        try await Task.sleep(nanoseconds: 30_000_000) // launched, timeout armed
        let spinUntil = Date().addingTimeInterval(0.8)
        let spinners = (0 ..< ProcessInfo.processInfo.activeProcessorCount).map { _ in
            Task.detached { while Date() < spinUntil {} }
        }
        defer { spinners.forEach { $0.cancel() } }
        do {
            _ = try await run.value
            Issue.record("the 0.1 s timeout fired only after the 0.5 s child had finished")
        } catch let EsclopError.toolFailed(_, _, stderr) {
            #expect(stderr.contains("timed out"))
        }
    }

    /// The structural half of the test above, which cannot saturate the pool for long: nothing
    /// in the runner may schedule on the global queues.
    @Test func runnerNeverSchedulesOnTheGlobalQueue() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/EsclopCore/ProcessRunner.swift").standardizedFileURL
        let code = try String(contentsOf: source, encoding: .utf8)
            .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let offending = code.filter { $0.contains("DispatchQueue.global") }
        #expect(offending.isEmpty, "\(offending)")
    }

    @Test func setsEsclopBin() async throws {
        let folder = try scratchFolder()
        let locator = ToolLocator(searchDirectories: [folder])
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf %s \"$ESCLOP_BIN\""], locator: locator
        )
        #expect(result.stdoutString == folder.path)
    }

    @Test func longRunningChildStreamsLines() async throws {
        let child = try ProcessRunner.launch(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [])
        try child.send("one")
        try child.send("two")
        var received: [String] = []
        for await line in child.lines {
            received.append(line)
            if received.count == 2 { break }
        }
        #expect(received == ["one", "two"])
        child.stop(grace: 0.1)
    }
}

final class LockedArray: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

@Suite struct BackupTests {
    @Test func backUpRestoreAndPrune() throws {
        let folder = try scratchFolder()
        let store = BackupStore(root: folder.appendingPathComponent("backups"))
        let original = folder.appendingPathComponent("photo.png")
        try Data("original".utf8).write(to: original)

        let entry = try store.backUp(original, requestID: UUID())
        #expect(FileManager.default.fileExists(atPath: entry.backup.path))
        #expect(FileManager.default.fileExists(atPath: entry.backup.deletingLastPathComponent().appendingPathComponent("manifest.json").path))
        #expect(store.entries().map(\.id) == [entry.id])
        #expect(store.entry(forBackup: entry.backup)?.id == entry.id)
        #expect(entry.bytes == 8)

        // Converted output replaced the original; restore brings the PNG back and removes the JPEG.
        let output = folder.appendingPathComponent("photo.jpeg")
        try Data("optimised".utf8).write(to: output)
        try FileManager.default.removeItem(at: original)
        let updated = try store.setOutput(output, for: entry)
        #expect(store.latest(for: output)?.id == entry.id)
        try store.restore(updated)
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
        #expect(!FileManager.default.fileExists(atPath: output.path))

        #expect(store.prune(olderThan: 7) == 0)
        #expect(store.prune(olderThan: 1, now: Date().addingTimeInterval(3 * 86400)) == 1)
        #expect(store.entries().isEmpty)
    }

    @Test func optimisedMark() throws {
        let file = try scratchFolder().appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)
        #expect(!OptimisedMark.isMarked(file))
        try OptimisedMark.set(file, note: "1")
        #expect(OptimisedMark.isMarked(file))
        #expect(OptimisedMark.value(file) == "1")
        #expect(Xattr.names(at: file).contains(OptimisedMark.name))
        OptimisedMark.clear(file)
        #expect(!OptimisedMark.isMarked(file))
    }
}

@Suite struct OutputLocationTests {
    let source = URL(fileURLWithPath: "/Volumes/Media/Pictures/shot.png")

    @Test func inPlaceKeepsTheFolder() {
        #expect(OutputLocation.inPlace.destination(for: source, extension: "png").path == "/Volumes/Media/Pictures/shot.png")
        #expect(OutputLocation.inPlace.destination(for: source, extension: "jpeg").path == "/Volumes/Media/Pictures/shot.jpeg")
    }

    @Test func sameFolderNeverOverwrites() throws {
        let folder = try scratchFolder()
        let file = folder.appendingPathComponent("shot.png")
        try Data().write(to: file)
        let first = OutputLocation.sameFolder.destination(for: file, extension: "png")
        #expect(first.lastPathComponent == "shot-optimised.png")
        try Data().write(to: first)
        #expect(OutputLocation.sameFolder.destination(for: file, extension: "png").lastPathComponent == "shot-optimised 2.png")
        // "%f" with a new extension is just the new extension.
        #expect(OutputLocation.sameFolder.destination(for: file, extension: "webp", sameFolderTemplate: "%f").lastPathComponent == "shot.webp")
        #expect(OutputLocation.sameFolder.destination(for: file, extension: "png", sameFolderTemplate: "%f").lastPathComponent == "shot-optimised 2.png")
    }

    @Test func templates() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(OutputLocation.path("~/out/%f.%e").destination(for: source, extension: "webp").path == "\(home)/out/shot.webp")
        #expect(OutputLocation.path("~/out/").destination(for: source, extension: "webp").path == "\(home)/out/shot.webp")
        #expect(OutputLocation.path("%d/small/%f-1").destination(for: source, extension: "png").path == "/Volumes/Media/Pictures/small/shot-1.png")
        #expect(OutputLocation.path("converted/%f").destination(for: source, extension: "jpeg").path == "/Volumes/Media/Pictures/converted/shot.jpeg")
        let temp = OutputLocation.temporary.destination(for: source, extension: "png", temporaryRoot: URL(fileURLWithPath: "/tmp/esclop"))
        #expect(temp.path.hasPrefix("/tmp/esclop/results/"))
        #expect(temp.lastPathComponent == "shot.png")
    }

    @Test func cropSizes() {
        #expect(CropSize(aspectRatio: "16:9").aspectRatioValue == 16.0 / 9.0)
        #expect(CropSize(aspectRatio: "1.5").aspectRatioValue == 1.5)
        #expect(CropSize(aspectRatio: "bad").aspectRatioValue == nil)
        // Aspect crops keep as much as fits.
        #expect(CropSize(aspectRatio: "1:1").targetSize(fromWidth: 400, height: 300) == (300, 300))
        #expect(CropSize(longEdge: 160, aspectRatio: "16:9").targetSize(fromWidth: 1920, height: 1440) == (160, 90))
        #expect(CropSize(longEdge: 200).targetSize(fromWidth: 400, height: 300) == (200, 150))
        #expect(CropSize(longEdge: 800).targetSize(fromWidth: 400, height: 300) == (400, 300))
        #expect(CropSize(width: 100).targetSize(fromWidth: 400, height: 300) == (100, 75))
        #expect(CropSize(width: 100, height: 100).targetSize(fromWidth: 400, height: 300) == (100, 100))
        #expect(CropSize(width: 100, height: 100).cropsAspect(fromWidth: 400, height: 300))
        #expect(!CropSize(width: 200).cropsAspect(fromWidth: 400, height: 300))
    }
}
