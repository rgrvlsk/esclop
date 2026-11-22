// SPDX-License-Identifier: GPL-3.0-or-later
//
// The menu bar panel (docs/design/targets: pr3-menu-panel): under the glyph, a cream panel with
// the day's saving, the batch at work, the recent results and the two commands. The gear holds
// the rest. Owner's decisions: no per-day history; the saving switches between today and the
// last 7 days, with the other under it; Recent has a quick Clear (privacy). Pausing has no
// state on the glyph: while it is on (the gear, ⌃⇧P, Settings, Shortcuts, the CLI), the panel
// says so in one line with Resume.

import AppKit
import EsclopCore
import EsclopIPC
import KeyboardShortcuts
import SwiftUI

/// What the panel's commands do outside the model: windows, the panel itself.
@MainActor
public struct MenuPanelActions {
    public var settings: () -> Void
    public var pipelines: () -> Void
    /// The Originals window: every original L'Esclop keeps.
    public var originals: (() -> Void)?
    public var welcome: (() -> Void)?
    public var checkForUpdates: (() -> Void)?
    public var quit: () -> Void
    /// Closes the panel, before a command that opens something else.
    public var close: () -> Void

    public init(
        settings: @escaping () -> Void, pipelines: @escaping () -> Void, originals: (() -> Void)? = nil, welcome: (() -> Void)?,
        checkForUpdates: (() -> Void)?, quit: @escaping () -> Void = { NSApp.terminate(nil) }, close: @escaping () -> Void
    ) {
        self.settings = settings
        self.pipelines = pipelines
        self.originals = originals
        self.welcome = welcome
        self.checkForUpdates = checkForUpdates
        self.quit = quit
        self.close = close
    }
}

/// Today, or today and the six days before.
public enum SavingRange: Hashable, Sendable {
    case today
    case week

    public func start(now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return self == .today ? today : calendar.date(byAdding: .day, value: -6, to: today) ?? today
    }
}

/// The sizes of the results in a range, from the shared log, cleared results included.
public struct SavingTotals: Equatable, Sendable {
    public var before = 0
    public var after = 0
    public var files = 0

    public var saved: Int { before - after }
    /// The part saved, for the arc; nil when nothing was saved.
    public var fraction: Double? { before > 0 && saved > 0 ? Double(saved) / Double(before) : nil }

    public static func of(_ savings: [ResultsLog.Saving], in range: SavingRange, now: Date, calendar: Calendar = .current) -> SavingTotals {
        let start = range.start(now: now, calendar: calendar)
        var totals = SavingTotals()
        for saving in savings where saving.finishedAt >= start {
            totals.before += saving.bytesBefore
            totals.after += saving.bytesAfter
            totals.files += 1
        }
        return totals
    }

    /// The log's savings once loaded. The log loads off the main actor, so until then Recent gives
    /// the figure: the panel never opens on "0 B" over results with savings.
    public static func savings(_ log: [ResultsLog.Saving]?, recent: [OptimisationResult]) -> [ResultsLog.Saving] {
        log ?? recent.map {
            ResultsLog.Saving(id: $0.id, kind: $0.kind, bytesBefore: $0.bytesBefore, bytesAfter: $0.bytesAfter, finishedAt: $0.finishedAt)
        }
    }
}

public struct MenuPanel: View {
    let model: AppModel
    let actions: MenuPanelActions
    /// The panel's x for the glyph's centre, where the notch goes.
    var notch: CGFloat?

    @State private var range: SavingRange = .today
    /// Nil until the log has loaded.
    @State private var savings: [ResultsLog.Saving]?
    @State private var option = false
    @State private var flags = ModifierFlagsWatcher()
    /// The row the arrows or the pointer are on, one at a time as in a menu: Return runs it.
    @State private var highlighted: Item?
    /// Where the pointer was at the last arrow key: a row the list scrolls under a pointer that
    /// did not move does not take the highlight, as in NSMenu.
    @State private var keyedAt: CGPoint?
    @FocusState private var listFocused: Bool

    public init(model: AppModel, actions: MenuPanelActions, notch: CGFloat? = nil) {
        self.model = model
        self.actions = actions
        self.notch = notch
    }

