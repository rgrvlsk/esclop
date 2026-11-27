// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Settings window: a sidebar of panes with the search at its top, and the chosen pane as a
// grouped form. While a search is typed, the sidebar lists the matching settings across every
// pane; picking one opens its pane and marks the row.

import EsclopCore
import EsclopIPC
import SwiftUI

public struct SettingsView: View {
    @Bindable var model: SettingsViewModel
    let agents: AgentsModel?
    let actions: SettingsActions

    public init(model: SettingsViewModel, agents: AgentsModel? = nil, actions: SettingsActions = SettingsActions()) {
        self.model = model
        self.agents = agents
        self.actions = actions
    }

    public var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(model: model)
                .frame(width: 216)
                .background(Surface.sidebar.ignoresSafeArea())
            SettingsPaneView(pane: model.pane, model: model, agents: agents, actions: actions)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .warmPage()
        // The pane's heading names it; the window keeps the title for the Window menu and
        // VoiceOver.
        .navigationTitle(model.pane.title)
        .frame(minWidth: 720, idealWidth: 780, minHeight: 480, idealHeight: 600)
        .designTint()
    }
}

/// What the panes can ask of the app, so the views stay free of AppKit side effects in tests.
public struct SettingsActions {
    public var reveal: @MainActor (URL) -> Void
    public var copy: @MainActor (String) -> Void
    /// L'Esclop's data folder (pipelines, backups, logs), for the Advanced pane.
    public var supportFolder: URL?
    /// Opens the pipeline editor (the Advanced pane's Pipelines row).
    public var openPipelines: (@MainActor () -> Void)?
    /// The settings General's Export… and Import… carry (`SettingsFile`).
    public var settingsStore: SettingsStore?

    public init(
        reveal: @escaping @MainActor (URL) -> Void = { _ in }, copy: @escaping @MainActor (String) -> Void = { _ in },
        supportFolder: URL? = nil, openPipelines: (@MainActor () -> Void)? = nil, settingsStore: SettingsStore? = nil
    ) {
        self.reveal = reveal
        self.copy = copy
        self.supportFolder = supportFolder
        self.openPipelines = openPipelines
        self.settingsStore = settingsStore
    }
}

