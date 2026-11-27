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
    /// A row drawn as under the pointer: renders show the hover state.
    var hovered: UUID?
    /// A row drawn as the arrow keys' one, and a search typed: renders show those states.
    var ringed: UUID?
    var initialQuery = ""

    @State private var logged: [OptimisationResult] = []
    @State private var query = ""
    @State private var kind: MediaKind?
    /// The row the arrow keys are on.
    @State private var selected: UUID?
    @FocusState private var listFocused: Bool
    /// The list's content and the scroll view's heights: a legacy scroller shows at the right
    /// while the content is taller.
    @State private var contentHeight: CGFloat = 0
    @State private var viewHeight: CGFloat = 0
    /// When the window opened: its first focus is not the person's.
    @State private var entry = KeyboardEntry()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static let days = 7

    /// What makes the log worth reading again: a result arrived or went, or Clear forgot the names.
    struct ReloadKey: Equatable {
        let ids: [UUID]
        let clears: Int
    }

    /// What is on show: the week's results under the search and the kind, and the failures that
    /// match them too. A result restored in this session leaves at once, even one the log still
    /// had when read.
    private func onShow() -> (shown: [OptimisationResult], failed: [ResultCard], rows: [AllResults.Row]) {
        let week = AllResults.week(model.recent + logged, now: now()).filter { !model.isRestored($0) }
        let shown = AllResults.filter(week, kind: kind, query: query)
        let failed = model.failedCards.filter { AllResults.matches(name: $0.displayName ?? $0.source.lastPathComponent, kind: MediaKind.of($0.source), filter: kind, query: query) }
        return (shown, failed, AllResults.rows(shown, now: now()))
    }

    var body: some View {
        let (shown, failed, rows) = onShow()
        // The arrow keys walk the failures first, then the results.
        let order = failed.map(\.id) + rows.map(\.id)
        VStack(alignment: .leading, spacing: 20) {
            header
                .padding(.horizontal, Spacing.xl)
            SavedTile(results: shown, failed: failed.count, filtered: !query.isEmpty || kind != nil)
                .padding(.horizontal, Spacing.xl)
            if shown.isEmpty, failed.isEmpty {
                Spacer()
                VStack(spacing: Spacing.xs) {
                    Text(query.isEmpty && kind == nil
                        ? Strings.text("Nothing optimised in the last 7 days.")
                        : Strings.text("No results match."))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Ink.text)
                    // The way out, from what hides the results.
                    Text(query.isEmpty && kind == nil
                        ? Strings.text("Copy a screenshot or drop a file on the clog: its result shows here.")
                        : kind == nil ? Strings.text("Clear the search.")
                        : query.isEmpty ? Strings.text("Choose All.")
                        : Strings.text("Clear the search or choose All."))
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Spacing.xl)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // One lazy row per result, the group's label beside its first: a busy day
                        // does not build every row and thumbnail at once.
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if !failed.isEmpty { failures(failed) }
                            ForEach(rows) { row in
                                let first = row.id == rows.first?.id && failed.isEmpty
                                let today = Calendar.current.isDate(row.result.finishedAt, inSameDayAs: now())
                                HStack(alignment: .top, spacing: Spacing.l) {
                                    // Today's rows sit under their hour; an earlier day's say their
                                    // time in the column, under the day.
                                    // 12 pt between groups, 4 between the rows of one: the
                                    // ledger's steps under the page's 20.
                                    TimeColumn(
                                        label: row.label,
                                        time: today ? nil : row.result.finishedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: Strings.locale)),
                                        top: row.label != nil && !first ? Spacing.s : 0
                                    )
                                    AllResultsRow(result: row.result, model: model, selected: (selected == row.id && listFocused) || ringed == row.id, forcedHover: hovered == row.id) {
                                        // A click moves the arrow keys' place to the row.
                                        selected = row.id
                                    }
                                        .padding(.top, (row.label != nil && !first ? Spacing.s : 0) + 2)
                                        .padding(.bottom, 2)
                                        .id(row.id)
                                }
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        // The page's gutters inside the scroll view, so the rows keep the tile's
                        // edges and the scroller sits in the margin.
                        .padding(.leading, Spacing.xl + 2)
                        .padding(.trailing, Gutter.trailing(Spacing.xl, overflows: contentHeight > viewHeight + 1) + 2)
                        .padding(.bottom, Spacing.l)
                        .readsHeight($contentHeight)
                    }
                    .readsHeight($viewHeight)
                    .onChange(of: selected) { if let selected { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo(selected) } } }
                }
                // ↑ and ↓ move through the rows; Return shows the row's card.
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                // Tab into the list puts the ring on its first row on show; the window's own
                // first focus does not.
                .onChange(of: listFocused) {
                    guard listFocused, entry.settled else { return }
                    if let current = selected, order.contains(current) { return }
                    selected = order.first
                }
                .onMoveCommand { direction in
                    let step = direction == .up ? -1 : direction == .down ? 1 : 0
                    guard step != 0 else { return }
                    let index = selected.flatMap { order.firstIndex(of: $0) } ?? (step > 0 ? -1 : order.count)
                    if order.indices.contains(index + step) { selected = order[index + step] }
                }
                .background {
                    // ⌘C copies the row the arrow keys are on; ⌘R shows it in Finder.
                    Group {
                        Button("") { if let result = shown.first(where: { $0.id == selected }), listFocused { model.writeClipboard(files: [result.output]) } }
                            .keyboardShortcut("c", modifiers: .command)
                            .disabled(!listFocused || !shown.contains { $0.id == selected })
                        Button("") { if let result = shown.first(where: { $0.id == selected }), listFocused { model.reveal([result.output]) } }
                            .keyboardShortcut("r", modifiers: .command)
                            .disabled(!listFocused || !shown.contains { $0.id == selected })
                    }
                    .hidden()
                    .accessibilityHidden(true)
                }
                .onKeyPress(.return) {
                    guard let id = selected else { return .ignored }
                    if let result = shown.first(where: { $0.id == id }) {
                        model.show(result)
                    } else if let card = failed.first(where: { $0.id == id }), let action = FailureGroup.retry(for: card) {
                        // Return on a failure tries it again.
                        model.perform(action, on: card)
                    } else {
                        return .ignored
                    }
                    return .handled
                }
            }
        }
        .padding(.top, Spacing.s)
        .frame(minWidth: 720, idealWidth: 860, minHeight: 520, idealHeight: 760)
        .warmPage()
        .designTint()
        .onAppear {
            entry.appeared()
            if !initialQuery.isEmpty { query = initialQuery }
        }
        // The log holds the week; the app's own recent results add what came since. Read again
        // when a result arrives or goes.
        // Clear forgets the names at once, before the log is read again.
        .onChange(of: model.recentClears) { logged = [] }
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

    /// The heading, the search and the kinds: one row when they fit, two when not.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.l) {
                title
                Spacer(minLength: 0)
                WarmSearchField(text: $query, prompt: Strings.text("Search by name")) { enterList() }
                    .frame(minWidth: 150, idealWidth: 150, maxWidth: 220)
                kinds
            }
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(spacing: Spacing.l) {
                    title
                    Spacer(minLength: 0)
                    WarmSearchField(text: $query, prompt: Strings.text("Search by name")) { enterList() }
                        .frame(width: 220)
                }
                kinds
            }
        }
    }

    /// ↓ from the search: into the list, on its first row.
    private func enterList() {
        listFocused = true
        // The first row on show, failures first, as the arrows walk them; a row the search has
        // since hidden does not count.
        let (_, failed, rows) = onShow()
        let order = failed.map(\.id) + rows.map(\.id)
        if let current = selected, order.contains(current) { return }
        selected = order.first
    }

    private var title: some View {
        Text(Strings.text("All Results"))
            .font(.warmHeading(34))
            .foregroundStyle(Ink.text)
            .lineLimit(1)
            .fixedSize()
            .accessibilityAddTraits(.isHeader)
    }

    private var kinds: some View {
        HStack(spacing: 6) {
            chip(nil, Strings.text("All"))
            chip(.image, Strings.text("Images"))
            chip(.video, Strings.text("Video"))
            chip(.pdf, Strings.text("PDF"))
            chip(.audio, Strings.text("Audio"))
        }
        .fixedSize()
    }

    /// A kind: charcoal when chosen.
    private func chip(_ value: MediaKind?, _ title: String) -> some View {
        let on = kind == value
        return Button(title) { kind = value }
            .buttonStyle(ChoiceChipStyle(selected: on))
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    /// The failures still on screen, in amber, each with Retry when another try can help.
    private func failures(_ cards: [ResultCard]) -> some View {
        HStack(alignment: .top, spacing: Spacing.l) {
            TimeColumn(label: Strings.text("Errors"), top: 0)
            VStack(spacing: 4) {
                ForEach(cards) { card in
                    AllResultsFailureRow(card: card, retry: FailureGroup.retry(for: card), selected: selected == card.id && listFocused) { model.perform($0, on: card) }
                        .id(card.id)
                }
            }
            .padding(.vertical, 2)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The hours and days down the left, on one line: the group's label beside its first row, set
/// against the line; an earlier day's row adds its time.
struct TimeColumn: View {
    let label: String?
    /// The time, for an earlier day's row.
    var time: String?
    /// Room above a group's first row; the line runs through it.
    var top: CGFloat = 0

    var body: some View {
        // The hour or day on the row's name's baseline, an earlier day's time on its sizes'.
        VStack(alignment: .trailing, spacing: 4) {
            if let label {
                Text(label)
                    .font(.system(size: 14))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .accessibilityAddTraits(.isHeader)
            } else if time != nil {
                // A later row of the same day: the day's line stays, so its time keeps to the
                // sizes' line.
                Text(verbatim: " ").font(.system(size: 14)).hidden()
            }
            if let time {
                Text(time)
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.secondary)
            }
        }
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.trailing, 13)
        // "Wednesday 25" and "Divendres 20" on one line, at full size.
        .frame(width: 112, alignment: .trailing)
        .padding(.top, top + 18)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Ink.secondary.opacity(0.3)).frame(width: 1)
        }
        .accessibilityHidden(label == nil && time == nil)
    }
}