    /// Opens on a range and a row, for the renders.
    init(model: AppModel, actions: MenuPanelActions, notch: CGFloat?, range: SavingRange, highlighted: Item?) {
        self.init(model: model, actions: actions, notch: notch)
        _range = State(initialValue: range)
        _highlighted = State(initialValue: highlighted)
    }

    /// What the arrows move through, top to bottom: Resume, the batch tile, the recent results,
    /// then the two commands.
    enum Item: Hashable { case resume, batch, result(UUID), optimiseFiles, optimiseClipboard }

    public static let width: CGFloat = 316

    public var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 10) {
                header
                saved
                if model.paused { PausedLine(highlighted: highlighted == .resume, hover: { hover(.resume, $0) }, resume: resume) }
                if let batch = shownBatch { batchRow(batch) }
                recent
                commands
            }
            // The panel is one stop for the keys, as a menu is: the arrows move through Recent and
            // on into the commands, even with Recent empty; Return runs the row, Space is Quick
            // Look on a result (as on a card and in Finder). No focus ring; the row's wash shows
            // where it is.
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, proxy) }
            .onKeyPress(.upArrow) { move(-1, proxy) }
            .onKeyPress(.return) { open(results) }
            .onKeyPress(.space) { quickLook(results) }
        }
        .padding(12)
        .frame(width: Self.width)
        .background { MenuPanelSurface(notch: notch) }
        .padding(.top, MenuPanelSurface.notchHeight)
        // The week's saving, again whenever a result arrives or leaves, or the list is cleared.
        .task(id: model.recent.map(\.id)) { savings = await Self.loadSavings(model.service.results) }
        // The arrows work at once, as in a menu.
        .defaultFocus($listFocused, true)
        .onAppear { flags.start { option = $0.contains(.option) } }
        .onDisappear {
            flags.stop()
            // The next open starts with no row chosen, so Return runs nothing unseen.
            highlighted = nil
        }
    }

    static func loadSavings(_ log: ResultsLog) async -> [ResultsLog.Saving] {
        await Task.detached(priority: .userInitiated) { log.savings() }.value
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text(range == .today ? Strings.text("Today") : Strings.text("Last 7 days"))
                .font(Typeface.heading)
                .foregroundStyle(Ink.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Menu {
                // The panel stays open, so its "Paused · Resume" line shows what changed.
                Button(model.paused ? Strings.text("Resume L’Esclop") : Strings.text("Pause L’Esclop")) { model.togglePause() }
                    .globalKeyboardShortcut(.togglePause)
                Divider()
                Button(Strings.text("Settings…"), action: run(actions.settings)).keyboardShortcut(",")
                Button(Strings.text("Pipelines…"), action: run(actions.pipelines))
                if let originals = actions.originals {
                    Button(Strings.text("Originals…"), action: run(originals))
                }
                Button(Strings.text("Show Backups in Finder"), action: run { model.reveal([model.service.context.locations.backups]) })
                if let welcome = actions.welcome {
                    Button(Strings.text("Welcome to L’Esclop…"), action: run(welcome))
                }
                if let check = actions.checkForUpdates {
                    Button(Strings.text("Check for Updates…"), action: run(check))
                }
                Divider()
                Button(Strings.text("Quit L’Esclop"), action: actions.quit).keyboardShortcut("q")
            } label: {
                PillButton.face("gearshape", size: 30, glyph: 0.5)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Strings.text("Settings and more"))
            .accessibilityLabel(Strings.text("Settings and more"))
        }
        .padding(.horizontal, 4)
    }

    /// Closes the panel, then runs what opens a window, so the window comes up in front.
    private func run(_ action: @escaping () -> Void) -> () -> Void {
        { actions.close(); action() }
    }

    // MARK: Saved

    private var saved: some View {
        let all = SavingTotals.savings(savings, recent: model.recent)
        let shown = SavingTotals.of(all, in: range, now: model.now())
        let other = SavingTotals.of(all, in: range == .today ? .week : .today, now: model.now())
        return VStack(spacing: 6) {
            HStack {
                Text(Strings.text("Saved")).sectionLabel()
                Spacer()
                chip(Strings.text("Today"), .today)
                chip(Strings.text("7 days"), .week)
            }
            // The arc's ends sit over the two sizes, the figure between them, under the arc.
            VStack(spacing: 0) {
                SavingGauge(saved: shown.fraction, shape: .arc, lineWidth: 5)
                    .frame(width: Self.arcWidth, height: Self.arcHeight, alignment: .top)
                HStack(alignment: .lastTextBaseline) {
                    Text(Figures.bytes(shown.before)).font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.original)
                    Spacer(minLength: 4)
                    Figure(bytesSaved: Int64(max(shown.saved, 0)), size: .panel)
                    Spacer(minLength: 4)
                    Text(Figures.bytes(shown.after)).font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.secondary)
                }
                .monospacedDigit()
                .padding(.top, -4)
            }
            .frame(maxWidth: .infinity)
            Text(caption(other))
                .font(Typeface.caption)
                .foregroundStyle(Ink.secondary)
                .monospacedDigit()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(Surface.tile))
        // The chips stay buttons of their own for VoiceOver.
        .accessibilityElement(children: .contain)
    }

    static let arcWidth: CGFloat = 236
    /// Down to the arc's ends, which sit over the two sizes.
    static var arcHeight: CGFloat { SavingGauge.arcHeight(width: arcWidth, lineWidth: 5) }

    /// The other range, under the figure: "Last 7 days −19.6 GB", or "Today −2.8 GB".
    /// Nothing saved yet reads as such, never "−0 B".
    private func caption(_ other: SavingTotals) -> String {
        guard other.saved > 0 else {
            return range == .today ? Strings.text("Nothing saved in the last 7 days") : Strings.text("Nothing saved today")
        }
        let amount = Figures.bytes(other.saved)
        return range == .today
            ? Strings.format("Last 7 days −%@", amount)
            : Strings.format("Today −%@", amount)
    }

    private func chip(_ title: String, _ value: SavingRange) -> some View {
        let selected = range == value
        return Button { range = value } label: {
            Text(title)
                .font(Typeface.section)
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(selected ? AnyShapeStyle(Ink.onCharcoal) : AnyShapeStyle(Ink.text))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(selected ? Ink.charcoal : Surface.cream))
                .overlay(Capsule().strokeBorder(Ink.secondary.opacity(selected ? 0 : 0.25), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Batch

    /// The batch at work (aqua), or once it ends the last one, until the next: its window keeps
    /// Restore All and Retry after it was closed.
    private func batchRow(_ batch: Batch) -> some View {
        let running = batch.isRunning
        let info = BatchPresentation(batch: batch)
        return Button(action: showBatch) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    if running {
                        Text(Strings.text("Working")).sectionLabel()
                        Text(Strings.format("%d of %d", batch.finished, batch.total))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Ink.text)
                            .monospacedDigit()
                    } else {
                        Text(Strings.text("Last batch")).sectionLabel()
                        Spacer(minLength: 4)
                        if let percent = info.percent {
                            Text(percent)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Ink.saving)
                                .monospacedDigit()
                        }
                    }
                }
                if !running {
                    // "5 optimised · 1 failed": what is left to restore or retry there.
                    Text(info.counts)
                        .font(Typeface.caption)
                        .foregroundStyle(Ink.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                } else {
                    ProgressBar(fraction: batch.progress)
                    if let row = batch.rows.first(where: \.isRunning) {
                        Text(row.source.lastPathComponent)
                            .font(Typeface.caption)
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(running ? Surface.progress : Surface.tile))
            .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(Ink.text.opacity(highlighted == .batch ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover(.batch, $0) }
        .help(Strings.text("Show Batch Window"))
    }

    private var shownBatch: Batch? { model.batch.flatMap { $0.rows.isEmpty ? nil : $0 } }
    private func showBatch() { actions.close(); model.showBatch() }
    private func resume() { model.setPaused(false) }

    // MARK: Recent

    /// The recent results the panel lists.
    private var results: [OptimisationResult] { Array(model.recent.prefix(Self.recentLimit)) }

    /// Every file at work outside a batch, with its Stop: the cards', and those with no card.
    /// ponytail: the arrows skip these rows, so their Stop is the pointer's and VoiceOver's; add
    /// them to the arrows' rows if a keyboard-only person needs to stop a file with no card.
    private var working: [AppModel.WorkingFile] {
        model.cards.filter(\.isWorking).map { card in
            let fraction: Double = if case let .working(value) = card.phase { max(0, value) } else { 0 }
            return AppModel.WorkingFile(id: card.id, name: card.displayName ?? card.source.lastPathComponent, fraction: fraction) {
                model.perform(.stop, on: card)
            }
        } + model.cardlessWork
    }

    private var recent: some View {
        let working = working
        let results = results
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Strings.text("Recent")).sectionLabel()
                Spacer()
                if !results.isEmpty {
                    Button(Strings.text("Clear")) { model.clearRecent() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Ink.charcoalText)
                        .help(Strings.text("Forget these names. The saving stays; the files and their originals are not touched."))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            if results.isEmpty && working.isEmpty {
                Text(Strings.text("Copy a screenshot. You’ll find it here, lighter."))
                    .font(Typeface.caption)
                    .foregroundStyle(Ink.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            } else {
                let rows = VStack(spacing: 0) {
                    ForEach(working) { file in WorkingRow(file: file) }
                    ForEach(results, id: \.id) { result in
                        RecentRow(result: result, model: model, highlighted: highlighted == .result(result.id), close: actions.close) {
                            hover(.result(result.id), $0)
                        }
                            .id(result.id)
                    }
                }
                if working.count + results.count > Self.rowsShown {
                    ScrollView { rows }.frame(height: CGFloat(Self.rowsShown) * RecentRow.height)
                } else {
                    rows
                }
            }
        }
        .padding(.bottom, 6)
        .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(Surface.tile))
    }

    private func move(_ step: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let next = Self.item(after: highlighted, by: step, results: results.map(\.id), resume: model.paused, batch: shownBatch != nil)
        highlighted = next
        keyedAt = NSEvent.mouseLocation
        if case let .result(id) = next { proxy.scrollTo(id) }
        return .handled
    }

    /// The row an arrow moves to: Resume and the batch tile when shown, the recent results, then
    /// the two commands, stopping at either end; from no row, the first (down) or the last (up).
    static func item(after current: Item?, by step: Int, results: [UUID], resume: Bool = false, batch: Bool = false) -> Item {
        let items = (resume ? [Item.resume] : []) + (batch ? [Item.batch] : []) + results.map(Item.result) + [.optimiseFiles, .optimiseClipboard]
        let index = current.flatMap(items.firstIndex).map { min(max($0 + step, 0), items.count - 1) } ?? (step > 0 ? 0 : items.count - 1)
        return items[index]
    }

    private func open(_ results: [OptimisationResult]) -> KeyPress.Result {
        switch highlighted {
        case let .result(id):
            guard let result = results.first(where: { $0.id == id }) else { return .ignored }
            actions.close()
            model.show(result)
        case .resume: resume()
        case .batch: showBatch()
        case .optimiseFiles: optimiseFiles()
        case .optimiseClipboard: optimiseClipboard()
        case nil: return .ignored
        }
        return .handled
    }

    /// The pointer moves the highlight, as in NSMenu; leaving the row clears it.
    private func hover(_ item: Item, _ inside: Bool) {
        guard NSEvent.mouseLocation != keyedAt else { return }
        if inside { highlighted = item } else if highlighted == item { highlighted = nil }
    }

    private func optimiseFiles() { actions.close(); model.chooseFiles() }
    private func optimiseClipboard() { actions.close(); model.optimiseClipboardNow(aggressive: option) }

    private func quickLook(_ results: [OptimisationResult]) -> KeyPress.Result {
        guard case let .result(id) = highlighted,
              let result = results.first(where: { $0.id == id }),
              FileManager.default.fileExists(atPath: result.output.path) else { return .ignored }
        // Quick Look takes the keys, so the panel closes as it does for any other window.
        QuickLookPresenter.shared.toggle(result.output)
        return .handled
    }

    /// Restore and Compare reach this many results from the panel until All Results exists.
    static let recentLimit = 12
    static let rowsShown = 5

    // MARK: Commands

    private var commands: some View {
        VStack(spacing: 0) {
            CommandRow(title: Strings.text("Optimise Files…"), keys: "⌘O", highlighted: highlighted == .optimiseFiles, hover: { hover(.optimiseFiles, $0) }, action: optimiseFiles)
                .keyboardShortcut("o")
            Rectangle().fill(Ink.secondary.opacity(0.18)).frame(height: 0.5).padding(.horizontal, 14)
            // ⌥ turns it into the harder run, as its own hotkey does.
            CommandRow(
                title: option ? Strings.text("Optimise Clipboard Harder") : Strings.text("Optimise Clipboard"),
                keys: (option ? KeyboardShortcuts.getShortcut(for: .optimiseClipboardHarder) : KeyboardShortcuts.getShortcut(for: .optimiseClipboard))?.description ?? "",
                highlighted: highlighted == .optimiseClipboard, hover: { hover(.optimiseClipboard, $0) }, action: optimiseClipboard
            )
        }
        .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(Surface.tile))
    }
}

