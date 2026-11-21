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
    /// The names of the originals the last removal could not delete; the window says so.
    var removalFailures: [String] = []
    @ObservationIgnored let app: AppModel
    /// Reads the list again when a backup is added or pruned while the window is open, by the
    /// app, the CLI or an agent.
    @ObservationIgnored private var watcher: FolderWatcher?
    /// Counts the loads, so one that ends after a newer one does not put an older list back.
    @ObservationIgnored private var loads = 0

    init(app: AppModel) {
        self.app = app
    }

    var store: BackupStore { BackupStore(root: app.service.context.locations.backups) }
    var totalBytes: Int { items.reduce(0) { $0 + $1.entry.bytes } }
    var retentionDays: Int { EsclopSettings.backupRetentionDays.value(in: app.settings) }

    /// Reads the backups and the log off the main actor.
    func load() async {
        loads += 1
        let (store, log, load) = (store, app.service.results, loads)
        let read = await Task.detached(priority: .userInitiated) { Self.items(store.entries(), log: log) }.value
        guard load == loads else { return }
        items = read
        loaded = true
    }

    /// While the window is open. ponytail: each burst of events (0.3 s apart) reads every
    /// manifest and the log again, and a big batch with the window open overlaps loads (`loads`
    /// drops the stale ones). Skip a load while one runs, then run one more, if that shows.
    func watch() {
        let root = store.root
        _ = try? Paths.ensure(root)
        let watcher = FolderWatcher(everyChange: true) { [weak self] _ in
            Task { @MainActor in await self?.load() }
        }
        watcher.start([root])
        self.watcher = watcher
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    nonisolated static func items(_ entries: [BackupEntry], log: ResultsLog) -> [OriginalItem] {
        // ponytail: the whole log, once per load; it keeps eight days of results.
        let logged = Dictionary(log.recent(limit: .max).compactMap { result in result.backup.map { ($0.standardizedFileURL.path, result) } }, uniquingKeysWith: { newest, _ in newest })
        let cleared = log.savings().filter { $0.redacted == true }
        return entries.map { entry in
            if let result = logged[entry.backup.standardizedFileURL.path] {
                return OriginalItem(entry: entry, result: result, inPlace: isInPlace(entry))
            }
            let output = entry.output ?? entry.original
            let kind = MediaKind.of(entry.original) ?? .image
            // A backup with no output named (a file a template's output replaced) matches no
            // size, so what is there always goes to the Trash. ponytail: its restored card then
            // calls that file an edited version; give the no-output case its own words if
            // templates overwriting files get common.
            let bytesAfter = entry.output == nil ? -1 : AppModel.size(of: output)
            // After Recent › Clear the log keeps each result's sizes and time, not its name. The
            // backup is made before the encode, so its time would call the result an edit after
            // a long encode: the first cleared line since the backup with the same sizes judges
            // it instead. Its own line is one of those, so the time is never later than its own
            // finish, and anything changed after that still goes to the Trash.
            let line = cleared.filter { saving in
                saving.kind == kind && saving.bytesBefore == entry.bytes && saving.bytesAfter == bytesAfter
                    && saving.finishedAt >= entry.createdAt.addingTimeInterval(-2)
            }.map(\.finishedAt).min()
            // ponytail: the rebuilt result keeps the backup's id, never a line's (two files of one
            // size would swap them), so restoring it leaves the cleared line in the saving totals.
            let result = OptimisationResult(
                id: entry.id, source: entry.original, output: output, backup: entry.backup, kind: kind,
                bytesBefore: entry.bytes, bytesAfter: bytesAfter,
                startedAt: entry.createdAt, finishedAt: line ?? entry.createdAt,
                requestID: entry.requestID
            )
            return OriginalItem(entry: entry, result: result, inPlace: isInPlace(entry))
        }
    }

    /// The file at the original's path is the original again: its size, and no converted output
    /// beside it. ponytail: size only, as `holdsOutput` judges by size and date.
    nonisolated static func isInPlace(_ entry: BackupEntry) -> Bool {
        isInPlace(original: entry.original, bytes: entry.bytes, output: entry.output)
    }

    /// The same for a result: `AppModel.putBack` skips an original already back.
    nonisolated static func isInPlace(original: URL, bytes: Int, output: URL?) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: original.path), AppModel.size(of: original) == bytes else { return false }
        guard let output, output.standardizedFileURL != original.standardizedFileURL else { return true }
        return !fm.fileExists(atPath: output.path)
    }

    func restore(_ items: [OriginalItem]) async {
        var restored = false
        for item in items where !item.inPlace {
            if await app.restore(item.result) { restored = true }
        }
        if restored { await load() }
    }

    /// Deletes kept originals: they can no longer be restored. The ones that could not be
    /// deleted are named in `removalFailures`.
    func remove(_ items: [OriginalItem]) async {
        let (store, entries) = (store, items.map(\.entry))
        removalFailures = await Task.detached(priority: .userInitiated) {
            entries.compactMap { entry in
                do {
                    try store.delete(entry)
                    return nil
                } catch {
                    return entry.original.lastPathComponent
                }
            }
        }.value
        await load()
    }

    func removeAll() async { await remove(items) }

    func reveal(_ items: [OriginalItem]) {
        app.reveal(items.map(\.entry.backup))
    }

    /// The selected items, in the list's order.
    func items(_ ids: Set<OriginalItem.ID>) -> [OriginalItem] {
        items.filter { ids.contains($0.id) }
    }
}
