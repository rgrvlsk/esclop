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

    /// Hands the local files to `deliver`: dropped files as they are, promised files once
    /// written into a new folder under `folder`, addresses once `download` has fetched them. The
    /// promises are asked for and the downloads started before this returns, so call it while
    /// the drop is under way. Files go ahead as they arrive, gathered while they come within
    /// `gather` of each other, so a drop of many photos is one batch and a slow video or a file
    /// that never comes holds back no other. Failures come with the files they arrived beside.
    // ponytail: promised and downloaded files stay in $TMPDIR/esclop until macOS clears it, like
    // the copies in `results`; prune them at launch with those if they pile up. A legacy promise
    // is taken to list one type per file (unverified); one listing fewer would lose the rest.
    // Files more than `gather` apart are separate batches, each counted against
    // `batchWindowFrom` (slow iCloud originals give cards, not one window); gather longer if so.
    @MainActor
    func resolve(
        into folder: URL = Paths.temporary.appendingPathComponent("dropped", isDirectory: true),
        gather: Duration = .milliseconds(500),
        download: @escaping @Sendable (URL) async throws -> URL = { try await WebDownload.fetch($0) },
        deliver: @escaping @MainActor (_ files: [URL], _ failures: [any Error]) -> Void
    ) {
        // The reader runs once per promised type; a promise of no type is not asked for.
        let asked = promises.filter { !$0.promisedTypes.isEmpty }
        let promised = asked.reduce(0) { $0 + $1.promisedTypes.count }
        let expected = promised + addresses.count
        guard expected > 0 else { return deliver(files, []) }
        let (results, sink) = AsyncStream.makeStream(of: Result<URL, any Error>.self)
        do {
            if !asked.isEmpty {
                let destination = try Paths.ensure(folder.appendingPathComponent(String(UUID().uuidString.prefix(8)), isDirectory: true))
                for promise in asked { promise.receive(into: destination) { sink.yield($0) } }
            }
        } catch {
            for _ in 0 ..< promised { sink.yield(.failure(error)) }
        }
        for address in addresses {
            Task {
                do { sink.yield(.success(try await download(address))) } catch { sink.yield(.failure(error)) }
            }
        }
        let batch = Batch(files: files)
        Task { @MainActor in
            var left = expected
            batch.handOver(after: gather, to: deliver)
            for await result in results {
                switch result {
                case let .success(url): batch.files.append(url)
                case let .failure(error): batch.failures.append(error)
                }
                left -= 1
                if left == 0 { break }
                batch.handOver(after: gather, to: deliver)
            }
            batch.flush?.cancel()
            batch.hand(to: deliver)
        }
    }

    /// What arrived and is not handed over yet.
    @MainActor private final class Batch {
        var files: [URL]
        var failures: [any Error] = []
        var flush: Task<Void, Never>?

        init(files: [URL]) { self.files = files }

        /// Unless another file arrives first: a pause hands over what came so far.
        func handOver(after gather: Duration, to deliver: @escaping @MainActor ([URL], [any Error]) -> Void) {
            flush?.cancel()
            flush = Task { @MainActor in
                try? await Task.sleep(for: gather)
                if !Task.isCancelled { self.hand(to: deliver) }
            }
        }

        func hand(to deliver: @MainActor ([URL], [any Error]) -> Void) {
            guard !files.isEmpty || !failures.isEmpty else { return }
            deliver(files, failures)
            files = []
            failures = []
        }
    }
}