/// "Paused · Resume": automatic optimisation is off; Resume turns the setting off again.
struct PausedLine: View {
    /// The arrows are on it: Return resumes.
    var highlighted = false
    var hover: (Bool) -> Void = { _ in }
    let resume: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .accessibilityHidden(true)
            Text(Strings.text("Paused"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Ink.text)
            Text("·").foregroundStyle(Ink.secondary).accessibilityHidden(true)
            Button(Strings.text("Resume"), action: resume)
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Ink.charcoalText)
                .help(Strings.text("Turn automatic optimisation back on"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(Surface.tile))
        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(Ink.text.opacity(highlighted ? 0.06 : 0)).allowsHitTesting(false))
        .onHover(perform: hover)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.text("Paused"))
    }
}

/// A straight 4 pt bar: work in progress is never a ring.
struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.progress.opacity(0.22))
                Capsule().fill(Ink.progress).frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// A file being optimised now: its name, a bar, the percentage and Stop.
struct WorkingRow: View {
    let file: AppModel.WorkingFile

    var body: some View {
        let fraction = file.fraction
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    StateMark(meaning: .working).font(.system(size: 12, weight: .semibold))
                    Text(file.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Ink.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                ProgressBar(fraction: fraction)
            }
            Text(Strings.format("%d %%", Int((fraction * 100).rounded())))
                .font(.system(size: 13))
                .foregroundStyle(Ink.secondary)
                .monospacedDigit()
            // The original stays as it was, as the card's Stop leaves it.
            Button(action: file.stop) { PillButton.face("xmark", size: 28, glyph: 0.45) }
                .buttonStyle(PressScale())
                .help(Strings.text("Stop"))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .frame(height: RecentRow.height)
        .background(Surface.progress.opacity(0.7))
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Strings.text("Stop"), file.stop)
    }
}