/// One result on a cream tile: its picture, name and sizes, the saving; under the pointer or the
/// keyboard, Copy, Show in Finder and a menu with Compare and Restore Original. A click shows
/// its card again; the context menu and VoiceOver's actions have every action.
struct AllResultsRow: View {
    let result: OptimisationResult
    let model: AppModel
    /// The arrow keys are on it.
    var selected = false
    /// Drawn as under the pointer, for renders.
    var forcedHover = false
    /// A click, before the card shows: the list's keyboard place follows it.
    var clicked: (() -> Void)?

    @State private var picture: CGImage?
    @State private var hovering = false

    static let height: CGFloat = 66

    private var lit: Bool { hovering || selected || forcedHover }

    var body: some View {
        Button {
            clicked?()
            model.show(result)
        } label: {
            HStack(spacing: 14) {
                thumbnail
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.output.lastPathComponent)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Ink.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    (Text(Figures.bytes(result.bytesBefore)).foregroundStyle(Ink.original)
                        + Text(" → \(Figures.bytes(result.bytesAfter))").foregroundStyle(Ink.secondary))
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .monospacedDigit()
                }
                Spacer(minLength: Spacing.s)
                // Room for the buttons, which sit over the row, outside its button.
                if lit { Color.clear.frame(width: Self.toolsWidth(menu: hasMenu), height: 1) }
                figure
            }
            .padding(.leading, 8)
            .padding(.trailing, Spacing.l + 2)
            .frame(height: Self.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The list is one stop for the keyboard; the arrows move inside it.
        .focusable(false)
        .warmTile(lit: lit && !selected, ring: selected)
        .overlay(alignment: .trailing) {
            if lit {
                HStack(spacing: 20) {
                    HStack(spacing: 12) {
                        round("square.on.square", Strings.text("Copy"), action: copy)
                        round("folder", Strings.text("Show in Finder"), action: reveal)
                        if hasMenu {
                            MoreMenu(size: Self.tool) {
                                if comparable { Button(Strings.text("Compare"), action: compare) }
                                if restorable { Button(Strings.text("Restore Original"), action: restore) }
                            }
                            // As the row's other tools: the list is the one keyboard stop.
                            .focusable(false)
                        }
                    }
                    figure.hidden()
                }
                .padding(.trailing, Spacing.l + 2)
                .transition(.opacity)
                // VoiceOver has them as the row's actions.
                .accessibilityHidden(true)
            }
        }
        .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
        .contextMenu { menuItems }
        .task(id: result.output) { picture = await Thumbnails.load(result.output, side: 128) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Strings.format(
            result.bytesAfter > result.bytesBefore ? "%@, %@ larger, %@ to %@" : "%@, %@ smaller, %@ to %@",
            result.output.lastPathComponent, (Double(abs(RecentRow.percent(result))) / 100).formatted(.percent.locale(Strings.locale)),
            Figures.bytes(result.bytesBefore), Figures.bytes(result.bytesAfter)
        ))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityActions { menuItems }
    }

