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

    /// Puts the original back where it was. A converted output with a different name is moved to
    /// the trash (it can be recovered from there). The backup itself is kept until pruned.
    @discardableResult
    public func restore(_ entry: BackupEntry, removeOutput: Bool = true) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: entry.backup.path) else {
            throw EsclopError.fileNotFound(entry.backup.path)
        }
        try Paths.ensure(entry.original.deletingLastPathComponent())
        let staging = entry.original.deletingLastPathComponent()
            .appendingPathComponent(".\(entry.original.lastPathComponent).esclop-restore-\(UUID().uuidString.prefix(8))")
        try fm.copyItem(at: entry.backup, to: staging)
        if fm.fileExists(atPath: entry.original.path) {
            _ = try fm.replaceItemAt(entry.original, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: entry.original)
        }
        OptimisedMark.clear(entry.original)
        // Only once the original is back: a converted output with another name goes to the trash.
        if removeOutput, let output = entry.output, output.path != entry.original.path, fm.fileExists(atPath: output.path) {
            try? fm.trashItem(at: output, resultingItemURL: nil)
            if fm.fileExists(atPath: output.path) { try? fm.removeItem(at: output) }
        }
        Log.backups.info("Restored \(entry.original.lastPathComponent, privacy: .private)")
        return entry.original
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