/// One recent result: its picture, name, sizes and time, the saving; on hover Copy and Show in
/// Finder. A click, or Return on the row the arrows are on, shows its card again; the context
/// menu and VoiceOver's actions have the rest.
struct RecentRow: View {
    let result: OptimisationResult
    let model: AppModel
    /// The arrow keys or the pointer are on it.
    var highlighted = false
    let close: () -> Void
    /// Tells the panel the pointer came or went, so it moves the one highlight.
    var hover: (Bool) -> Void = { _ in }

    @State private var picture: CGImage?
    @State private var hovering = false

    static let height: CGFloat = 52
    /// Copy and Show in Finder, 28 pt each, 6 pt apart.
    static let toolsWidth: CGFloat = 62

    var body: some View {
        Button { close(); model.show(result) } label: {
            HStack(spacing: 10) {
                thumbnail
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.output.lastPathComponent)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Ink.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    (Text(Figures.bytes(result.bytesBefore)).foregroundStyle(Ink.original)
                        + Text(" → \(Figures.bytes(result.bytesAfter)) · \(result.finishedAt.formatted(date: .omitted, time: .shortened))").foregroundStyle(Ink.secondary))
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .monospacedDigit()
                }
                Spacer(minLength: 4)
                // Room for the hover buttons, which sit over the row, outside its button.
                if hovering { Color.clear.frame(width: Self.toolsWidth, height: 1) }
                figure
            }
            .padding(.horizontal, 14)
            .frame(height: Self.height)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.text.opacity(highlighted ? 0.06 : 0)).padding(.horizontal, 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if hovering {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        round("square.on.square", Strings.text("Copy"), action: copy)
                        round("folder", Strings.text("Show in Finder"), action: reveal)
                    }
                    figure.hidden()
                }
                .padding(.horizontal, 14)
                .transition(.opacity)
                // VoiceOver has them as the row's actions.
                .accessibilityHidden(true)
            }
        }
        .onHover { inside in
            withAnimation(Motion.hover) { hovering = inside }
            hover(inside)
        }
        .contextMenu {
            Button(Strings.text("Show in Finder"), action: reveal)
            Button(Strings.text("Copy"), action: copy)
            if comparable { Button(Strings.text("Compare"), action: compare) }
            if restorable { Button(Strings.text("Restore Original"), action: restore) }
        }
        .task(id: result.output) { picture = await Thumbnails.load(result.output, side: 64) }
        .accessibilityActions {
            Button(Strings.text("Show in Finder"), action: reveal)
            Button(Strings.text("Copy"), action: copy)
            if comparable { Button(Strings.text("Compare"), action: compare) }
            if restorable { Button(Strings.text("Restore Original"), action: restore) }
        }
    }

    private var figure: some View {
        Figure(percentSaved: Self.percent(result), size: .card, color: result.bytesAfter < result.bytesBefore ? AnyShapeStyle(Ink.saving) : AnyShapeStyle(Ink.secondary))
            .fixedSize()
    }

    private var comparable: Bool { result.backup != nil || result.output.standardizedFileURL != result.source.standardizedFileURL }
    private var restorable: Bool { model.restorable.contains { $0.id == result.id } }

    private func copy() { model.writeClipboard(files: [result.output]) }
    private func reveal() { close(); model.reveal([result.output]) }
    private func compare() { close(); model.onCompare?(result) }
    private func restore() { Task { await model.restore(result) } }

    static func percent(_ result: OptimisationResult) -> Int {
        guard result.bytesBefore > 0 else { return 0 }
        return Int((Double(result.bytesBefore - result.bytesAfter) / Double(result.bytesBefore) * 100).rounded())
    }

    private var thumbnail: some View {
        Group {
            if let picture {
                Image(decorative: picture, scale: 2).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: Picture.symbol(for: result.kind)).font(.system(size: 14)).foregroundStyle(Ink.secondary)
            }
        }
        .frame(width: 44, height: 36)
        .background(Rectangle().fill(NeutralFill.resting))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .pictureHairline(8)
        .accessibilityHidden(true)
    }

    private func round(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { PillButton.face(symbol, size: 28, glyph: 0.45) }
            .buttonStyle(PressScale())
            .help(title)
            .accessibilityLabel(title)
    }
}

