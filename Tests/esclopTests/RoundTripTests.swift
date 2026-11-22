// SPDX-License-Identifier: GPL-3.0-or-later
//
// optimise -> recent -> restore through the real binary, with ESCLOP_SUPPORT_DIR set: the backup
// lands in that folder, not in the person's Application Support. Two files in one job are two
// results: each lists, and restoring one leaves the other. A HEIC goes through ImageIO, so no
// bundled tool is needed.

import CoreGraphics
import EsclopCore
@testable import esclop
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite struct CLIRoundTrip {
    @Test func optimiseRecentRestore() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("esclop-roundtrip-\(UUID().uuidString)", isDirectory: true)
        let support = folder.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("photo.heic"), other = folder.appendingPathComponent("other.heic")
        try Self.heic(photo)
        try Self.heic(other)
        let original = try Data(contentsOf: photo)

        func run(_ arguments: [String]) async throws -> (status: Int32, output: String) {
            let result = try await runEsclop(arguments, environment: ["ESCLOP_SUPPORT_DIR": support.path])
            return (result.exitCode, result.output)
        }

        let optimised = try await run(["optimise", "--no-color", "-n", photo.path, other.path])
        #expect(optimised.status == 0, "\(optimised.output)")
        #expect(try Data(contentsOf: photo) != original)

        struct Row: Decodable { var id: String; var source: String; var backup: String?; var origin: String? }
        func recent() async throws -> [Row] {
            let recent = try await run(["recent", "--json", "--limit", "5"])
            #expect(recent.status == 0, "\(recent.output)")
            return try JSONDecoder().decode([Row].self, from: Data(recent.output.utf8))
        }
        let rows = try await recent()
        #expect(Set(rows.map { URL(fileURLWithPath: $0.source).lastPathComponent }) == ["photo.heic", "other.heic"])
        #expect(Set(rows.map(\.id)).count == 2)
        #expect(rows.allSatisfy { $0.origin == "cli" }, "recent says where each came from")
        #expect(try await run(["recent", "--no-color"]).output.contains("  cli"))
        let backup = try #require(rows.first { $0.source.hasSuffix("/photo.heic") }?.backup)
        #expect(URL(fileURLWithPath: backup).resolvingSymlinksInPath().path.hasPrefix(support.resolvingSymlinksInPath().path + "/"))

        let restored = try await run(["restore", "--no-color", photo.path])
        #expect(restored.status == 0, "\(restored.output)")
        #expect(try Data(contentsOf: photo) == original)
        #expect(try await recent().map { URL(fileURLWithPath: $0.source).lastPathComponent } == ["other.heic"], "the other file's result stays")
    }

    /// A pipeline step that cannot run in the CLI is a `note:` line on stderr, not silence.
    @Test func aSkippedStepIsNoted() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("esclop-skipped-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let support = folder.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("photo.heic")
        try Self.heic(photo)
        let run = try await runEsclop(["pipeline", "run", "copyLinkForSending -> shelveWith(app: yoink)", "--no-color", "-n", photo.path], environment: ["ESCLOP_SUPPORT_DIR": support.path])
        #expect(run.exitCode == 0, "\(run.output)")
        #expect(run.stderrString == """
        note: copyLinkForSending skipped: not available yet (planned for 0.3)
        note: shelveWith(app: yoink) skipped: needs the L'Esclop app

        """)
        #expect(Output.skippedNote("crop(longEdge: 100): done") == nil)
        #expect(Output.skippedNote("open(app: Preview): skipped") == "open(app: Preview) skipped")
    }

    /// `settings import` skips the permissions a file turns on (agents', uploads') and names them;
    /// `--allow-permissions` applies them. Its own settings suite, never the person's.
    @Test func importSkipsPermissionsUnlessAllowed() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("esclop-import-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let support = folder.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let environment = ["ESCLOP_SUPPORT_DIR": support.path]
        let suite = Paths.defaultsSuite(environment: environment)
        defer {
            try? FileManager.default.removeItem(at: folder)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let file = folder.appendingPathComponent("shared.json")
        try Data(#"{"format": "esclop-settings", "version": 1, "settings": {"batchWindowFrom": 6, "allowRunScripts": true, "uploadAutomatically": ["clipboard"]}}"#.utf8).write(to: file)

        let skipped = try await runEsclop(["settings", "import", file.path], environment: environment)
        #expect(skipped.exitCode == 0, "\(skipped.output)")
        #expect(skipped.stdoutString == "Changed batchWindowFrom.\n", "each changed key, not a count")
        #expect(skipped.stderrString == "note: skipped permissions the file turns on: allowRunScripts, uploadAutomatically (--allow-permissions turns them on)\n")

        struct Imported: Decodable { var imported: [String]; var permissionsTurnedOn: [String] }
        let allowed = try await runEsclop(["settings", "import", "--allow-permissions", "--json", file.path], environment: environment)
        let read = try JSONDecoder().decode(Imported.self, from: Data(allowed.stdoutString.utf8))
        #expect(read.imported == ["allowRunScripts", "batchWindowFrom", "uploadAutomatically"], "\(allowed.output)")
        #expect(read.permissionsTurnedOn == ["allowRunScripts", "uploadAutomatically"])
    }

    /// V1: a link whose target has no extension is refused in one sentence and writes nothing
    /// beside the target; a link to a file of the same kind under another name optimises that file.
    @Test func aLinkIsOptimisedOnlyAsAFileOfItsKind() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("esclop-links-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let support = folder.appendingPathComponent("support", isDirectory: true)
        let store = folder.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.heic(store.appendingPathComponent("abc123"))
        try Self.heic(store.appendingPathComponent("picture.HEIC"))
        let unnamed = folder.appendingPathComponent("photo.heic"), named = folder.appendingPathComponent("named.heic")
        try FileManager.default.createSymbolicLink(atPath: unnamed.path, withDestinationPath: "store/abc123")
        try FileManager.default.createSymbolicLink(atPath: named.path, withDestinationPath: "store/picture.HEIC")
        let before = try Data(contentsOf: store.appendingPathComponent("abc123"))

        let refused = try await runEsclop(["optimise", "--no-color", unnamed.path], environment: ["ESCLOP_SUPPORT_DIR": support.path])
        #expect(refused.exitCode == 1, "\(refused.output)")
        #expect(refused.stdoutString == "✗ photo.heic A link to a file L’Esclop cannot name: optimise the file itself.\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.path).sorted() == ["abc123", "picture.HEIC"], "no file beside the target")
        #expect(try Data(contentsOf: store.appendingPathComponent("abc123")) == before)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: unnamed.path) == "store/abc123")

        let done = try await runEsclop(["optimise", "--no-color", named.path], environment: ["ESCLOP_SUPPORT_DIR": support.path])
        #expect(done.exitCode == 0, "\(done.output)")
        #expect(done.stdoutString.hasPrefix("✓ picture.HEIC"), "\(done.output)")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: named.path) == "store/picture.HEIC", "the link keeps pointing at it")
    }

    /// V8: a pipeline whose `optimise` saves nothing reports "unchanged", as `optimise` does, and
    /// adds no row to the recent results.
    @Test func aPipelineThatChangesNothingIsUnchanged() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("esclop-unchanged-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let support = folder.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("photo.heic")
        try Self.heic(photo)
        let environment = ["ESCLOP_SUPPORT_DIR": support.path]
        let first = try await runEsclop(["pipeline", "run", "optimise", "--no-color", photo.path], environment: environment)
        #expect(first.exitCode == 0 && first.stdoutString.hasPrefix("✓ photo.heic"), "\(first.output)")
        let again = try await runEsclop(["pipeline", "run", "optimise", "--no-color", photo.path], environment: environment)
        #expect(again.exitCode == 0, "\(again.output)")
        #expect(again.stdoutString.hasPrefix("– photo.heic unchanged"), "\(again.output)")
        let recent = try await runEsclop(["recent", "--json"], environment: environment)
        struct Row: Decodable { var source: String }
        #expect(try JSONDecoder().decode([Row].self, from: Data(recent.stdoutString.utf8)).count == 1, "\(recent.output)")
    }

    static func heic(_ url: URL) throws {
        let width = 480, height = 360
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw TestFailure("context") }
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                let noise = CGFloat((x * 7919 + y * 104_729) % 97) / 97
                context.setFillColor(red: CGFloat(x) / CGFloat(width), green: noise, blue: CGFloat(y) / CGFloat(height), alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 4, height: 4))
            }
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil)
        else { throw TestFailure("heic destination") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw TestFailure("heic write") }
    }
}
