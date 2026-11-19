// SPDX-License-Identifier: GPL-3.0-or-later
//
// A web address the person asked for (`esclop optimise https://…`, an image dropped from a
// browser) is downloaded into L'Esclop's temporary folder and optimised there as a local file.
// Only on such a request: PRODUCT.md allows network operations only when the person asks.

import EsclopCore
import Foundation
import UniformTypeIdentifiers

public enum WebDownload {
    /// Where downloads go, one folder each so names never clash.
    public static var folder: URL { Paths.temporary.appendingPathComponent("downloads", isDirectory: true) }

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
    /// that L'Esclop knows, so `…/photo?w=800` served as JPEG becomes `photo.jpg`.
    public static func fetch(_ url: URL, into folder: URL = WebDownload.folder, session: URLSession = .shared) async throws -> URL {
        let (temporary, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw EsclopError.other("\(url.absoluteString) answered \(http.statusCode)")
        }
        let file = try Paths.ensure(folder.appendingPathComponent(String(UUID().uuidString.prefix(8)), isDirectory: true))
            .appendingPathComponent(name(for: url, response: response))
        try FileManager.default.moveItem(at: temporary, to: file)
        return file
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
