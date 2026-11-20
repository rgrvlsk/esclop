// SPDX-License-Identifier: GPL-3.0-or-later
//
// A web address the person asked for (`esclop optimise https://…`, an image dropped from a
// browser) is downloaded into L'Esclop's temporary folder and optimised there as a local file.
// Only on such a request: a click on the offer of a copied address of media, or, when the person
// chose "Download and optimise" for `optimiseURLClipboard`, the copy itself. Those two are
// `Terms.automatic`: stricter, as nobody typed the request.

import EsclopCore
import Foundation
import UniformTypeIdentifiers

public enum WebDownload {
    /// Where downloads go, one folder each so names never clash. The app's hourly sweep
    /// (`BackupPruner.prune`) removes old ones.
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

    /// The session of automatic downloads: no cookies sent or kept, and nothing over Low Data Mode.
    public static let automaticSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = timeLimit
        configuration.allowsConstrainedNetworkAccess = false
        return URLSession(configuration: configuration)
    }()

    /// How one download is made.
    public struct Terms: Sendable {
        /// The most bytes it may bring.
        public var largest: Int
        /// L'Esclop started it from a copy, not a typed request: `automaticSession`, one at a time,
        /// and never to this Mac or the local network (`isLocal`).
        public var automatic: Bool
        /// The fraction received, when the server announced the size.
        public var progress: @Sendable (Double) -> Void

        public init(largest: Int = WebDownload.largest, automatic: Bool = false, progress: @escaping @Sendable (Double) -> Void = { _ in }) {
            self.largest = largest
            self.automatic = automatic
            self.progress = progress
        }
    }

    /// Why a download was refused. The CLI prints `description`; the app says it in the
    /// person's language.
    public enum Refusal: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
        case status(URL, Int)
        case tooLarge(URL, largest: Int)
        case notMedia(URL, type: String?)
        /// An automatic download to this Mac or the local network.
        case local(URL)

        public var description: String {
            switch self {
            case let .status(url, code): return "\(url.absoluteString) answered \(code)"
            case let .tooLarge(url, largest): return "\(url.absoluteString) is larger than \(ByteSize.format(largest)), the most L'Esclop downloads"
            case let .notMedia(url, type): return "\(url.absoluteString) is not an image, video, PDF or audio file\(type.map { " (\($0))" } ?? "")"
            case let .local(url): return "\(url.absoluteString) is on this Mac or the local network: only a request downloads it"
            }
        }

        public var errorDescription: String? { description }
    }

    /// The host is this Mac or the local network, by its name or its address: loopback,
    /// link-local, private and shared ranges, `localhost`, `.local` and names without a dot.
    // ponytail: by the name alone, so copying a link resolves nothing; a public name whose DNS
    // answers a private address gets through. Check the connection's remote address
    // (URLSessionTaskMetrics) if that matters.
    public static func isLocal(_ url: URL) -> Bool {
        guard var host = url.host()?.lowercased() else { return false }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if host == "localhost" || (!host.contains(".") && !host.contains(":")) { return true }
        if [".localhost", ".local", ".home.arpa", ".internal", ".lan"].contains(where: host.hasSuffix) { return true }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let a = withUnsafeBytes(of: &v4) { Array($0) }
            return a[0] == 0 || a[0] == 10 || a[0] == 127 || (a[0] == 169 && a[1] == 254) || (a[0] == 172 && (16 ... 31).contains(a[1]))
                || (a[0] == 192 && a[1] == 168) || (a[0] == 100 && (64 ... 127).contains(a[1]))
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host.components(separatedBy: "%")[0], &v6) == 1 {
            let b = withUnsafeBytes(of: &v6) { Array($0) }
            let mapped = b[0 ..< 10].allSatisfy { $0 == 0 } && b[10] == 0xFF && b[11] == 0xFF
            if mapped { return isLocal(URL(string: "http://\(b[12]).\(b[13]).\(b[14]).\(b[15])/")!) }
            let loopback = b[0 ..< 15].allSatisfy { $0 == 0 } && b[15] <= 1
            return loopback || (b[0] == 0xFE && b[1] & 0xC0 == 0x80) || b[0] & 0xFE == 0xFC
        }
        return false
    }

    /// Automatic downloads wait for each other.
    private static let turns = Turns()

    private actor Turns {
        private var busy = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func enter() async {
            guard busy else { return busy = true }
            await withCheckedContinuation { waiting.append($0) }
        }

        func leave() {
            if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        }
    }

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
    /// video, PDF or audio file (a web page, say). A refused or stopped download leaves nothing.
    public static func fetch(_ url: URL, into folder: URL = WebDownload.folder, session: URLSession? = nil, largest: Int = WebDownload.largest) async throws -> URL {
        try await fetch(url, terms: Terms(largest: largest), into: folder, session: session)
    }

    public static func fetch(_ url: URL, terms: Terms, into folder: URL = WebDownload.folder, session: URLSession? = nil) async throws -> URL {
        guard terms.automatic else { return try await transfer(url, terms: terms, into: folder, session: session ?? Self.session) }
        guard !isLocal(url) else { throw Refusal.local(url) }
        await turns.enter()
        do {
            try Task.checkCancellation()
            let file = try await transfer(url, terms: terms, into: folder, session: session ?? automaticSession)
            await turns.leave()
            return file
        } catch {
            await turns.leave()
            throw error
        }
    }

    private static func transfer(_ url: URL, terms: Terms, into folder: URL, session: URLSession) async throws -> URL {
        let limits = Limits(url: url, largest: terms.largest, progress: terms.progress)
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
        let progress: @Sendable (Double) -> Void
        private let lock = NSLock()
        private var observation: NSKeyValueObservation?
        private var stoppedFor: Refusal?

        init(url: URL, largest: Int, progress: @escaping @Sendable (Double) -> Void) {
            self.url = url
            self.largest = largest
            self.progress = progress
        }

        /// Why the download was stopped, if it was.
        var refusal: Refusal? { lock.withLock { stoppedFor } }

        /// What breaks a rule: an error status, more than `largest` bytes announced or received,
        /// an answer that is not media. nil while it may go on.
        func check(_ response: URLResponse, received: Int64) -> Refusal? {
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                return .status(url, http.statusCode)
            }
            if max(response.expectedContentLength, received) > Int64(largest) {
                return .tooLarge(url, largest: largest)
            }
            // A web page served at a media address (a login page at `photo.jpg`) is refused too;
            // other text types stay, as an SVG often comes as text/xml. (Served as text/plain it
            // is named `logo.svg.txt` by `suggestedFilename`, so it is not taken for media.)
            let name = WebDownload.name(for: url, response: response)
            let page = ["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? "")
            if MediaKind.of(URL(fileURLWithPath: name)) == nil || page {
                return .notMedia(url, type: response.mimeType)
            }
            return nil
        }

        // All of a task's properties are key-value observable.
        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            let observation = task.observe(\.countOfBytesReceived) { [weak self] task, _ in
                guard let self, let response = task.response else { return }
                guard let refusal = self.check(response, received: task.countOfBytesReceived) else {
                    if response.expectedContentLength > 0 { self.progress(Double(task.countOfBytesReceived) / Double(response.expectedContentLength)) }
                    return
                }
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
