// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

/// A tool L'Esclop started dies with it, even when L'Esclop is killed (a crash, a force quit).
@Suite struct ChildProcessTests {
    @Test(.timeLimit(.minutes(1))) func aKilledParentTakesItsToolWithIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("esclop-orphan-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let bin = folder.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A probe that never answers and leaves its pid behind.
        let pidFile = folder.appendingPathComponent("pid")
        let tool = bin.appendingPathComponent("ffprobe")
        try "#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec sleep 60\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let video = folder.appendingPathComponent("clip.mov")
        try Data("not really a video".utf8).write(to: video)

        let parent = Process()
        parent.executableURL = try esclopBinary()
        parent.arguments = ["optimise", "--behaviour", "temp", "--no-progress", "--no-gui", video.path]
        parent.environment = ProcessInfo.processInfo.environment.merging(["ESCLOP_BIN": bin.path]) { $1 }
        parent.standardOutput = FileHandle.nullDevice
        parent.standardError = FileHandle.nullDevice
        try parent.run()

        var child: Int32?
        for _ in 0 ..< 100 where child == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
            child = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let pid = try #require(child)
        kill(parent.processIdentifier, SIGKILL)
        parent.waitUntilExit()

        var alive = true
        for _ in 0 ..< 50 where alive {
            try await Task.sleep(nanoseconds: 100_000_000)
            alive = kill(pid, 0) == 0
        }
        if alive { kill(pid, SIGKILL) }
        #expect(!alive, "the tool outlived the killed parent")
    }
}
