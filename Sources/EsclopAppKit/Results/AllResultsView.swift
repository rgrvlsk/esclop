// SPDX-License-Identifier: GPL-3.0-or-later
//
// All Results (`pr6-results-window`): every result of the last seven days in one window, newest
// first. Today is grouped by hour and the days before by day. The window is searchable and
// filters by kind. Its heading tile has the week's saving, from the original size to the new
// one, and the counts. Failures still on screen come first, in amber, with Retry. Each row is the
// menu panel's Recent row: Copy and Show in Finder on hover; Compare and Restore Original in its
// context menu and as VoiceOver actions; a click shows its card.

import AppKit
import EsclopCore
import EsclopIPC
import SwiftUI

struct AllResultsView: View {
    let model: AppModel
    /// The clock the groups and the seven days are measured against; renders fix it.
    var now: () -> Date = Date.init

    @State private var logged: [OptimisationResult] = []
    @State private var query = ""
    @State private var kind: MediaKind?

    nonisolated static let days = 7

    /// What makes the log worth reading again: a result arrived or went, or Clear forgot the names.
    struct ReloadKey: Equatable {
        let ids: [UUID]
        let clears: Int
    }

    var body: some View {
        // A result restored in this session leaves at once, even one the log still had when read.
        let week = AllResults.week(model.recent + logged, now: now()).filter { !model.isRestored($0) }
        let shown = AllResults.filter(week, kind: kind, query: query)
        VStack(alignment: .leading, spacing: Spacing.l) {
            header
            SavedTile(results: shown, failed: model.failedCards.count)
            if shown.isEmpty, model.failedCards.isEmpty {
                Spacer()
                Text(query.isEmpty && kind == nil
                    ? Strings.text("Nothing optimised in the last 7 days.")
                    : Strings.text("No result matches."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    // One lazy row per result, the group's label beside its first: a busy day does
                    // not build every row and thumbnail at once.
                    LazyVStack(alignment: .leading, spacing: Spacing.xs) {
                        if !model.failedCards.isEmpty { failures.padding(.bottom, Spacing.s) }
                        ForEach(AllResults.rows(shown, now: now())) { row in
                            HStack(alignment: .top, spacing: Spacing.m) {
                                Text(row.label ?? "")
                                    .font(Typeface.body)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 76, alignment: .leading)
                                    .padding(.top, 16)
                                    .accessibilityHidden(row.label == nil)
                                    .accessibilityAddTraits(.isHeader)
                                RecentRow(result: row.result, model: model, close: {})
                                    .background(RoundedRectangle(cornerRadius: Radius.tile / 1.5, style: .continuous).fill(Surface.tile))
                            }
                            .padding(.top, row.label != nil && row.id != shown.first?.id ? Spacing.s : 0)
                        }
                    }
                    .padding(.bottom, Spacing.l)
                }
            }
        }
        .padding(Spacing.xl)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 520, idealHeight: 720)
        .designTint()
        // The log holds the week; the app's own recent results add what came since. Read again
        // when a result arrives or goes.
        .task(id: ReloadKey(ids: model.recent.map(\.id), clears: model.recentClears)) {
            // A batch changes the list many times a second: read once it settles.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let log = model.service.results
            let read = await Task.detached(priority: .userInitiated) { log.recent(limit: AllResults.logLimit) }.value
            // A newer read may have started: an older one must not put a withdrawn result back.
            guard !Task.isCancelled else { return }
            logged = read
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.l) {
                Text(Strings.text("All Results"))
                    .font(Typeface.heading)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                HStack(spacing: Spacing.s) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField(Strings.text("Search"), text: $query, prompt: Text(Strings.text("Search by name")))
                        .textFieldStyle(.plain)
                        .frame(width: 180)
                }
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, 6)
                .background(Capsule().fill(Surface.recessed))
            }
            HStack(spacing: Spacing.s) {
                chip(nil, Strings.text("All"))
                chip(.image, Strings.text("Images"))
                chip(.video, Strings.text("Video"))
                chip(.pdf, Strings.text("PDF"))
                chip(.audio, Strings.text("Audio"))
            }
        }
    }

    /// A kind: charcoal when chosen.
    private func chip(_ value: MediaKind?, _ title: String) -> some View {
        let on = kind == value
        return Button { kind = value } label: {
            Text(title)
                .font(Typeface.label)
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, 5)
                .foregroundStyle(on ? AnyShapeStyle(Ink.onCharcoal) : AnyShapeStyle(Ink.text))
                .background(Capsule().fill(on ? AnyShapeStyle(Ink.charcoal) : AnyShapeStyle(Surface.tile)))
                .overlay(Capsule().strokeBorder(Ink.secondary.opacity(on ? 0 : 0.3), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    /// The failures still on screen, in amber, each with Retry when another try can help.
    private var failures: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Text(Strings.text("Failed"))
                .font(Typeface.body)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: Spacing.xs) {
                ForEach(model.failedCards) { card in
                    FailureRow(card: card, retry: FailureGroup.retry(for: card)) { model.perform($0, on: card) }
                        .padding(.horizontal, Spacing.m)
                        .background(RoundedRectangle(cornerRadius: Radius.tile / 1.5, style: .continuous).fill(Surface.decision))
                }
            }
        }
    }
}

