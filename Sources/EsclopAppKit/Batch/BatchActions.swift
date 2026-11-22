// SPDX-License-Identifier: GPL-3.0-or-later
//
// What the batch window does to the rows selected in it: optimise again with a format or a
// compression, crop to a shape, scale down, restore, try again. Each row runs again through its
// own Try again (`BatchRow.runAgain`), from its original, with the options popover's choices.

import EsclopCore
import EsclopIPC
import Foundation

extension AppModel {
    /// Runs the rows again from their originals, each with the change `change` gives for its
    /// original (the backup while a result stands; nil leaves that row as it is). A row's result
    /// is put back first, so nothing is compressed twice; a row whose restore fails keeps its
    /// result and says why. Rows at work are left alone. Returns how many `change` left as they
    /// were.
    @discardableResult
    public func rerun(_ rows: [BatchRow], _ change: @escaping (_ original: URL) async -> ((inout OptimisationJob) -> Void)?) async -> Int {
        var unchanged = 0
        for row in rows where row.isFinished {
            guard let change = await change(row.result?.backup ?? row.source) else {
                unchanged += 1
                continue
            }
            if case let .done(result) = row.state {
                if result.backup != nil {
                    await restore(row)
                    guard case .restored = row.state else { continue }
                } else {
                    // Written beside its original, which is untouched: the new result replaces
                    // this one in Recent and the saving, as a card's re-run does.
                    forget(result)
                    service.results.append([], withdrawing: [result], wait: false)
                }
            }
            row.runAgain?(change)
        }
        return unchanged
    }

    /// Optimise Again With: one of the options popover's formats for every row; the rest of how
    /// each ran stays.
    public func rerun(_ rows: [BatchRow], as format: OutputFormat) async {
        await rerun(rows) { _ in { $0.request.format = format } }
    }

    /// Optimise Again With: one of the popover's compressions for every row.
    public func rerun(_ rows: [BatchRow], compression: OptimiseChoice.Compression) async {
        await rerun(rows) { _ in { $0.request.quality = compression.quality } }
    }

    /// The card's Crop choices: a shape, at the file's own resolution.
    public func crop(_ rows: [BatchRow], to aspect: CropAspect) async {
        guard case let .ratio(width, height) = aspect else { return }
        await rerun(rows) { _ in { $0.request.crop = CropSize(aspectRatio: "\(width):\(height)") } }
    }

    /// The card's Downscale choices: a long side in pixels, or Half. A file the long side would
    /// not make smaller (the card does not offer it) stays as it is, and a notice counts those.
    public func downscale(_ rows: [BatchRow], longSide: Int?) async {
        let left = await rerun(rows) { original in
            let facts = await FileFacts.read(original)
            let long = Double(max(facts.width ?? 0, facts.height ?? 0))
            let factor = longSide.map { Double($0) / long } ?? 0.5
            guard factor < 1, OptionsModel.sizePresets(for: facts).contains(where: { $0.factor == factor }) else { return nil }
            return { $0.request.downscale = factor }
        }
        if left > 0 { notice(left == 1 ? Strings.text("1 left as it was") : Strings.format("%d left as they were", left), "") }
    }

    /// The batch footer's Retry All Failed.
    public func retryFailed(_ batch: Batch) {
        for row in batch.retriable { row.retry() }
    }
}
