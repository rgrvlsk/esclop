// SPDX-License-Identifier: GPL-3.0-or-later
//
// What a drag carries that L'Esclop can optimise: files (Finder), file promises (Photos, Mail,
// Safari's images) and web addresses of images and videos (a browser). Promised and downloaded
// files land in L'Esclop's temporary folder and are then optimised as dropped files: dropping is
// the person's request, so the download is one they asked for.

import AppKit
import EsclopCore
import EsclopIPC
import UniformTypeIdentifiers

/// A file another app promises to write where the drop asks; NSFilePromiseReceiver in the app,
/// a fake in tests.
protocol FilePromise {
    /// The promised files' type identifiers, one per file.
    var promisedTypes: [String] { get }
    /// Asks for the files in `folder`; `reader` runs once per file, on any thread.
    func receive(into folder: URL, reader: @escaping @Sendable (Result<URL, any Error>) -> Void)
}

extension NSFilePromiseReceiver: FilePromise {
    var promisedTypes: [String] { fileTypes }

    func receive(into folder: URL, reader: @escaping @Sendable (Result<URL, any Error>) -> Void) {
        receivePromisedFiles(atDestination: folder, operationQueue: DropIntake.promiseQueue) { url, error in
            reader(error.map { .failure($0) } ?? .success(url))
        }
    }
}

struct DropIntake {
    var files: [URL] = []
    var promises: [any FilePromise] = []
    /// Web addresses of media, only when the drag has no files or promises (a browser sends the
    /// address beside the image's promise; the promise is the exact file).
    var addresses: [URL] = []
    /// The drag carries image data beside its addresses, so an address without an extension is
    /// an image's.
    var addressesAreImages = false

    nonisolated static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// The pasteboard types a drop target registers for, to be offered all of these.
    static let draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    init(files: [URL] = [], promises: [any FilePromise] = [], addresses: [URL] = [], addressesAreImages: Bool = false) {
        self.files = files
        self.promises = promises
        self.addresses = addresses
        self.addressesAreImages = addressesAreImages
    }

    init(pasteboard: NSPasteboard) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        files = urls.filter(\.isFileURL)
        if files.isEmpty {
            promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        }
        guard files.isEmpty, promises.isEmpty else { return }
        addressesAreImages = pasteboard.types?.contains { UTType($0.rawValue)?.conforms(to: .image) ?? false } ?? false
        addresses = urls.filter { url in
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
            return MediaKind.of(url) != nil || addressesAreImages
        }
    }

    var isEmpty: Bool { files.isEmpty && promises.isEmpty && addresses.isEmpty }

    /// The kinds a drag of promises and addresses carries, for the preset zones; files are
    /// counted by `DropZoneController.media(in:)`.
    var remoteMedia: (count: Int, kinds: Set<MediaKind>) {
        var kinds = Set<MediaKind>()
        var count = 0
        for type in promises.flatMap(\.promisedTypes) {
            guard let kind = UTType(type).flatMap(MediaKind.of) else { continue }
            count += 1
            kinds.insert(kind)
        }
        for address in addresses {
            count += 1
            kinds.insert(MediaKind.of(address) ?? .image)
        }
        return (count, kinds)
    }

    /// The local files to optimise: dropped files as they are, promised files once written into
    /// a new folder under `folder`, addresses once `download` has fetched them. The promises are
    /// asked for and the downloads started before this returns, so call it while the drop is
    /// under way; the task ends when every file arrived or failed. Failures come back beside the
    /// files, which go ahead without them.
    @MainActor
    func resolve(
        into folder: URL = Paths.temporary.appendingPathComponent("dropped", isDirectory: true),
        download: @escaping @Sendable (URL) async throws -> URL = { try await WebDownload.fetch($0) }
    ) -> Task<(files: [URL], failures: [any Error]), Never> {
        // The reader runs once per promised type; a promise of no type is not asked for, so the
        // count below always reaches zero.
        let asked = promises.filter { !$0.promisedTypes.isEmpty }
        let expected = asked.reduce(0) { $0 + $1.promisedTypes.count } + addresses.count
        let (results, sink) = AsyncStream.makeStream(of: Result<URL, any Error>.self)
        if expected == 0 { sink.finish() }
        do {
            if !asked.isEmpty {
                let destination = try Paths.ensure(folder.appendingPathComponent(String(UUID().uuidString.prefix(8)), isDirectory: true))
                for promise in asked { promise.receive(into: destination) { sink.yield($0) } }
            }
        } catch {
            sink.yield(.failure(error))
            sink.finish()
        }
        for address in addresses {
            Task {
                do { sink.yield(.success(try await download(address))) } catch { sink.yield(.failure(error)) }
            }
        }
        let files = files
        return Task { @MainActor in
            var left = expected
            var received: [URL] = []
            var failures: [any Error] = []
            for await result in results {
                switch result {
                case let .success(url): received.append(url)
                case let .failure(error): failures.append(error)
                }
                left -= 1
                if left == 0 { break }
            }
            received.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            return (files + received, failures)
        }
    }
}
