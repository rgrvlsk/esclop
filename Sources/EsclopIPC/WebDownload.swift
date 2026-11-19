// SPDX-License-Identifier: GPL-3.0-or-later
//
// A web address the person asked for (`esclop optimise https://…`, an image dropped from a
// browser) is downloaded into L'Esclop's temporary folder and optimised there as a local file.
// Only on such a request: PRODUCT.md allows network operations only when the person asks.

import EsclopCore
import Foundation
import UniformTypeIdentifiers

public enum WebDownload {
    /// Where downloads go, one folder each so names never clash. The app's launch sweep
    /// (`BackupPruner.pruneAtLaunch`) removes old ones.
    public static var folder: URL { Paths.temporary.appendingPathComponent("downloads", isDirectory: true) }

    /// The largest download, by the size the server announces and by the bytes received.
    // ponytail: one cap for every kind, so a link to a stream or a 10 GB file cannot fill
    // $TMPDIR. A screen recording above it is refused; raise it, or cap per kind, if people hit it.
    public static let largest = 2_000_000_000
    /// The whole download, from the request to the last byte.
    // ponytail: an hour takes the whole cap at about 4.5 Mbit/s; a slower line fails a large
    // video. Use an idle timeout with the cap alone if people on slow lines hit it.
    public static let timeLimit: TimeInterval = 60 * 60

    /// The session downloads use: `timeLimit` for the whole transfer.
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = timeLimit
        return URLSession(configuration: configuration)
    }()

    /// Plain http to another machine: what arrives may have been changed on the way.
    public static func isInsecure(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host()?.lowercased() else { return false }
        return !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) && !host.hasSuffix(".localhost")
    }

    /// The address in `raw` when it is a web one (http or https), nil for a path or a `file:` URL.
    /// Any other scheme (`ftp://`, `smb://` …) is refused rather than read as a relative path.
    public static func address(_ raw: String) throws -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil, let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            guard url.host() != nil else { throw EsclopError.invalidArgument("\(raw) has no host") }
            return url
        case "file":
            return nil
        default:
            // A colon alone is a file name ("a:b.png"); a scheme followed by "//" is an address.
            guard text.dropFirst(scheme.count + 1).hasPrefix("//") else { return nil }
            throw EsclopError.invalidArgument("\(raw): only http and https addresses can be downloaded")
        }
    }

    /// Downloads `url` into a new folder under `folder` and returns the file. The name comes from
    /// the server or the address; the extension from the content type when the name has none
    /// that L'Esclop knows, so `…/photo?w=800` served as JPEG becomes `photo.jpg`. Refused, and
    /// stopped as soon as it shows: more than `largest` bytes, and an answer that is not an image,
    /// video, PDF or audio file (a web page, say).
    public static func fetch(
        _ url: URL, into folder: URL = WebDownload.folder, session: URLSession = WebDownload.session, largest: Int = WebDownload.largest
    ) async throws -> URL {
        let limits = Limits(url: url, largest: largest)
        let temporary: URL, response: URLResponse
        do {
            (temporary, response) = try await session.download(from: url, delegate: limits)
        } catch {
            throw limits.refusal ?? error
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let refusal = limits.check(response, received: Self.size(of: temporary)) { throw refusal }
        let file = try Paths.ensure(folder.appendingPathComponent(String(UUID().uuidString.prefix(8)), isDirectory: true))
            .appendingPathComponent(name(for: url, response: response))
        try FileManager.default.moveItem(at: temporary, to: file)
        return file
    }

    private static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Watches a download's bytes as they arrive and stops it at the first that breaks a rule.
    private final class Limits: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let url: URL
        let largest: Int
        private let lock = NSLock()
        private var observation: NSKeyValueObservation?
        private var stoppedFor: EsclopError?

        init(url: URL, largest: Int) {
            self.url = url
            self.largest = largest
        }

        /// Why the download was stopped, if it was.
        var refusal: EsclopError? { lock.withLock { stoppedFor } }

        /// What breaks a rule: an error status, more than `largest` bytes announced or received,
        /// an answer that is not media. nil while it may go on.
        func check(_ response: URLResponse, received: Int64) -> EsclopError? {
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                return .other("\(url.absoluteString) answered \(http.statusCode)")
            }
            if max(response.expectedContentLength, received) > Int64(largest) {
                return .other("\(url.absoluteString) is larger than \(ByteSize.format(largest)), the most L'Esclop downloads")
            }
            // A web page served at a media address (a login page at `photo.jpg`) is refused too.
            let name = WebDownload.name(for: url, response: response)
            if MediaKind.of(URL(fileURLWithPath: name)) == nil || response.mimeType?.lowercased().hasPrefix("text/") == true {
                let type = response.mimeType.map { " (\($0))" } ?? ""
                return .other("\(url.absoluteString) is not an image, video, PDF or audio file\(type)")
            }
            return nil
        }

        // All of a task's properties are key-value observable.
        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            let observation = task.observe(\.countOfBytesReceived) { [weak self] task, _ in
                guard let self, let response = task.response, let refusal = self.check(response, received: task.countOfBytesReceived) else { return }
                self.lock.withLock { if self.stoppedFor == nil { self.stoppedFor = refusal } }
                task.cancel()
            }
            lock.withLock { self.observation = observation }
        }
    }

    static func name(for url: URL, response: URLResponse) -> String {
        // The last path part only: a server's suggestion never leaves the download folder.
        var name = ((response.suggestedFilename ?? url.lastPathComponent) as NSString).lastPathComponent
        if name.isEmpty || name == "/" || name.hasPrefix(".") { name = "download" + name }
        if MediaKind.of(URL(fileURLWithPath: name)) == nil,
           let ext = response.mimeType.flatMap({ UTType(mimeType: $0) })?.preferredFilenameExtension
        {
            name = ((name as NSString).deletingPathExtension as String) + "." + ext
        }
        return name
    }
}