/// "SAVED": the arc from the original size to the new one with the saving between them, and the
/// counts beside it.
struct SavedTile: View {
    let results: [OptimisationResult]
    let failed: Int

    var body: some View {
        let before = results.reduce(0) { $0 + $1.bytesBefore }
        let after = results.reduce(0) { $0 + $1.bytesAfter }
        HStack(spacing: Spacing.xl) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(Strings.text("Saved")).sectionLabel()
                SavingGauge(saved: before > 0 && after < before ? 1 - Double(after) / Double(before) : nil, shape: .arc, lineWidth: 4)
                    .frame(width: 240, height: 30)
                    .padding(.bottom, Spacing.xs)
                    .accessibilityHidden(true)
                // The original size under the arc's left end, the new one under its right.
                HStack(alignment: .lastTextBaseline, spacing: Spacing.m) {
                    Text(Figures.bytes(before)).foregroundStyle(Ink.original)
                    Spacer(minLength: 0)
                    Figure(bytesSaved: Int64(max(before - after, 0)), size: .panel)
                    Spacer(minLength: 0)
                    Text(Figures.bytes(after)).foregroundStyle(Ink.secondary)
                }
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 240)
                .font(.title3.weight(.medium))
                .monospacedDigit()
            }
            Divider().frame(height: 64)
            HStack(spacing: Spacing.xl) {
                count(AllResults.filesCount(results.count))
                count(Strings.format("%d converted", AllResults.converted(results)))
                if failed > 0 { count(Strings.format("%d failed", failed)) }
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.l)
        .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(Surface.tile))
        .accessibilityElement(children: .combine)
    }

    private func count(_ text: String) -> some View {
        Text(text).font(.title3).monospacedDigit().foregroundStyle(Ink.secondary).lineLimit(1).fixedSize()
    }
}

/// The week's results, grouped, filtered and counted: plain values, so tests check them.
enum AllResults {
    /// The log keeps every result of the last eight days; this reads more than a busy week holds.
    static let logLimit = 2000

    /// The app's results and the log's, each once, newest first, from the last seven days.
    static func week(_ results: [OptimisationResult], now: Date, calendar: Calendar = .current) -> [OptimisationResult] {
        let start = calendar.date(byAdding: .day, value: -(AllResultsView.days - 1), to: calendar.startOfDay(for: now)) ?? now
        var seen = Set<UUID>()
        return results
            .filter { $0.finishedAt >= start && seen.insert($0.id).inserted }
            .sorted { $0.finishedAt > $1.finishedAt }
    }

    /// The results of one kind (all when nil) whose name holds the query, accents and case folded.
    static func filter(_ results: [OptimisationResult], kind: MediaKind?, query: String) -> [OptimisationResult] {
        let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).split(separator: " ")
        return results.filter { result in
            guard kind == nil || result.kind == kind else { return false }
            let name = result.output.lastPathComponent.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return words.allSatisfy { name.contains($0) }
        }
    }

    /// A result is converted when its file changed format.
    static func converted(_ results: [OptimisationResult]) -> Int {
        results.filter { $0.source.pathExtension.lowercased() != $0.output.pathExtension.lowercased() }.count
    }

    static func filesCount(_ count: Int) -> String {
        count == 1 ? Strings.text("1 file") : Strings.format("%d files", count)
    }

    struct Group: Identifiable {
        let label: String
        let results: [OptimisationResult]
        var id: String { label }
    }

    /// One row per result, with its group's label on the group's first row only.
    struct Row: Identifiable {
        let label: String?
        let result: OptimisationResult
        var id: UUID { result.id }
    }

    static func rows(_ results: [OptimisationResult], now: Date, calendar: Calendar = .current) -> [Row] {
        groups(results, now: now, calendar: calendar).flatMap { group in
            group.results.enumerated().map { Row(label: $0.offset == 0 ? group.label : nil, result: $0.element) }
        }
    }

    /// Today by hour ("09:00"), the days before by day ("Yesterday", "Monday 23"), newest first.
    static func groups(_ results: [OptimisationResult], now: Date, calendar: Calendar = .current) -> [Group] {
        var groups: [Group] = []
        for result in results {
            let label = Self.label(for: result.finishedAt, now: now, calendar: calendar)
            if let last = groups.last, last.label == label {
                groups[groups.count - 1] = Group(label: label, results: last.results + [result])
            } else {
                groups.append(Group(label: label, results: [result]))
            }
        }
        return groups
    }

    static func label(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            let hour = calendar.component(.hour, from: date)
            return String(format: "%02d:00", hour)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return Strings.text("Yesterday")
        }
        return date.formatted(.dateTime.weekday(.wide).day().locale(Strings.locale))
    }
}

/// One All Results window, reused.
@MainActor
final class AllResultsWindowController {
    let model: AppModel
    private var window: NSWindow?
    private var closing: (any NSObjectProtocol)?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        if window.contentView == nil {
            window.contentView = NSHostingView(rootView: AllResultsView(model: model))
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.title = Strings.text("All Results")
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("dev.esclop.all-results")
        // A closed window's view would keep reading the log on every result: it goes with it.
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { [weak window] _ in
            MainActor.assumeIsolated { window?.contentView = nil }
        }
        return window
    }
}
