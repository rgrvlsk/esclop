// SPDX-License-Identifier: GPL-3.0-or-later
//
// The originals L'Esclop keeps (`BackupStore`), for the Originals window: every backup still
// there, not only the last twelve results the menu lists, each restorable through the same
// `AppModel.restore` as a card, Recent and Compare.

import EsclopCore
import EsclopIPC
import Foundation
import Observation

/// One kept original and the result it can undo.
struct OriginalItem: Identifiable, Sendable {
    let entry: BackupEntry
    /// The logged result with this backup, or one rebuilt from the manifest when the log no
    /// longer has it (cleared names, older than the log keeps).
    let result: OptimisationResult
    /// The original is at its place already (restored before): nothing to put back.
    let inPlace: Bool

    var id: UUID { entry.id }
}

@MainActor @Observable
final class OriginalsModel {
    private(set) var items: [OriginalItem] = []
    private(set) var loaded = false
    @ObservationIgnored let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    var store: BackupStore { BackupStore(root: app.service.context.locations.backups) }
    var totalBytes: Int { items.reduce(0) { $0 + $1.entry.bytes } }
    var retentionDays: Int { EsclopSettings.backupRetentionDays.value(in: app.settings) }

    /// Reads the backups and the log off the main actor.
    func load() async {
        let (store, log) = (store, app.service.results)
        items = await Task.detached(priority: .userInitiated) { Self.items(store.entries(), log: log) }.value
        loaded = true
    }

    nonisolated static func items(_ entries: [BackupEntry], log: ResultsLog) -> [OriginalItem] {
        // ponytail: the whole log, once per load; it keeps eight days of results.
        let logged = Dictionary(log.recent(limit: .max).compactMap { result in result.backup.map { ($0.standardizedFileURL.path, result) } }, uniquingKeysWith: { newest, _ in newest })
        return entries.map { entry in
            let output = entry.output ?? entry.original
            let result = logged[entry.backup.standardizedFileURL.path] ?? OptimisationResult(
                id: entry.id, source: entry.original, output: output, backup: entry.backup, kind: MediaKind.of(entry.original) ?? .image,
                // Done when the backup was made: anything at the path changed after that goes to
                // the Trash on restore, never overwritten.
                bytesBefore: entry.bytes, bytesAfter: AppModel.size(of: output), startedAt: entry.createdAt, finishedAt: entry.createdAt,
                requestID: entry.requestID
            )
            return OriginalItem(entry: entry, result: result, inPlace: isInPlace(entry))
        }
    }

    /// The file at the original's path is the original again: its size, and no converted output
    /// beside it. ponytail: size only, as `holdsOutput` judges by size and date.
    nonisolated static func isInPlace(_ entry: BackupEntry) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: entry.original.path), AppModel.size(of: entry.original) == entry.bytes else { return false }
        guard let output = entry.output, output.standardizedFileURL != entry.original.standardizedFileURL else { return true }
        return !fm.fileExists(atPath: output.path)
    }

    func restore(_ item: OriginalItem) async {
        if await app.restore(item.result) { await load() }
    }

    /// Deletes every kept original: none of these files can be restored afterwards.
    func removeAll() async {
        let (store, entries) = (store, items.map(\.entry))
        await Task.detached(priority: .userInitiated) { for entry in entries { try? store.delete(entry) } }.value
        await load()
    }

    func reveal(_ item: OriginalItem) {
        app.reveal([item.entry.backup])
    }
}
