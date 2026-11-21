// SPDX-License-Identifier: GPL-3.0-or-later
//
// Originals are copied here before anything overwrites them, so every in-place result can be
// undone. Each backup is its own folder under `Paths.backups`:
//
//   backups/<id>/<original file name>
//   backups/<id>/manifest.json      where it came from, what replaced it, when
//
// One folder per backup means the app, the CLI and the MCP server can write concurrently without
// sharing a manifest file. On APFS the copy is a clone and costs no space until the file changes.
//
// Files esclop writes carry the extended attribute `dev.esclop.optimised` so the clipboard and
// folder watchers do not optimise their own output again.

import Darwin
import Foundation

// MARK: - Backups

public struct BackupEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Where the original lived.
    public var original: URL
    /// The copy inside the backup folder.
    public var backup: URL
    /// What replaced the original (differs from `original` after a format conversion).
    public var output: URL?
    public var requestID: UUID?
    public var createdAt: Date
    public var bytes: Int

    public init(id: UUID, original: URL, backup: URL, output: URL?, requestID: UUID?, createdAt: Date, bytes: Int) {
        self.id = id
        self.original = original
        self.backup = backup
        self.output = output
        self.requestID = requestID
        self.createdAt = createdAt
        self.bytes = bytes
    }
}

/// What a restore set aside on the way.
public struct RestoreReport: Equatable, Sendable {
    /// Where the files set aside are now, in the Trash.
    public var trashed: [URL] = []
    /// A converted output the Trash refused; it is still at this path.
    public var leftInPlace: URL?
    /// The original was back already (another process put it back): nothing was touched.
    public var alreadyRestored = false
}

public struct BackupStore: Sendable {
    public static var shared: BackupStore { BackupStore(root: Paths.backups) }

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    static let manifestName = "manifest.json"

    /// Copies `original` into a new backup folder and records it.
    @discardableResult
    public func backUp(_ original: URL, requestID: UUID? = nil, output: URL? = nil) throws -> BackupEntry {
        let fm = FileManager.default
        guard fm.fileExists(atPath: original.path) else {
            throw EsclopError.fileNotFound(original.path)
        }
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try Paths.ensure(folder)
        let copy = folder.appendingPathComponent(original.lastPathComponent)
        do {
            try fm.copyItem(at: original, to: copy)
        } catch {
            try? fm.removeItem(at: folder)
            throw EsclopError.other("Could not back up \(original.lastPathComponent): \(error.localizedDescription)")
        }
        let bytes = (try? copy.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let entry = BackupEntry(
            id: id, original: original.standardizedFileURL, backup: copy, output: output?.standardizedFileURL,
            requestID: requestID, createdAt: Date(), bytes: bytes
        )
        try write(entry)
        Log.backups.info("Backed up \(original.lastPathComponent, privacy: .private) as \(id.uuidString, privacy: .public)")
        return entry
    }

    /// Records what replaced the original once the result is in place.
    @discardableResult
    public func setOutput(_ output: URL, for entry: BackupEntry) throws -> BackupEntry {
        var updated = entry
        updated.output = output.standardizedFileURL
        try write(updated)
        return updated
    }

    /// When the entry's result was in place: its manifest is written last, by `setOutput`.
    /// ponytail: a file date, so a backups folder copied with new dates (a migration, a restore
    /// from Time Machine) moves it later, and an edit made before then is replaced without the
    /// Trash. Record the time in the manifest if backups are ever moved between Macs.
    public static func placedAt(_ entry: BackupEntry) -> Date? {
        let manifest = entry.backup.deletingLastPathComponent().appendingPathComponent(manifestName)
        return (try? FileManager.default.attributesOfItem(atPath: manifest.path))?[.modificationDate] as? Date
    }

    /// Every backup, newest first. Folders without a readable manifest are skipped.
    public func entries() -> [BackupEntry] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { read(folder: $0) }.sorted { $0.createdAt > $1.createdAt }
    }

