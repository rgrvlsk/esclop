// SPDX-License-Identifier: GPL-3.0-or-later

import EsclopCore
import EsclopIPC
@testable import esclop
import Foundation
import Network
import Testing

/// One HTTP answer on 127.0.0.1, for every request: enough to download from without the network.
/// Without `announcesLength` the body has no Content-Length and ends when the connection closes;
/// with `holdsOpen` it never closes, like a stream.
final class LocalServer: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16

    init(status: Int = 200, contentType: String, body: Data, announcesLength: Bool = true, holdsOpen: Bool = false) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let length = announcesLength ? "Content-Length: \(body.count)\r\n" : ""
                let head = "HTTP/1.1 \(status) Answer\r\nContent-Type: \(contentType)\r\n\(length)Connection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in if !holdsOpen { connection.cancel() } })
            }
        }
        port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
    }

    func stop() { listener.cancel() }
}

@Suite struct WebAddressTests {
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 7, count: 64)

    /// `esclop optimise http://…` downloads into the temporary folder and works on that file; the
    /// content type gives a name without an extension one.
    @Test func aWebAddressIsDownloadedFirst() async throws {
        let server = try await LocalServer(contentType: "image/png", body: Self.png)
        defer { server.stop() }
        let command: Optimise = try parse(["optimise", "http://127.0.0.1:\(server.port)/pixel?w=800"])
        let sources = try await command.files.inputs.sources()
        let file = try #require(sources.first)
        #expect(sources.count == 1)
        #expect(file.pathExtension == "png")
        #expect(file.resolvingSymlinksInPath().path.hasPrefix(WebDownload.folder.resolvingSymlinksInPath().path + "/"))
        #expect(try Data(contentsOf: file) == Self.png)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func aRefusedDownloadSaysSoAndSkipErrorsSkipsIt() async throws {
        let server = try await LocalServer(status: 404, contentType: "text/html", body: Data("gone".utf8))
        defer { server.stop() }
        let address = "http://127.0.0.1:\(server.port)/gone.png"
        await #expect(throws: EsclopError.other("\(address) answered 404")) {
            try await (try parse(["optimise", address]) as Optimise).files.inputs.sources()
        }
        #expect(try await (try parse(["optimise", address, "--skip-errors"]) as Optimise).files.inputs.sources().isEmpty)
    }

    /// A download stops at `largest` bytes, whether the server announces more or just keeps
    /// sending, and an answer that is not media (a web page) is refused.
    @Test func aDownloadTooLargeOrNotMediaIsRefused() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("esclop-downloads-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A stream never ends: only stopping it as the bytes come in returns at all.
        for (announces, stream) in [(true, false), (false, false), (false, true)] {
            let server = try await LocalServer(contentType: "image/png", body: Self.png + Data(count: 4096), announcesLength: announces, holdsOpen: stream)
            defer { server.stop() }
            let address = URL(string: "http://127.0.0.1:\(server.port)/big.png")!
            await #expect(throws: EsclopError.other("\(address.absoluteString) is larger than 1.0 KB, the most L'Esclop downloads"), "announced: \(announces), stream: \(stream)") {
                try await WebDownload.fetch(address, into: folder, largest: 1000)
            }
        }
        let page = try await LocalServer(contentType: "text/html", body: Data("<html></html>".utf8))
        defer { page.stop() }
        let address = URL(string: "http://127.0.0.1:\(page.port)/gallery")!
        await #expect(throws: EsclopError.other("\(address.absoluteString) is not an image, video, PDF or audio file (text/html)")) {
            try await WebDownload.fetch(address, into: folder)
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty ?? true, "nothing is kept")
        #expect(WebDownload.isInsecure(URL(string: "http://example.com/a.png")!))
        #expect(!WebDownload.isInsecure(URL(string: "http://localhost:8080/a.png")!))
        #expect(!WebDownload.isInsecure(URL(string: "https://example.com/a.png")!))
    }

    /// `esclop optimise <address>` writes the result into the working directory, under a name
    /// nothing there has, and prints where it is; with -o or --behaviour temp it goes there.
    @Test func aDownloadedResultLandsInTheWorkingDirectory() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("esclop-cwd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let support = folder.appendingPathComponent(".support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("served.heic")
        try CLIRoundTrip.heic(photo)
        let server = try await LocalServer(contentType: "image/heic", body: try Data(contentsOf: photo))
        defer { server.stop() }
        try FileManager.default.removeItem(at: photo)
        try Data("mine".utf8).write(to: folder.appendingPathComponent("photo.heic"))
        let address = "http://127.0.0.1:\(server.port)/photo.heic"

        let process = Process()
        process.executableURL = try esclopBinary()
        process.arguments = ["optimise", "--no-color", "-n", address]
        process.currentDirectoryURL = folder
        process.environment = ProcessInfo.processInfo.environment.merging(["ESCLOP_NO_APP": "1", "ESCLOP_SUPPORT_DIR": support.path]) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(output)")
        let result = folder.appendingPathComponent("photo 2.heic")
        #expect(FileManager.default.fileExists(atPath: result.path), "\(output)")
        #expect(output.contains("/photo 2.heic"), "the line names the path: \(output)")
        #expect(try Data(contentsOf: folder.appendingPathComponent("photo.heic")) == Data("mine".utf8), "a file there is left alone")

        #expect(try (parse(["optimise", address]) as Optimise).files.downloadFolder != nil)
        #expect(try (parse(["optimise", address, "--behaviour", "samefolder"]) as Optimise).files.downloadFolder != nil)
        #expect(try (parse(["optimise", address, "--behaviour", "temp"]) as Optimise).files.downloadFolder == nil)
        #expect(try (parse(["optimise", address, "-o", "/tmp/"]) as Optimise).files.downloadFolder == nil)
    }

    /// Only http and https are downloaded; another scheme is refused rather than read as a path.
    @Test func otherSchemesAreRefused() async throws {
        for address in ["ftp://example.com/a.png", "smb://server/share/b.png"] {
            await #expect(throws: EsclopError.self) { try await (try parse(["optimise", address]) as Optimise).files.inputs.sources() }
        }
        #expect(try WebDownload.address("a:b.png") == nil, "a colon alone is a file name")
        #expect(try WebDownload.address("file:///tmp/a.png") == nil)
        #expect(try WebDownload.address("HTTPS://example.com/a.png") != nil)
    }
}
