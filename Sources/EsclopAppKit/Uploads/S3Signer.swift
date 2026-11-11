// SPDX-License-Identifier: GPL-3.0-or-later
//
// AWS Signature Version 4 for S3 requests, the scheme every S3-compatible service accepts. The
// body is not hashed (UNSIGNED-PAYLOAD, as the AWS SDKs do for uploads over TLS), so a large
// video is not read twice. Checked against AWS's published example in S3SignerTests.

import CryptoKit
import Foundation

public enum S3Signer {
    public static let unsignedPayload = "UNSIGNED-PAYLOAD"

    /// The headers to add to a request: `x-amz-date`, `x-amz-content-sha256` and `Authorization`.
    /// `headers` are the other headers to sign (lowercased names), `host` included.
    public static func sign(
        method: String, url: URL, headers: [String: String], payloadHash: String = unsignedPayload,
        accessKey: String, secret: String, region: String, date: Date, service: String = "s3"
    ) -> [String: String] {
        let (amzDate, day) = stamps(date)
        var signed = headers.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value.trimmingCharacters(in: .whitespaces) }
        signed["x-amz-date"] = amzDate
        signed["x-amz-content-sha256"] = payloadHash
        if signed["host"] == nil { signed["host"] = hostHeader(url) }
        let names = signed.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(signed[$0]!)\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        let canonical = [
            method, canonicalPath(url), canonicalQuery(url), canonicalHeaders, signedHeaders, payloadHash,
        ].joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", amzDate, scope, hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")
        var key = SymmetricKey(data: Data("AWS4\(secret)".utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: key))
        return [
            "x-amz-date": amzDate,
            "x-amz-content-sha256": payloadHash,
            "Authorization": "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
        ]
    }

    /// `host` or `host:port` when the port is not the scheme's.
    public static func hostHeader(_ url: URL) -> String {
        let host = url.host() ?? ""
        guard let port = url.port else { return host }
        let standard = (url.scheme == "https" && port == 443) || (url.scheme == "http" && port == 80)
        return standard ? host : "\(host):\(port)"
    }

    /// The URL's path as S3 signs it: already encoded once by `encode`, never twice.
    static func canonicalPath(_ url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        return path.isEmpty ? "/" : path
    }

    static func canonicalQuery(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let pairs: [(name: String, value: String)] = items.map { item in (encode(item.name), encode(item.value ?? "")) }
        let sorted = pairs.sorted { a, b in a.name == b.name ? a.value < b.value : a.name < b.name }
        return sorted.map { pair in pair.name + "=" + pair.value }.joined(separator: "&")
    }

    /// AWS's URI encoding: everything but `A-Z a-z 0-9 - . _ ~` (and `/` in a key) as %XX.
    public static func encode(_ text: String, keepSlashes: Bool = false) -> String {
        var out = ""
        for byte in text.utf8 {
            let c = Character(UnicodeScalar(byte))
            if c.isASCII, c.isLetter || c.isNumber || "-._~".contains(c) || (keepSlashes && c == "/") {
                out.append(c)
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    static func stamps(_ date: Date) -> (amzDate: String, day: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amz = formatter.string(from: date)
        return (amz, String(amz.prefix(8)))
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
