// SPDX-License-Identifier: GPL-3.0-or-later
//
// One PUT of a file to an S3-compatible bucket, signed with SigV4, with progress as the bytes go
// out and cancellation through the calling task. A refusal comes back with the service's own code
// and message ("AccessDenied: Access Denied"), never the request's signature or keys.

import EsclopCore
import Foundation
import UniformTypeIdentifiers

public struct S3Uploader: Sendable {
    public var session: URLSession
    /// A clock for the signature, so tests can pin it.
    public var now: @Sendable () -> Date

    public init(session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.now = now
    }

    /// Uploads `file` to `key` in the target's bucket and returns the link to copy.
    public func upload(
        _ file: URL, to target: UploadTarget, key: String, credentials: UploadCredentials,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        if let problem = target.problem { throw EsclopError.invalidArgument(problem) }
        guard let url = target.objectURL(key: key), let link = target.link(key: key) else {
            throw EsclopError.invalidArgument(Strings.text("The endpoint is an address such as https://s3.eu-west-1.amazonaws.com."))
        }
        guard FileManager.default.fileExists(atPath: file.path) else { throw EsclopError.fileNotFound(file.path) }
        // ponytail: one PUT, which S3 takes up to 5 GiB; a multipart upload when larger files need to go.
        if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber, size.int64Value > Self.largestPut {
            throw EsclopError.invalidArgument(Strings.format("%@ is larger than 5 GB, the most L’Esclop can upload in one go.", file.lastPathComponent))
        }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        let signed = S3Signer.sign(
            method: "PUT", url: url, headers: ["host": S3Signer.hostHeader(url), "content-type": type],
            accessKey: credentials.accessKeyID, secret: credentials.secret, region: target.region, date: now()
        )
        for (name, value) in signed { request.setValue(value, forHTTPHeaderField: name) }

        let delegate = ProgressDelegate(progress)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.upload(for: request, fromFile: file, delegate: delegate)
        } catch let error as URLError where error.code == .cancelled {
            throw EsclopError.cancelled
        } catch is CancellationError {
            throw EsclopError.cancelled
        } catch let error as URLError {
            throw EsclopError.other(Strings.format("Could not reach %@: %@", url.host() ?? target.endpoint, error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else { throw EsclopError.other(Strings.text("The upload target did not answer.")) }
        // The session reports sent bytes on its own queue; none may land after the last word.
        delegate.finish()
        guard (200 ..< 300).contains(http.statusCode) else {
            throw EsclopError.other(Self.refusal(status: http.statusCode, body: data))
        }
        progress(1)
        return link
    }

    /// Removes `key` from the target's bucket (the test upload's file, once checked).
    public func delete(_ key: String, from target: UploadTarget, credentials: UploadCredentials) async throws {
        guard let url = target.objectURL(key: key) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let signed = S3Signer.sign(
            method: "DELETE", url: url, headers: ["host": S3Signer.hostHeader(url)],
            accessKey: credentials.accessKeyID, secret: credentials.secret, region: target.region, date: now()
        )
        for (name, value) in signed { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw EsclopError.other(Self.refusal(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data))
        }
    }

    /// The largest file one PUT takes (S3's limit, also R2's and B2's).
    static let largestPut: Int64 = 5 * 1024 * 1024 * 1024

    /// Whether `link` answers for someone without the keys (a HEAD request), as the test upload
    /// checks: throws what to set when it does not.
    public func checkLink(_ link: URL) async throws {
        var request = URLRequest(url: link)
        request.httpMethod = "HEAD"
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw EsclopError.other(Strings.format("Could not reach %@: %@", link.host() ?? link.absoluteString, error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw EsclopError.other(Strings.format("The test file went up, but its link answers %d: people you send it to cannot open it. Set the public link to an address that serves the bucket, with {path}.", status))
        }
    }

    /// "The upload target refused the file (403): AccessDenied, Access Denied."
    static func refusal(status: Int, body: Data) -> String {
        let text = String(data: body, encoding: .utf8) ?? ""
        func element(_ name: String) -> String? {
            guard let start = text.range(of: "<\(name)>"), let end = text.range(of: "</\(name)>", range: start.upperBound ..< text.endIndex) else { return nil }
            return String(text[start.upperBound ..< end.lowerBound])
        }
        let detail = [element("Code"), element("Message")].compactMap { $0 }.joined(separator: ", ")
        return detail.isEmpty
            ? Strings.format("The upload target refused the file (%d).", status)
            : Strings.format("The upload target refused the file (%d): %@.", status, detail)
    }
}

/// Reports the bytes sent, until the upload is over.
/// Sendable by hand: `finished` is behind `lock`.
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let report: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var finished = false

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func finish() { lock.withLock { finished = true } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        // Under the lock, so a report never crosses finish().
        lock.withLock {
            guard !finished else { return }
            report(min(0.99, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        }
    }
}