    private var figure: some View {
        Figure(percentSaved: RecentRow.percent(result), size: .panel, color: result.bytesAfter < result.bytesBefore ? AnyShapeStyle(Ink.saving) : AnyShapeStyle(Ink.secondary))
            .fixedSize()
    }

    /// A hover button's side.
    static let tool: CGFloat = 38
    /// The buttons' width, and the 20 pt before the figure.
    static func toolsWidth(menu: Bool) -> CGFloat { (menu ? 3 * tool + 2 * 12 : 2 * tool + 12) + 20 - Spacing.s }

    @ViewBuilder private var menuItems: some View {
        Button(Strings.text("Copy"), action: copy)
            .keyboardShortcut("c", modifiers: .command)
        Button(Strings.text("Show in Finder"), action: reveal)
            .keyboardShortcut("r", modifiers: .command)
        if comparable { Button(Strings.text("Compare"), action: compare) }
        if restorable { Button(Strings.text("Restore Original"), action: restore) }
    }

    private var hasMenu: Bool { comparable || restorable }
    private var comparable: Bool { result.backup != nil || result.output.standardizedFileURL != result.source.standardizedFileURL }
    private var restorable: Bool { model.restorable.contains { $0.id == result.id } }

    private func copy() { model.writeClipboard(files: [result.output]) }
    private func reveal() { model.reveal([result.output]) }
    private func compare() { model.onCompare?(result) }
    private func restore() { Task { await model.restore(result) } }

