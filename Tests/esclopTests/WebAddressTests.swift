// SPDX-License-Identifier: GPL-3.0-or-later

import EsclopCore
import EsclopIPC
@testable import esclop
import Foundation
import Network
import Testing

/// One HTTP answer on 127.0.0.1, for every request: enough to download from without the network.
final class LocalServer: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16

    init(status: Int = 200, contentType: String, body: Data) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let head = "HTTP/1.1 \(status) Answer\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
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
