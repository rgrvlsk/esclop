// SPDX-License-Identifier: GPL-3.0-or-later
//
// What the batch window says, as plain values: the title, the aggregate saving, the counts and
// each row's status. Kept apart from the view so the wording and the arithmetic are tested
// without drawing.

import EsclopCore
import Foundation

@MainActor
public struct BatchPresentation: Equatable {
    /// "Optimising 8 of 12 files", "Paused at 8 of 12 files", "12 files optimised".
    public var title: String
    /// "48 MB → 12 MB", or nothing before the first file finishes.
    public var change: String?
    /// "−75 %": the one large figure.
    public var percent: String?
    /// Where the aggregate bar ends, as a fraction of the originals.
    public var barEnd: Double
    public var progress: Double?
    /// Nothing is saved any more (all restored, or stopped): the bar stays a neutral track
    /// rather than a full green bar, which reads as success.
    public var barIsNeutral = false
    /// "10 optimised · 1 already optimised · 1 failed"
    public var counts: String
    public var announcement: String

    public init(batch: Batch, locale: Locale = Strings.locale) {
        func t(_ key: String) -> String { Strings.text(key, locale: locale) }
        func f(_ key: String, _ arguments: any CVarArg...) -> String { String(format: t(key), locale: locale, arguments: arguments) }
        /// "1 restored" or "3 restored": Catalan, like English, has one form for one and one for the rest.
        func count(_ number: Int, one: String, other: String) -> String { number == 1 ? t(one) : f(other, number) }
        let before = batch.bytesBefore, after = batch.bytesAfter
        if batch.isRunning {
            title = batch.paused
                ? f("Paused at %d of %d files", batch.finished, batch.total)
                : f("Optimising %d of %d files", min(batch.total, batch.finished + 1), batch.total)
            progress = batch.progress
        } else {
            if batch.optimised == batch.total {
                title = batch.total == 1 ? t("1 file optimised") : f("%d files optimised", batch.total)
            } else if batch.optimised == 0, batch.restored > 0 {
                // Say what happened, not "0 of 6 files optimised".
                title = batch.restored == 1 ? t("1 original restored") : f("%d originals restored", batch.restored)
            } else if batch.optimised == 0, batch.cancelled > 0 {
                title = batch.total == 1 ? t("Stopped: 1 original kept") : f("Stopped: %d originals kept", batch.total)
            } else {
                title = f("%d of %d files optimised", batch.optimised, batch.total)
            }
            progress = nil
        }
        let saved = before > 0 && !Figures.isNoSaving(before: before, after: after)
        barIsNeutral = !batch.isRunning && !saved
        change = saved ? Figures.change(before: before, after: after, locale: locale) : nil
        percent = before > 0 && !Figures.isNoSaving(before: before, after: after) ? Figures.percent(before: before, after: after, locale: locale) : nil
        barEnd = before > 0 ? min(1, max(0, Double(after) / Double(before))) : 1
        var parts: [String] = []
        if batch.optimised > 0 { parts.append(count(batch.optimised, one: "1 optimised", other: "%d optimised")) }
        if batch.unchanged > 0 { parts.append(count(batch.unchanged, one: "1 already optimised", other: "%d already optimised")) }
        if batch.failed > 0 { parts.append(count(batch.failed, one: "1 failed", other: "%d failed")) }
        if batch.cancelled > 0 { parts.append(count(batch.cancelled, one: "1 stopped", other: "%d stopped")) }
        if batch.restored > 0 { parts.append(count(batch.restored, one: "1 restored", other: "%d restored")) }
        let waiting = batch.total - batch.finished
        if waiting > 0 { parts.append(count(waiting, one: "1 to go", other: "%d to go")) }
        counts = parts.joined(separator: " · ")
        let savedBytes = Figures.bytes(max(0, before - after), locale: locale)
        announcement = batch.total == 1 ? f("Batch finished: 1 file, %@ saved", savedBytes) : f("Batch finished: %d files, %@ saved", batch.total, savedBytes)
    }

    /// A row's status line: "2.4 MB → 612 kB", "Waiting", "Optimising 40 %", the error.
    public static func status(of row: BatchRow, locale: Locale = Strings.locale) -> String {
        func t(_ key: String) -> String { Strings.text(key, locale: locale) }
        switch row.state {
        case .waiting: return t("Waiting")
        case let .working(fraction):
            return fraction > 0 ? String(format: t("Optimising %d %%"), locale: locale, Int((fraction * 100).rounded())).replacingOccurrences(of: " %", with: Figures.space + "%") : t("Optimising…")
        case let .done(result):
            // An automatic upload says how it goes; the saving stays in the figure.
            switch row.upload {
            case let .uploading(fraction):
                return String(format: t("Uploading… %d %%"), locale: locale, Int((min(1, max(0, fraction)) * 100).rounded()))
                    .replacingOccurrences(of: " %", with: Figures.space + "%")
            case .uploaded: return t("Uploaded · link copied")
            // ponytail: a row has no Upload Again; its Share tab or a card has. Add one when batch
            // uploads fail often enough to matter.
            case let .failed(message): return t("Not uploaded") + " · " + message
            case nil: break
            }
            if Figures.isNoSaving(before: result.bytesBefore, after: result.bytesAfter) {
                return String(format: t("Already optimised · %@"), locale: locale, Figures.bytes(result.bytesAfter, locale: locale))
            }
            return Figures.change(before: result.bytesBefore, after: result.bytesAfter, locale: locale)
        case .unchanged: return String(format: t("Already optimised · %@"), locale: locale, Figures.bytes(row.bytesBefore, locale: locale))
        case let .failed(message): return message
        case .cancelled: return t("Stopped, original kept")
        case let .restored(result): return String(format: t("Original restored · %@"), locale: locale, Figures.bytes(result.bytesBefore, locale: locale))
        }
    }

    /// The figure at the end of a row: "−75 %", or nothing.
    public static func figure(of row: BatchRow, locale: Locale = Strings.locale) -> String? {
        guard let result = row.result, !Figures.isNoSaving(before: result.bytesBefore, after: result.bytesAfter) else { return nil }
        return Figures.percent(before: result.bytesBefore, after: result.bytesAfter, locale: locale)
    }
}
