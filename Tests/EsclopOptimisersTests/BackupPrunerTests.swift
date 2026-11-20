// SPDX-License-Identifier: GPL-3.0-or-later

import EsclopCore
@testable import EsclopOptimisers
import Foundation
import Testing

@Suite struct BackupPrunerTests {
    /// Retention also applies at launch: no new in-place job has to run first.
    @Test func launchRemovesExpiredBackupsAndOldTemporaryFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("esclop-pruner-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let store = BackupStore(root: root.appendingPathComponent("backups", isDirectory: true))
        let file = root.appendingPathComponent("photo.png")
        try Paths.ensure(root)
        try Data("original".utf8).write(to: file)
        let old = try store.backUp(file)
        let fresh = try store.backUp(file)
        try age(old, days: 10)

        // L'Esclop's temporary folder: folders of one folder per item, and loose leftovers.
        let temporary = try Paths.ensure(root.appendingPathComponent("temporary", isDirectory: true))
        let tenDaysAgo = Date().addingTimeInterval(-10 * 86400)
        var kept: [URL] = [], gone: [URL] = []
        for parent in ["clipboard", "results", "downloads", "dropped", "work", "estimates"] {
            let folder = temporary.appendingPathComponent(parent, isDirectory: true)
            let old = try Paths.ensure(folder.appendingPathComponent("old", isDirectory: true))
            try Data("copy".utf8).write(to: old.appendingPathComponent("photo.png"))
            try fm.setAttributes([.modificationDate: tenDaysAgo], ofItemAtPath: old.path)
            kept += [try Paths.ensure(folder.appendingPathComponent("new", isDirectory: true)), folder]
            gone.append(old)
        }
        // A Shortcut's input: a file whose own date is old (a copy keeps it) in a folder made now.
        let shortcut = try Paths.ensure(temporary.appendingPathComponent("shortcuts-NEW", isDirectory: true))
        try Data("input".utf8).write(to: shortcut.appendingPathComponent("old photo.png"))
        try fm.setAttributes([.modificationDate: tenDaysAgo], ofItemAtPath: shortcut.appendingPathComponent("old photo.png").path)
        kept.append(shortcut.appendingPathComponent("old photo.png"))
        let oldFork = try Paths.ensure(temporary.appendingPathComponent("fork-OLD", isDirectory: true))
        try Data("fork".utf8).write(to: oldFork.appendingPathComponent("photo.png"))
        try fm.setAttributes([.modificationDate: tenDaysAgo], ofItemAtPath: oldFork.path)
        gone.append(oldFork)

        BackupPruner.prune(days: 7, backups: store, temporary: temporary)
        #expect(store.entries().map(\.id) == [fresh.id])
        for url in gone { #expect(!fm.fileExists(atPath: url.path), "\(url.lastPathComponent) in \(url.deletingLastPathComponent().lastPathComponent)") }
        for url in kept { #expect(fm.fileExists(atPath: url.path), "\(url.path)") }

        // Backups kept for ever: the temporary folder still goes after its own limit, not before.
        BackupPruner.prune(days: 0, backups: store, temporary: temporary, now: Date().addingTimeInterval(Double(BackupPruner.temporaryDays - 1) * 86400))
        #expect(fm.fileExists(atPath: shortcut.path))
        BackupPruner.prune(days: 0, backups: store, temporary: temporary, now: Date().addingTimeInterval(365 * 86400))
        #expect(store.entries().count == 1, "0 days keeps every backup")
        #expect(!fm.fileExists(atPath: shortcut.path), "a week at most for the temporary folder")
    }

    /// Moves a backup's manifest date back.
    func age(_ entry: BackupEntry, days: Int) throws {
        let manifest = entry.backup.deletingLastPathComponent().appendingPathComponent("manifest.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var aged = try decoder.decode(BackupEntry.self, from: Data(contentsOf: manifest))
        aged.createdAt = aged.createdAt.addingTimeInterval(-Double(days) * 86400)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(aged).write(to: manifest)
    }
}
