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
        guard (200 ..< 300).contains(http.statusCode) else {
            throw EsclopError.other(Self.refusal(status: http.statusCode, body: data))
        }
        progress(1)
        return link
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

/// Reports the bytes sent.
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(min(0.99, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}
