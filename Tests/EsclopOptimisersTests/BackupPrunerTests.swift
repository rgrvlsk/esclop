// SPDX-License-Identifier: GPL-3.0-or-later

import EsclopCore
@testable import EsclopOptimisers
import Foundation
import Testing

@Suite struct BackupPrunerTests {
    /// Retention also applies at launch: no new in-place job has to run first.
    @Test func launchRemovesExpiredBackupsAndCopiedImages() throws {
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

        let clipboard = root.appendingPathComponent("clipboard", isDirectory: true)
        let oldCopy = try Paths.ensure(clipboard.appendingPathComponent("old", isDirectory: true))
        let newCopy = try Paths.ensure(clipboard.appendingPathComponent("new", isDirectory: true))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-10 * 86400)], ofItemAtPath: oldCopy.path)

        BackupPruner.pruneAtLaunch(days: 7, backups: store, clipboard: clipboard)
        #expect(store.entries().map(\.id) == [fresh.id])
        #expect(!fm.fileExists(atPath: oldCopy.path))
        #expect(fm.fileExists(atPath: newCopy.path))

        BackupPruner.pruneAtLaunch(days: 0, backups: store, clipboard: clipboard, now: Date().addingTimeInterval(365 * 86400))
        #expect(store.entries().count == 1, "0 days keeps everything")
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