/// The panes, as warm rows under a search field. While a search is typed, the matching settings
/// across every pane; picking one opens its pane and marks the row. ↑ and ↓ move through the
/// list, Return opens a found setting, ↓ from the search field goes into the list.
struct SettingsSidebar: View {
    @Bindable var model: SettingsViewModel
    @State private var hit: String?
    @FocusState private var listFocused: Bool
    /// The keyboard came to the list (Tab, ↓, an arrow): its ring shows until a click.
    @State private var keyboardMoved = false
    /// When the window opened: its first focus is not the person's.
    @State private var entry = KeyboardEntry()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            WarmSearchField(text: $model.query, prompt: Strings.text("Search settings")) {
                listFocused = true
                keyboardMoved = true
                if hit == nil { hit = model.hits.first?.id }
            }
            // Return in the field opens the marked setting: the first found, unless one is chosen.
            .onSubmit {
                guard let found = model.hits.first(where: { $0.id == hit }) ?? model.hits.first else { return }
                hit = found.id
                model.open(found)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    list
                }
                .scrollIndicators(.never)
                .onChange(of: hit) { if let hit { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo(hit) } } }
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            // Tab into the list shows the ring, and in a search chooses the first found setting;
            // the window's own first focus does neither.
            .onChange(of: listFocused) {
                guard listFocused, entry.settled else { return }
                keyboardMoved = true
                if searching, hit == nil { hit = model.hits.first?.id }
            }
            // The window opens on the list, which draws no ring until the person moves: the
            // search field's ring waits for a click or ⌘F.
            .onAppear {
                entry.appeared()
                listFocused = true
            }
            .onMoveCommand(perform: move)
            .onKeyPress(.return) {
                guard let id = hit, let found = model.hits.first(where: { $0.id == id }) else { return .ignored }
                model.open(found)
                return .handled
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.top, Spacing.xs)
        .onChange(of: model.query) { hit = nil }
        .background {
            // ⌘1 to ⌘7 open the panes as they are listed, from a search too.
            ForEach(Array(SettingsPane.allCases.prefix(9).enumerated()), id: \.element) { index, pane in
                Button("") {
                    model.query = ""
                    keyboardMoved = false
                    model.pane = pane
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
            }
        }
    }

    private var searching: Bool { !model.query.trimmingCharacters(in: .whitespaces).isEmpty }

    @ViewBuilder private var list: some View {
        if !searching {
            VStack(spacing: 2) {
                ForEach(Array(SettingsPane.allCases.enumerated()), id: \.element) { index, pane in
                    let selected = model.pane == pane
                    Button {
                        keyboardMoved = false
                        model.pane = pane
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: pane.symbol)
                                .font(.system(size: 15))
                                .foregroundStyle(Ink.charcoalText)
                                .frame(width: 22)
                                .accessibilityHidden(true)
                            Text(pane.title)
                            Spacer(minLength: 4)
                            if needsAttention(pane) {
                                // A folder in it needs a decision: the amber sign its panel shows.
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Ink.warm)
                                    .help(Strings.text("Needs attention"))
                                    .accessibilityHidden(true)
                            } else if let changed = changed(in: pane) {
                                // Settings here differ from their defaults: the dot the panels'
                                // index uses, the count in its help.
                                Circle().fill(Ink.text.opacity(0.55)).frame(width: 5, height: 5)
                                    .help(changed == 1 ? Strings.text("1 setting changed") : Strings.format("%d settings changed", changed))
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .buttonStyle(SidebarRowStyle(selected: selected, focused: listFocused && keyboardMoved))
                    // The list is the one keyboard stop; the arrows move inside it.
                    .focusable(false)
                    .help(Strings.format("%@ (⌘%d)", pane.title, index + 1))
                    .accessibilityLabel(pane.title)
                    .accessibilityValue(([Strings.format("%d of %d", index + 1, SettingsPane.allCases.count)] + [needsAttention(pane) ? Strings.text("Needs attention") : nil, changed(in: pane).map { $0 == 1 ? Strings.text("1 setting changed") : Strings.format("%d settings changed", $0) }].compactMap { $0 }).joined(separator: ", "))
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .padding(.vertical, 2)
        } else {
            let hits = model.hits
            if hits.isEmpty {
                // In the sidebar's own type and inks, not the system's grey.
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(Strings.format("No settings match “%@”", model.query.trimmingCharacters(in: .whitespaces)))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Ink.text)
                    Text(Strings.text("Check the spelling or try other words."))
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Spacing.m)
                .padding(.top, Spacing.s)
                .accessibilityElement(children: .combine)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsPane.allCases.filter { pane in hits.contains { $0.pane == pane } }) { pane in
                        Text(pane.title)
                            .warmLabel()
                            .padding(.horizontal, Spacing.m)
                            .padding(.top, Spacing.s)
                            .padding(.bottom, 2)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(hits.filter { $0.pane == pane }) { found in
                            Button {
                                hit = found.id
                                model.open(found)
                            } label: {
                                // While typing, the first found is marked with the key that
                                // opens it.
                                let marked = hit == nil && found.id == hits.first?.id
                                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                                    Self.found(found.title, query: model.query)
                                        .font(.system(size: 13))
                                        // Whole in Catalan too: "Optimitza sempre els JPEG de manera agressiva".
                                        .lineLimit(3)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                    if marked {
                                        Image(systemName: "return")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Ink.secondary)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(SidebarRowStyle(selected: hit == found.id, focused: listFocused && keyboardMoved, marked: hit == nil && found.id == hits.first?.id))
                            .focusable(false)
                            .help(found.summary)
                            .id(found.id)
                            .accessibilityValue(Strings.format("%d of %d", (hits.firstIndex { $0.id == found.id } ?? 0) + 1, hits.count))
                            .accessibilityHint(found.summary)
                            .accessibilityAddTraits(hit == found.id ? [.isSelected] : [])
                        }
                    }
                }
            }
        }
    }

    /// A found setting's name with the typed words picked out: semibold in text ink, the rest
    /// quieter, still 4.5:1 on a marked or hovered row.
    static func found(_ title: String, query: String) -> Text {
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, let range = title.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return Text(title).foregroundStyle(Ink.text)
        }
        let quiet = Ink.text.opacity(0.8)
        return Text(title[..<range.lowerBound]).foregroundStyle(quiet)
            + Text(title[range]).fontWeight(.semibold).foregroundStyle(Ink.text)
            + Text(title[range.upperBound...]).foregroundStyle(quiet)
    }

    private func needsAttention(_ pane: SettingsPane) -> Bool {
        model.groups(in: pane).contains { PanelStatus.needsAttention($0.panel, model: model) }
    }

    /// How many of a pane's settings differ from their defaults; nil when none.
    private func changed(in pane: SettingsPane) -> Int? {
        let keys = model.groups(in: pane).flatMap { group in (group.switchSetting.map { [$0.key] } ?? []) + group.settings.map(\.key) }
        let count = keys.filter(model.isModified).count
        return count == 0 ? nil : count
    }

    /// ↑ and ↓: the next pane, or the next found setting.
    private func move(_ direction: MoveCommandDirection) {
        let step = direction == .up ? -1 : direction == .down ? 1 : 0
        guard step != 0 else { return }
        keyboardMoved = true
        if searching {
            let ids = model.hits.map(\.id)
            let index = hit.flatMap { ids.firstIndex(of: $0) } ?? (step > 0 ? -1 : ids.count)
            let next = index + step
            if ids.indices.contains(next) { hit = ids[next] }
        } else {
            let panes = SettingsPane.allCases
            guard let index = panes.firstIndex(of: model.pane), panes.indices.contains(index + step) else { return }
            model.pane = panes[index + step]
        }
    }
}
