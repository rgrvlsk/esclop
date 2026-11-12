// SPDX-License-Identifier: GPL-3.0-or-later
//
// An upload target: an S3-compatible bucket (AWS S3, Cloudflare R2, Backblaze B2, MinIO) the
// person set up in Settings › Uploads. What it holds is not secret and lives in the
// `uploadTargets` setting, one JSON object per target; the keys live in the Keychain only
// (UploadCredentials).

import EsclopCore
import EsclopPipelines
import Foundation

public struct UploadTarget: Codable, Hashable, Identifiable, Sendable {
    /// What the person calls it; `upload(to:)` and `esclop upload --to` name it.
    public var name: String
    /// `https://s3.eu-west-1.amazonaws.com`, `https://<account>.r2.cloudflarestorage.com`,
    /// `https://s3.us-west-004.backblazeb2.com`, `http://127.0.0.1:9000`.
    public var endpoint: String
    public var bucket: String
    /// `us-east-1`; R2 takes `auto`.
    public var region: String
    /// Where the file goes in the bucket, with the pipeline path tokens (%f, %e, %y, %m, %r...).
    public var path: String
    /// The link that is copied: a template where `{path}` is the uploaded path. Empty: the
    /// object's address at the endpoint.
    public var publicURL: String
    /// `endpoint/bucket/path` (true) or `bucket.endpoint/path` (false).
    public var pathStyle: Bool

    public var id: String { name }

    public static let defaultPath = "%y/%m/%f-%r.%e"

    public init(name: String, endpoint: String, bucket: String, region: String = "us-east-1", path: String = UploadTarget.defaultPath, publicURL: String = "", pathStyle: Bool = true) {
        self.name = name
        self.endpoint = endpoint
        self.bucket = bucket
        self.region = region
        self.path = path
        self.publicURL = publicURL
        self.pathStyle = pathStyle
    }

    // MARK: Checking

    /// What is wrong with the target, in words for the person, or nil.
    public var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return Strings.text("A target needs a name.") }
        guard let url = URL(string: endpoint), let scheme = url.scheme?.lowercased(), let host = url.host(), !host.isEmpty else {
            return Strings.text("The endpoint is an address such as https://s3.eu-west-1.amazonaws.com.")
        }
        // Keys never travel in the clear, except to a server on this Mac (tests, a local MinIO).
        if scheme != "https", !(scheme == "http" && Self.isLocal(host)) {
            return Strings.text("The endpoint must use https (http only for a server on this Mac).")
        }
        if bucket.trimmingCharacters(in: .whitespaces).isEmpty { return Strings.text("A target needs a bucket.") }
        if region.trimmingCharacters(in: .whitespaces).isEmpty { return Strings.text("A target needs a region (auto for Cloudflare R2).") }
        if path.trimmingCharacters(in: .whitespaces).isEmpty { return Strings.text("A target needs a path, such as %f.%e.") }
        if !publicURL.isEmpty, URL(string: publicURL.replacingOccurrences(of: "{path}", with: "x"))?.scheme == nil {
            return Strings.text("The public link is an address with {path} where the file's path goes.")
        }
        return nil
    }

    static func isLocal(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
    }

    // MARK: Addresses

    /// The object key for `file`: the path template resolved, without a leading slash.
    public func key(for file: URL, date: Date = Date()) -> String {
        let resolved = TemplateContext(file: file, date: date).resolve(path)
        return resolved.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }

    /// The address the file is PUT to.
    public func objectURL(key: String) -> URL? {
        guard var components = URLComponents(string: endpoint) else { return nil }
        let base = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        if pathStyle {
            components.percentEncodedPath = base + "/" + S3Signer.encode(bucket) + "/" + S3Signer.encode(key, keepSlashes: true)
        } else {
            components.host = bucket + "." + (components.host ?? "")
            components.percentEncodedPath = base + "/" + S3Signer.encode(key, keepSlashes: true)
        }
        return components.url
    }

    /// The link that is copied for `key`.
    public func link(key: String) -> URL? {
        guard !publicURL.isEmpty else { return objectURL(key: key) }
        return URL(string: publicURL.replacingOccurrences(of: "{path}", with: S3Signer.encode(key, keepSlashes: true)))
    }

    // MARK: The setting

    /// The targets in the `uploadTargets` setting; entries that do not read are left out.
    public static func all(in store: SettingsStore) -> [UploadTarget] {
        decode(EsclopSettings.uploadTargets.value(in: store))
    }

    public static func decode(_ entries: [String]) -> [UploadTarget] {
        entries.compactMap { try? JSONDecoder().decode(UploadTarget.self, from: Data($0.utf8)) }
    }

    public static func encode(_ targets: [UploadTarget]) -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return targets.compactMap { (try? encoder.encode($0)).flatMap { String(data: $0, encoding: .utf8) } }
    }

    /// The target `name` names, else the default (`uploadTarget`), else the first.
    public static func resolve(_ name: String?, in store: SettingsStore) throws -> UploadTarget {
        let targets = all(in: store)
        guard !targets.isEmpty else {
            throw EsclopError.invalidArgument(Strings.text("There is no upload target yet. Add one in Settings › Uploads (esclop://settings/uploads)."))
        }
        let wanted = name.flatMap { $0.isEmpty ? nil : $0 } ?? EsclopSettings.uploadTarget.value(in: store)
        if wanted.isEmpty { return targets[0] }
        guard let target = targets.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) else {
            throw EsclopError.invalidArgument(Strings.format("There is no upload target named “%@”. Targets: %@.", wanted, targets.map(\.name).joined(separator: ", ")))
        }
        return target
    }
}
