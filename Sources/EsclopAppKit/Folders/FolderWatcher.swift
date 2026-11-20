// SPDX-License-Identifier: GPL-3.0-or-later
//
// File events in the watched folders, from FSEvents: one stream for every folder, file-level
// events, delivered on a serial queue and handed to the main actor as paths. Only files that
// were created, renamed into place or written count; removals do not. With `rootChanged`, a
// watched folder that is created, renamed or deleted is reported too.

import CoreServices
import Foundation

/// Sendable by hand: its owner sets and clears `stream` on the main actor; FSEvents calls back on `queue`.
final class FolderWatcher: @unchecked Sendable {
    typealias Handler = @Sendable ([URL]) -> Void

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.esclop.folder-watcher")
    private static let queueKey = DispatchSpecificKey<Bool>()
    private let handler: Handler
    /// Report every change, removals included (the pipelines folder), not only new files.
    private let everyChange: Bool
    /// A watched folder itself appeared, moved or went away (FSEvents' root change).
    private let rootChanged: (@Sendable () -> Void)?

    init(everyChange: Bool = false, rootChanged: (@Sendable () -> Void)? = nil, handler: @escaping Handler) {
        self.rootChanged = rootChanged
        self.everyChange = everyChange
        self.handler = handler
        queue.setSpecific(key: Self.queueKey, value: true)
    }

    deinit { stop() }

    /// Watches `folders`, replacing any earlier stream. A folder that is not there yet can be in
    /// the list: its creation is a root change. False when FSEvents refused the stream (a path
    /// too long, for one), so nothing is watched.
    @discardableResult
    func start(_ folders: [URL]) -> Bool {
        stop()
        guard !folders.isEmpty else { return false }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        var flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes
        if rootChanged != nil { flags |= kFSEventStreamCreateFlagWatchRoot }
        guard let stream = FSEventStreamCreate(
            nil, Self.callback, &context, folders.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, UInt32(flags)
        ) else { return false }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        // Let a callback already running finish before this object can go away (the stream holds
        // an unretained pointer to it). Skipped when stopping from that callback itself.
        if DispatchQueue.getSpecific(key: Self.queueKey) != true { queue.sync {} }
    }

    /// Created, renamed into place or written; a file, not removed.
    static func isNewFile(_ flags: FSEventStreamEventFlags) -> Bool {
        let flags = Int(flags)
        guard flags & kFSEventStreamEventFlagItemIsFile != 0, flags & kFSEventStreamEventFlagItemRemoved == 0 else { return false }
        return flags & (kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified) != 0
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
        let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        if let rootChanged = watcher.rootChanged, (0 ..< count).contains(where: { Int(flags[$0]) & kFSEventStreamEventFlagRootChanged != 0 }) {
            rootChanged()
        }
        if watcher.everyChange {
            watcher.handler(list.map { URL(fileURLWithPath: $0) })
            return
        }
        var files: [URL] = []
        for index in 0 ..< count where index < list.count && isNewFile(flags[index]) {
            // A rename fires for both the old and the new name; only a path that exists is new.
            if FileManager.default.fileExists(atPath: list[index]) { files.append(URL(fileURLWithPath: list[index])) }
        }
        if !files.isEmpty { watcher.handler(files) }
    }
}

/// Waits until a file stops changing: size and modification date the same over consecutive
/// checks, and the file can be opened. A screenshot is written in one go; a download or a
/// recording grows for a while.
enum FileSettle {
    enum Outcome: Equatable {
        case steady
        /// Still, but L'Esclop may not open it: no point in waiting longer.
        case unreadable
        /// It disappeared, stayed empty, or kept changing until the timeout.
        case unsettled
    }

    struct Snapshot: Equatable {
        var size: Int
        var modified: Date
    }

    static func snapshot(_ url: URL) -> Snapshot? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return Snapshot(size: (attributes[.size] as? NSNumber)?.intValue ?? 0, modified: attributes[.modificationDate] as? Date ?? .distantPast)
    }

    /// Steady once the file has been still for `steadyChecks` checks `interval` apart and opens.
    static func wait(
        for url: URL, interval: Duration = .milliseconds(300), steadyChecks: Int = 2, timeout: Duration = .seconds(180)
    ) async -> Outcome {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var last = snapshot(url)
        var steady = 0
        while clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: interval)
            guard let now = snapshot(url) else { return .unsettled }
            if now == last, now.size > 0 {
                steady += 1
                guard steady >= steadyChecks else { continue }
                do {
                    try FileHandle(forReadingFrom: url).close()
                    return .steady
                } catch {
                    // A writer that holds the file shut keeps it waiting; a refusal does not pass.
                    if WatchedFolders.isDenied(error) { return .unreadable }
                }
            } else {
                steady = 0
                last = now
            }
        }
        return .unsettled
    }
}