    private var thumbnail: some View {
        ResultThumbnail(picture: picture, kind: result.kind)
    }

    private func round(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
        }
        .buttonStyle(RoundPillStyle(size: Self.tool))
        .focusable(false)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// A row's picture: the file's own, or its kind's symbol on the sunken cream; a video carries a
/// play mark.
struct ResultThumbnail: View {
    let picture: CGImage?
    let kind: MediaKind?
    var well: Color = Surface.sunken

    var body: some View {
        ZStack {
            if let picture {
                Image(decorative: picture, scale: 2).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: Picture.symbol(for: kind)).font(.system(size: 20)).foregroundStyle(Ink.secondary)
            }
            if kind == .video, picture != nil {
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.black.opacity(0.45)))
            }
        }
        .frame(width: 68, height: 50)
        .background(Rectangle().fill(well))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .pictureHairline(10)
        .accessibilityHidden(true)
    }
}

/// A failure still on screen: the same row as a result, in amber, with its reason and Retry when
/// another try can help.
struct AllResultsFailureRow: View {
    let card: ResultCard
    let retry: CardPresentation.Action?
    /// The arrow keys are on it: Return tries again.
    var selected = false
    let perform: (CardPresentation.Action) -> Void

    var body: some View {
        // Laid from the top as a one-line row is: the name on the "Errors" baseline, and a
        // reason on two lines makes the row grow down.
        HStack(alignment: .top, spacing: 14) {
            ResultThumbnail(picture: card.thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil), kind: MediaKind.of(card.source), well: Self.well)
                .padding(.vertical, 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(card.displayName ?? card.source.lastPathComponent)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Ink.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(reason)
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(reason)
            }
            .padding(.top, 15)
            .padding(.bottom, 14)
            Spacer(minLength: Spacing.s)
            if let action = retry {
                Button(CardFooter.retryTitle(action) ?? action.title) { perform(action) }
                    .buttonStyle(PillButtonStyle(decision: true))
                    .fixedSize()
                    .accessibilityLabel(action.accessibilityName)
                    .padding(.top, 18)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, Spacing.l + 2)
        .frame(minHeight: AllResultsRow.height)
        .warmTile(fill: Surface.warmDecision, ring: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The picture's well on amber: a deeper amber.
    static let well = Color(nsColor: Palette.dynamic(light: 0xF0CB8E, dark: 0x6A4C1E))

    /// The failure's own words; a file that is gone says so, since that is what stops a retry.
    private var reason: String {
        if card.failure == .optimise, !FileManager.default.fileExists(atPath: card.source.path) {
            return Strings.text("The file was moved or deleted.")
        }
        return card.failureMessage ?? ""
    }
}

/// "SAVED": the arc from the original size to the new one with the saving between them, and the
/// counts beside it. With nothing yet, the track alone, and no zeros.
struct SavedTile: View {
    let results: [OptimisationResult]
    let failed: Int
    /// A search or a kind hides results: nothing on show is not an empty week.
    var filtered = false

    var body: some View {
        let before = results.reduce(0) { $0 + $1.bytesBefore }
        let after = results.reduce(0) { $0 + $1.bytesAfter }
        let empty = results.isEmpty
        let converted = AllResults.converted(results)
        Group {
            if empty {
                // Nothing saved on show: the label and the track alone, the same margin above the
                // label as under the arc's ends; failures on show keep their count beside it.
                HStack(spacing: Spacing.xl) {
                    // A search or a kind that hides everything keeps the label where it was.
                    VStack(alignment: filtered ? .leading : .center, spacing: Spacing.m) {
                        Text(Strings.text("Saved · last 7 days")).warmLabel()
                        SavingGauge(saved: nil, shape: .arc, lineWidth: 7.5)
                            .frame(width: 250, height: 44)
                            .accessibilityHidden(true)
                    }
                    .padding(.bottom, 9)
                    // As tall as the tile with results, so nothing under it moves when a search
                    // finds nothing.
                    .frame(minHeight: 89)
                    if failed > 0 {
                        Rectangle().fill(Ink.secondary.opacity(0.3)).frame(width: 1, height: 56)
                        count(failed == 1 ? Strings.text("1 error") : Strings.format("%d errors", failed))
                            .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, alignment: filtered ? .leading : .center)
            } else {
                HStack(spacing: Spacing.xl) {
                    // The arc's top 12 pt under the label; the figures' foot as far from the
                    // tile's edge as the label's top.
                    VStack(alignment: .leading, spacing: 4) {
                        // One line at the narrowest window too.
                        Text(Strings.text("Saved · last 7 days")).warmLabel().fixedSize()
                        ZStack(alignment: .bottom) {
                            SavingGauge(saved: before > 0 && after < before ? 1 - Double(after) / Double(before) : nil, shape: .arc, lineWidth: 5)
                                .frame(width: 250, height: 44)
                                .padding(.bottom, 32)
                                .accessibilityHidden(true)
                            // The original size under the arc's left end, the new one under its
                            // right, the saving between them.
                            HStack(alignment: .lastTextBaseline, spacing: Spacing.s) {
                                Text(Figures.bytes(before)).foregroundStyle(Ink.original)
                                Spacer(minLength: 0)
                                Figure(bytesSaved: Int64(max(before - after, 0)), size: .window)
                                Spacer(minLength: 0)
                                Text(Figures.bytes(after)).foregroundStyle(Ink.secondary)
                            }
                            .lineLimit(1)
                            .font(.system(size: 16, weight: .medium))
                            .monospacedDigit()
                            .frame(width: 300)
                        }
                        .frame(width: 300, height: 77, alignment: .bottom)
                    }
                    .padding(.bottom, -5)
                    Rectangle().fill(Ink.secondary.opacity(0.3)).frame(width: 1, height: 76)
                    // The counts spread over the rest of the tile; a count of nothing stays out.
                    // The same space between the counts as from the rule to the first and from
                    // the last to the tile's edge, at every width: the row spans that whole width.
                    HStack(spacing: 0) {
                        Spacer(minLength: 12)
                        count(AllResults.filesCount(results.count))
                        if converted > 0 {
                            Spacer(minLength: 12)
                            count(converted == 1 ? Strings.text("1 converted") : Strings.format("%d converted", converted))
                        }
                        if failed > 0 {
                            Spacer(minLength: 12)
                            count(failed == 1 ? Strings.text("1 error") : Strings.format("%d errors", failed))
                        }
                        Spacer(minLength: 12)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.leading, -Spacing.xl)
                    .padding(.trailing, -(Spacing.xl - 4))
                }
            }
        }
        .padding(.horizontal, Spacing.xl - 4)
        .padding(.vertical, 15)
        .warmTile(22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(empty
            ? (filtered ? Strings.text("Saved: no result on show") : Strings.text("Saved: nothing yet"))
            : Strings.format("Saved %@ in the last 7 days, from %@ to %@", Figure.byteParts(Int64(max(before - after, 0))).text, Figures.bytes(before), Figures.bytes(after)))
        .accessibilityValue([
            empty ? nil : AllResults.filesCount(results.count),
            converted > 0 ? (converted == 1 ? Strings.text("1 converted") : Strings.format("%d converted", converted)) : nil,
            failed > 0 ? (failed == 1 ? Strings.text("1 error") : Strings.format("%d errors", failed)) : nil,
        ].compactMap { $0 }.joined(separator: ", "))
    }

    private func count(_ text: String) -> some View {
        // At the narrowest window a long count shrinks a little rather than leave the tile.
        Text(text).font(.system(size: 20)).monospacedDigit().foregroundStyle(Ink.secondary).lineLimit(1).minimumScaleFactor(0.7)
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
        results.filter { matches(name: $0.output.lastPathComponent, kind: $0.kind, filter: kind, query: query) }
    }

    static func matches(name: String, kind: MediaKind?, filter: MediaKind?, query: String) -> Bool {
        guard filter == nil || kind == filter else { return false }
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).split(separator: " ").allSatisfy { folded.contains($0) }
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
            // The hour's start in the Mac's own time format, as each row's time is ("14:00", "2 PM").
            let hour = calendar.dateInterval(of: .hour, for: date)?.start ?? date
            return hour.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: Strings.locale, calendar: calendar))
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return Strings.text("Yesterday")
        }
        // "Dilluns 23": a day's name starts with a capital, as "Ahir" does.
        let day = date.formatted(.dateTime.weekday(.wide).day().locale(Strings.locale))
        return day.prefix(1).uppercased(with: Strings.locale) + day.dropFirst()
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
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.title = Strings.text("All Results")
        // The heading says it in New York; the title stays for the Window menu and VoiceOver.
        window.titleVisibility = .hidden
        window.dressWarm()
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

/// A round white pill with a symbol: the row's hover buttons, lighter than the tile in both
/// appearances.
struct RoundPillStyle: ButtonStyle {
    var size: CGFloat = 38

    func makeBody(configuration: Configuration) -> some View {
        RoundPillFace(label: configuration.label, size: size, pressed: configuration.isPressed)
    }
}

private struct RoundPillFace<Label: View>: View {
    let label: Label
    let size: CGFloat
    let pressed: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let dark = scheme == .dark
        label
            .foregroundStyle(Ink.text)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(dark ? Color.white.opacity(0.14) : Color.white)
                    .overlay(Circle().strokeBorder(contrast == .increased ? Color(nsColor: .labelColor) : (dark ? Color.white.opacity(0.1) : Color.black.opacity(0.06)), lineWidth: contrast == .increased ? 1 : 0.5))
                    .shadow(color: .black.opacity(dark ? 0.35 : 0.12), radius: 1.5, y: 1)
            }
            .contentShape(Circle())
            .contentShape(.focusEffect, Circle())
            .scaleEffect(pressed ? 0.95 : 1)
    }
}