    public func entry(id: UUID) -> BackupEntry? {
        read(folder: root.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    /// The entry whose backup file is `url` (what `OptimisationResult.backup` points at).
    public func entry(forBackup url: URL) -> BackupEntry? {
        read(folder: url.deletingLastPathComponent())
    }

    /// The most recent backup of the file at `original`.
    public func latest(for original: URL) -> BackupEntry? {
        let path = original.standardizedFileURL.path
        return entries().first { $0.original.path == path || $0.output?.path == path }
    }

    /// Puts a result's original back at its source path, the one restore path for the app, the
    /// CLI and the MCP server. Nothing is deleted: a file at the source path that is no longer the
    /// result's output (edited, or optimised again since) and a converted output with another name
    /// go to the Trash. The backup itself is kept until pruned.
    @discardableResult
    public func restore(_ result: OptimisationResult) throws -> RestoreReport {
        let fm = FileManager.default
        guard let backup = result.backup, fm.fileExists(atPath: backup.path) else {
            throw EsclopError.fileNotFound(result.backup?.path ?? result.source.path)
        }
        let original = result.source
        // Put back already, by whichever process (the CLI, an agent, another window): again would
        // send the original itself to the Trash as an edit.
        if Self.holdsOriginal(of: result) { return RestoreReport(alreadyRestored: true) }
        try Paths.ensure(original.deletingLastPathComponent())
        var report = RestoreReport()
        // A name of its own in the same folder (same volume): never another restore's, never a
        // file that happens to be there.
        let staging = original.deletingLastPathComponent()
            .appendingPathComponent(".\(original.lastPathComponent).esclop-restore-\(UUID().uuidString.prefix(8))")
        try fm.copyItem(at: backup, to: staging)
        do {
            if fm.fileExists(atPath: original.path) {
                if Self.holdsOutput(of: result) {
                    _ = try fm.replaceItemAt(original, withItemAt: staging)
                } else {
                    do {
                        report.trashed.append(try trash(original))
                    } catch {
                        throw EsclopError.other(Self.untrashableEdit)
                    }
                    try fm.moveItem(at: staging, to: original)
                }
            } else {
                try fm.moveItem(at: staging, to: original)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        OptimisedMark.clear(original)
        // Only once the original is back: a converted output with another name goes to the Trash,
        // or stays where it is when the Trash refuses it. Never a permanent removal.
        let output = result.output
        if output.standardizedFileURL.path != original.standardizedFileURL.path, fm.fileExists(atPath: output.path) {
            do { report.trashed.append(try trash(output)) } catch { report.leftInPlace = output }
        }
        Log.backups.info("Restored \(original.lastPathComponent, privacy: .private)")
        return report
    }

    /// One sentence for people, translated by the app (no file name: the card names it).
    public static let untrashableEdit = "The file changed after it was optimised and could not go to the Trash, so it was left as it is."

    /// Whether the file at the source path is still the output `result` wrote: same path, same
    /// size, and not modified after the result finished.
    // ponytail: size and date, no hash; an edit that keeps the exact size and backdates the file
    // passes. Store a hash in the result if that ever matters.
    static func holdsOutput(of result: OptimisationResult) -> Bool {
        // Attributes, not URL resource values: those are cached on a URL the app keeps.
        guard result.output.standardizedFileURL.path == result.source.standardizedFileURL.path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: result.source.path),
              (attributes[.size] as? NSNumber)?.intValue == result.bytesAfter,
              let modified = attributes[.modificationDate] as? Date
        else { return false }
        // Results read back from the shared log carry whole seconds.
        return modified <= result.finishedAt.addingTimeInterval(2)
    }

    /// Whether the file at the source path is the original again: the backup, byte for byte.
    /// Reads both files when their sizes agree; call it off the main actor.
    public static func holdsOriginal(of result: OptimisationResult) -> Bool {
        guard let backup = result.backup else { return false }
        let fm = FileManager.default
        func size(_ url: URL) -> Int? { (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int }
        guard let bytes = size(result.source), bytes == size(backup) else { return false }
        return fm.contentsEqual(atPath: result.source.path, andPath: backup.path)
    }

    /// Moves `url` to the Trash and returns where it went. Tests swap it for a folder of their own.
    var trash: @Sendable (URL) throws -> URL = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return (resulting as URL?) ?? url
    }

    public func delete(_ entry: BackupEntry) throws {
        try FileManager.default.removeItem(at: entry.backup.deletingLastPathComponent())
    }

    /// Removes backups older than `days` (0 keeps everything). Returns how many were removed.
    @discardableResult
    public func prune(olderThan days: Int, now: Date = Date()) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        var removed = 0
        for entry in entries() where entry.createdAt < cutoff {
            if (try? delete(entry)) != nil { removed += 1 }
        }
        return removed
    }

    /// Total bytes held by backups.
    public func totalBytes() -> Int {
        entries().reduce(0) { $0 + $1.bytes }
    }

    private func write(_ entry: BackupEntry) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        let folder = entry.backup.deletingLastPathComponent()
        try data.write(to: folder.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    private func read(folder: URL) -> BackupEntry? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(Self.manifestName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BackupEntry.self, from: data)
    }
}

// MARK: - Extended attributes

public enum Xattr {
    public static func get(_ name: String, at url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let length = getxattr(path, name, nil, 0, 0, 0)
            guard length >= 0 else { return nil }
            var data = Data(count: length)
            let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, length, 0, 0) }
            return read >= 0 ? data.prefix(read) : nil
        }
    }

    public static func set(_ name: String, _ data: Data, at url: URL) throws {
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, 0) }
        }
        guard status == 0 else {
            throw EsclopError.other("Could not set \(name) on \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
    }

    public static func remove(_ name: String, at url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            removexattr(path, name, 0)
        }
    }

    public static func names(at url: URL) -> [String] {
        url.withUnsafeFileSystemRepresentation { path -> [String] in
            guard let path else { return [] }
            let length = listxattr(path, nil, 0, 0)
            guard length > 0 else { return [] }
            var buffer = [CChar](repeating: 0, count: length)
            let read = listxattr(path, &buffer, length, 0)
            guard read > 0 else { return [] }
            return buffer[0 ..< read].split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        }
    }
}

/// The marker on files esclop wrote. The value is a small JSON note: when and which version.
public enum OptimisedMark {
    public static let name = "dev.esclop.optimised"

    public static func set(_ url: URL, note: String = "1") throws {
        try Xattr.set(name, Data(note.utf8), at: url)
    }

    public static func isMarked(_ url: URL) -> Bool {
        Xattr.get(name, at: url) != nil
    }

    public static func value(_ url: URL) -> String? {
        Xattr.get(name, at: url).map { String(decoding: $0, as: UTF8.self) }
    }

    public static func clear(_ url: URL) {
        Xattr.remove(name, at: url)
    }
}