/// A command with its keys at the end, as in a menu.
struct CommandRow: View {
    let title: String
    let keys: String
    /// The arrow keys or the pointer are on it.
    var highlighted = false
    var hover: (Bool) -> Void = { _ in }
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 14)).foregroundStyle(Ink.text)
                Spacer()
                Text(keys).font(.system(size: 13)).foregroundStyle(Ink.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.text.opacity(highlighted ? 0.06 : 0)).padding(.horizontal, 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: hover)
    }
}

/// The panel's surface: the cream material in a rounded rectangle, with a small notch at the top
/// pointing to the glyph.
struct MenuPanelSurface: View {
    var notch: CGFloat?

    static let notchHeight: CGFloat = 7
    static let radius: CGFloat = 22

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .floatingSurface(Self.radius)
                .overlay(alignment: .topLeading) {
                    if let notch {
                        Notch()
                            .fill(Surface.cream)
                            .frame(width: 18, height: Self.notchHeight + 1)
                            .offset(x: min(max(notch - 9, Self.radius), proxy.size.width - Self.radius - 18), y: -Self.notchHeight)
                    }
                }
        }
    }

    struct Notch: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY), control: CGPoint(x: rect.midX - 2, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX + 2, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }
}

/// Tells the panel whether ⌥ is down, for the commands' harder variant.
@MainActor
final class ModifierFlagsWatcher {
    private var monitor: Any?

    func start(_ changed: @escaping (NSEvent.ModifierFlags) -> Void) {
        stop()
        changed(NSEvent.modifierFlags)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            changed(event.modifierFlags)
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
