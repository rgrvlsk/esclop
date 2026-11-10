// SPDX-License-Identifier: GPL-3.0-or-later
//
// File events in the watched folders, from FSEvents: one stream for every folder, file-level
// events, delivered on a serial queue and handed to the main actor as paths. Only files that
// were created, renamed into place or written count; removals do not.

import CoreServices
import Foundation

final class FolderWatcher: @unchecked Sendable {
    typealias Handler = @Sendable ([URL]) -> Void

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.esclop.folder-watcher")
    private let handler: Handler
    /// Report every change, removals included (the pipelines folder), not only new files.
    private let everyChange: Bool

    init(everyChange: Bool = false, handler: @escaping Handler) {
        self.everyChange = everyChange
        self.handler = handler
    }

    deinit { stop() }

    /// Watches `folders` (existing ones only: FSEvents refuses a whole stream for one missing
    /// path). Replaces any earlier stream.
    func start(_ folders: [URL]) {
        stop()
        guard !folders.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(
            nil, Self.callback, &context, folders.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
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
    struct Snapshot: Equatable {
        var size: Int
        var modified: Date
    }

    static func snapshot(_ url: URL) -> Snapshot? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return Snapshot(size: (attributes[.size] as? NSNumber)?.intValue ?? 0, modified: attributes[.modificationDate] as? Date ?? .distantPast)
    }

    /// True once the file has been still for `steadyChecks` checks `interval` apart; false when
    /// it disappeared, stayed empty, or kept changing until `timeout`.
    static func wait(
        for url: URL, interval: Duration = .milliseconds(300), steadyChecks: Int = 2, timeout: Duration = .seconds(180)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var last = snapshot(url)
        var steady = 0
        while clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: interval)
            guard let now = snapshot(url) else { return false }
            if now == last, now.size > 0 {
                steady += 1
                if steady >= steadyChecks, FileHandle(forReadingAtPath: url.path) != nil { return true }
            } else {
                steady = 0
                last = now
            }
        }
        return false
    }
}
