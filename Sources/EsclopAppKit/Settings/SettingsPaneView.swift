// SPDX-License-Identifier: GPL-3.0-or-later
//
// One pane: its registry sections as a grouped form, then the rows that are not registry
// settings (hotkeys in General, maintenance in Advanced). Scrolls to the row a deep link or a
// search result names and marks it for a moment.

import AppKit
import EsclopCore
import EsclopIPC
import EsclopMCP
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

struct SettingsPaneView: View {
    let pane: SettingsPane
    let model: SettingsViewModel
    let agents: AgentsModel?
    let actions: SettingsActions

    @State private var confirmingReset = false
    /// The pane's content and the scroll view's heights: a legacy scroller shows at the right
    /// while the content is taller.
    @State private var contentHeight: CGFloat = 0
    @State private var viewHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    PaneHeading(pane: pane)
                    PanelIndex(groups: model.groups(in: pane), extras: Self.indexExtras(pane, agents: agents != nil, store: actions.settingsStore != nil), extrasFirst: pane == .agents, model: model) { id in
                        // A chip opens its panel too, so the click always shows something.
                        if let panel = pane.panels.first(where: { $0.id == id }), panel.collapsible, !model.isOpen(panel) {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { model.toggle(panel) }
                        }
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .top) }
                        // The panel takes the search's mark for a moment, so the click shows where;
                        // a click on the same chip again starts the mark afresh.
                        model.markInView = nil
                        model.highlighted = id
                    }
                    if pane == .agents, let agents {
                        Text(Strings.text("Agents such as Claude, Codex and Cursor use L’Esclop through its MCP server. Connect one here, then restart it."))
                            .foregroundStyle(Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Spacing.xs)
                            .padding(.bottom, Spacing.xs)
                        AgentsConnectSection(agents: agents, model: model, actions: actions)
                        AgentsTestSection(agents: agents)
                    }
                    ForEach(model.groups(in: pane)) { group in
                        panel(group)
                    }
                    extras
                }
                .padding(.leading, Spacing.xl - 4)
                .padding(.trailing, Gutter.trailing(Spacing.xl - 4, overflows: contentHeight > viewHeight + 1))
                .padding(.top, Spacing.s)
                .padding(.bottom, Spacing.xl)
                .labeledContentStyle(PanelRowStyle())
                // Every button on a panel is a white pill (owner's grammar); a few keep their own.
                .buttonStyle(PillButtonStyle(compact: true))
                .readsHeight($contentHeight)
            }
            .readsHeight($viewHeight)
            // The rows mark themselves and say when the mark is in view (`markable`).
            .environment(model)
            .task(id: model.highlighted) {
                guard let row = model.highlighted else { return }
                // Scroll until the row says it is in view: a scroll before the pane is laid out
                // finds no row, and on a busy Mac that takes longer than any fixed wait (council
                // C7-F1). Each try waits for the last one's animation; about five seconds.
                try? await Task.sleep(for: .milliseconds(80))
                for _ in 0 ..< 15 where model.markInView != row {
                    guard !Task.isCancelled else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { proxy.scrollTo(row, anchor: .center) }
                    try? await Task.sleep(for: .milliseconds(350))
                }
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                withAnimation(Motion.crossfade) { model.highlighted = nil }
            }
        }
    }

    /// A panel is a cream tile: its heading (with its switch and chevron when it opens and
    /// closes), then its rows while it is open. A panel that does not open names itself in small
    /// caps at its top.
    @ViewBuilder private func panel(_ group: SettingsViewModel.Group) -> some View {
        let panel = group.panel
        let open = model.isOpen(panel)
        // A panel of one switch and no name (Pause) is a feature of its own: a switch, as a
        // panel's heading has.
        let lone = panel.title == nil && group.settings.count == 1 && {
            if case .toggle = SettingPresentation.control(for: group.settings[0]) { return true }
            return false
        }()
        // While Pause is on, the clipboard and the folders under it wait: their panels dim.
        let waiting = panel.id.hasPrefix("automatic.") && !lone && model.value(EsclopSettings.pauseAutomaticOptimisations.key)?.boolValue == true
        VStack(alignment: .leading, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 0) {
                if lone, let setting = group.settings.first {
                    LoneSwitchHeading(setting: setting, model: model, actions: actions)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                } else if panel.collapsible {
                    PanelHeading(group: group, model: model, actions: actions, status: PanelStatus.text(for: panel, model: model))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
                if open, !lone {
                    if panel.collapsible {
                        Rectangle().fill(Ink.secondary.opacity(0.16)).frame(height: 0.5).padding(.horizontal, Spacing.l)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        if !panel.collapsible, let heading = panel.title {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(heading).warmLabel().accessibilityAddTraits(.isHeader)
                                    Spacer()
                                    if let changed = PanelStatus.changed(group, model: model) {
                                        Text(changed).font(.system(size: 11.5)).foregroundStyle(Ink.secondary)
                                    }
                                }
                                if let note = PanelStatus.note(for: panel) {
                                    Text(note)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Ink.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        if panel.id == "general.menuBar", let login = model.login {
                            // Open at login is a system setting, not a registry one; it leads General.
                            LoginItemRows(onboarding: login)
                        }
                        if panel.id == "general.keys" {
                            ForEach(Hotkeys.all, id: \.name.rawValue) { hotkey in
                                KeyboardShortcuts.Recorder(hotkey.title, name: hotkey.name)
                                    .markable(Hotkeys.rowID(hotkey.name))
                            }
                        }
                        let kinds = KindChecks.keys(in: panel)
                        if !kinds.isEmpty, panel.id == "automatic.clipboard" {
                            KindChecks(keys: kinds, label: KindChecks.label(in: panel), model: model, actions: actions)
                        }
                        ForEach(group.settings.filter { !kinds.contains($0.key) && SettingsViewModel.editedIn[$0.key] == nil }, id: \.key) { setting in
                            SettingRow(descriptor: setting, model: model, actions: actions, shortTitle: Self.shortTitle(setting.key))
                        }
                        // The formats that are always squeezed hard, after the sliders.
                        if !kinds.isEmpty, panel.id != "automatic.clipboard" {
                            KindChecks(keys: kinds, label: KindChecks.label(in: panel), plainLabel: true, model: model, actions: actions)
                        }
                    }
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, 14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .warmTile()
            if let footer = pane.footer(for: panel) {
                PanelFooter(text: footer)
            }
        }
        .environment(\.panelWaiting, waiting)
        .markable(panel.id)
    }

    @ViewBuilder private var extras: some View {
        switch pane {
        case .automatic:
            if let openPipelines = actions.openPipelines {
                TileSection {
                    LabeledContent {
                        Button(Strings.text("Open the Pipeline Editor…")) { openPipelines() }
                            .buttonStyle(PillButtonStyle(compact: true))
                    } label: {
                        SettingLabel(title: Strings.text("Pipelines"), summary: Strings.text("Make and change pipelines: their steps, what runs them and a filter, with Try it."))
                    }
                }
            }
        case .advanced:
            if let store = actions.settingsStore {
                TileSection(Strings.text("Settings file"), id: Self.settingsFileTile) {
                    LabeledContent {
                        HStack {
                            Button(Strings.text("Export…")) { SettingsFilePanels.export(store) }
                            Button(Strings.text("Import…")) { SettingsFilePanels.import(into: store) }
                        }
                        .buttonStyle(PillButtonStyle(compact: true))
                    } label: {
                        SettingLabel(
                            title: Strings.text("Settings on another Mac"),
                            summary: Strings.text("Export saves the settings you changed as a file; Import reads it on the other Mac. Pipelines, hotkeys and upload keys stay on this Mac.")
                        )
                    }
                    .markable(Self.settingsFileRow)
                }
            }
            TileSection(Strings.text("Maintenance"), id: Self.maintenanceTile) {
                LabeledContent {
                    Button(Strings.text("Copy")) { actions.copy("esclop settings schema") }
                        .buttonStyle(PillButtonStyle(compact: true))
                } label: {
                    SettingLabel(
                        title: Strings.text("The same settings in Terminal"),
                        summary: Strings.text("esclop settings schema lists them, esclop settings set and reset change them. The window follows.")
                    )
                }
                if let folder = actions.supportFolder {
                    LabeledContent {
                        Button(Strings.text("Show in Finder")) { actions.reveal(folder) }
                            .buttonStyle(PillButtonStyle(compact: true))
                    } label: {
                        SettingLabel(title: Strings.text("L’Esclop’s folder"), summary: Strings.text("Pipelines, backups of originals, recent results and logs."))
                    }
                }
                LabeledContent {
                    Button(Strings.text("Reset All…"), role: .destructive) { confirmingReset = true }
                        .buttonStyle(PillButtonStyle(compact: true))
                } label: {
                    SettingLabel(title: Strings.text("Reset every setting"), summary: Strings.text("Puts every setting back to its default, including the agent permissions. Hotkeys stay."))
                }
                .markable(Self.resetAllRow)
                .confirmationDialog(Strings.text("Reset every setting to its default?"), isPresented: $confirmingReset) {
                    Button(Strings.text("Reset All Settings"), role: .destructive) { model.resetAll() }
                } message: {
                    Text(Strings.text("Agent permissions are switched off again. This cannot be undone."))
                }
            }
        case .agents:
            if let agents { AgentsManualSection(agents: agents, actions: actions) }
        default:
            EmptyView()
        }
    }

    /// A row named by what its tile leaves to say: the kind alone under "Normally" and "When
    /// aggressive", "Folders" in a kind's panel, a size limit as the phrase it reads as. The
    /// registry's title stays for search, the CLI and VoiceOver's hint.
    static func shortTitle(_ key: String) -> String? {
        typealias S = EsclopSettings
        switch key {
        case S.imageCompression.key, S.imageAggressiveCompression.key: return Strings.text("Images")
        case S.videoCompression.key, S.videoAggressiveCompression.key: return Strings.text("Video")
        case S.audioCompression.key, S.audioAggressiveCompression.key: return Strings.text("Audio")
        case S.imageDirs.key, S.videoDirs.key, S.pdfDirs.key, S.audioDirs.key: return Strings.text("Folders")
        case S.maxImageSizeMB.key: return Strings.text("Skip images larger than")
        case S.maxVideoSizeMB.key: return Strings.text("Skip videos larger than")
        case S.maxPDFSizeMB.key: return Strings.text("Skip PDFs larger than")
        case S.maxAudioSizeMB.key: return Strings.text("Skip audio files larger than")
        default: return nil
        }
    }

    /// The tiles of a pane that are not registry panels, for its index.
    static func indexExtras(_ pane: SettingsPane, agents: Bool, store: Bool) -> [(id: String, title: String)] {
        switch pane {
        case .advanced:
            return (store ? [(settingsFileTile, Strings.text("Settings file"))] : []) + [(maintenanceTile, Strings.text("Maintenance"))]
        case .agents where agents:
            return [(AgentsConnectSection.tileID, Strings.text("Connect")), (AgentsTestSection.rowID, Strings.text("Test")), (AgentsManualSection.tileID, Strings.text("By hand"))]
        default:
            return []
        }
    }

    static let settingsFileTile = "advanced.settingsFileTile"
    static let maintenanceTile = "advanced.maintenanceTile"

    static let resetAllRow = "advanced.resetAll"
    static let settingsFileRow = "advanced.settingsFile"
    static let openAtLoginRow = "general.openAtLogin"

    /// The rows the search finds that are not registry settings.
    static var extraRows: [SettingsViewModel.ExtraRow] {
        Hotkeys.all.map { hotkey in
            SettingsViewModel.ExtraRow(
                id: Hotkeys.rowID(hotkey.name), title: hotkey.title, summary: Strings.text("Keyboard shortcut"),
                pane: .general, keywords: ["hotkey", "shortcut", "keyboard", "keyboard shortcut"]
            )
        } + AgentCatalog.all.map { agent in
            SettingsViewModel.ExtraRow(
                id: AgentRow.rowID(agent), title: Strings.format("Connect %@", agent.shownName), summary: Strings.format("Add L’Esclop’s MCP server to %@.", agent.shownName),
                pane: .agents, keywords: ["mcp", "install", "agent", "ai", "connect", agent.id]
            )
        } + [
            SettingsViewModel.ExtraRow(
                id: openAtLoginRow, title: Strings.text("Open at login"),
                summary: Strings.text("Keep L’Esclop in the menu bar after a restart, so copies are optimised from the start."),
                pane: .general, keywords: ["login", "startup", "launch", "login items", "open at login"]
            ),
            SettingsViewModel.ExtraRow(
                id: AgentsTestSection.rowID, title: Strings.text("Test the MCP server"), summary: Strings.text("Start esclop mcp serve and ask for its tools."),
                pane: .agents, keywords: ["mcp", "smoke", "handshake", "check", "test the mcp server"]
            ),
            SettingsViewModel.ExtraRow(
                id: settingsFileRow, title: Strings.text("Settings on another Mac"), summary: Strings.text("Export and import the settings you changed."),
                pane: .advanced, keywords: ["export", "import", "backup", "sync", "transfer", "json"]
            ),
            SettingsViewModel.ExtraRow(
                id: resetAllRow, title: Strings.text("Reset every setting"), summary: Strings.text("Puts every setting back to its default."),
                pane: .advanced, keywords: ["defaults", "restore", "factory", "reset every setting"]
            ),
        ]
    }
}

/// The pane's one heading, in New York, and what the pane is for.
struct PaneHeading: View {
    let pane: SettingsPane

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(pane.title)
                .font(.warmHeading(30))
                .foregroundStyle(Ink.text)
                .accessibilityAddTraits(.isHeader)
            Text(pane.subtitle)
                .font(.system(size: 14))
                .foregroundStyle(Ink.secondary)
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.bottom, Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A panel's heading: its symbol, name and state, the switch that turns the feature on or off,
/// and the chevron that opens its settings. The whole heading opens and closes it.
struct PanelHeading: View {
    let group: SettingsViewModel.Group
    let model: SettingsViewModel
    let actions: SettingsActions
    let status: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelWaiting) private var waiting
    @State private var hovering = false

    var body: some View {
        let panel = group.panel
        let open = model.isOpen(panel)
        HStack(spacing: Spacing.m) {
            Button(action: toggle) {
                HStack(spacing: 14) {
                    if let symbol = panel.symbol {
                        // Waiting under Pause: the sign and the switch quieten; the words stay.
                        IconBadge(symbol: symbol).opacity(waiting ? 0.5 : 1)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(panel.title ?? "")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Ink.text)
                        let line = [status, PanelStatus.changed(group, model: model)].compactMap { $0 }.joined(separator: " · ")
                        if !line.isEmpty {
                            HStack(spacing: 5) {
                                // A folder inside needs a decision: amber, closed or open.
                                if PanelStatus.needsAttention(panel, model: model) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Ink.warm)
                                        .accessibilityHidden(true)
                                }
                                Text(line)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Ink.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The whole heading opens the panel: a wash under the pointer says so.
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.04 : 0))
                    .padding(-6)
            }
            .onHover { hovering = $0 }
            .contentShape(.focusEffect, RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(panel.title ?? "")
            .accessibilityValue([status, PanelStatus.changed(group, model: model), open ? Strings.text("open") : Strings.text("closed")].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint(open ? Strings.text("Hides its settings") : Strings.text("Shows its settings"))
            if let setting = group.switchSetting {
                Toggle(isOn: Binding(get: { setting.value?.boolValue ?? false }, set: { model.set(setting.key, to: .bool($0)) })) {
                    Text(setting.title)
                }
                .switchLabel(title: setting.title, hint: setting.summary)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(WarmInk.switchOn)
                .opacity(waiting ? 0.6 : 1)
                .help(setting.summary)
                .markable(setting.key)
                .settingMenu(setting, model: model, actions: actions)
            }
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: Spacing.hit, height: Spacing.hit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The heading itself opens and closes: one stop for the keyboard, one for VoiceOver.
            .focusable(false)
            .accessibilityHidden(true)
        }
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { model.toggle(group.panel) }
    }
}

extension EnvironmentValues {
    /// The panel waits under Pause.
    @Entry var panelWaiting = false
}

/// A feature that is one switch (Pause): a panel heading of its own, its switch in the panels'
/// column.
struct LoneSwitchHeading: View {
    let setting: SettingDescriptor
    let model: SettingsViewModel
    let actions: SettingsActions

    var body: some View {
        HStack(spacing: Spacing.m) {
            HStack(spacing: 14) {
                IconBadge(symbol: setting.key == EsclopSettings.pauseAutomaticOptimisations.key ? "pause" : "switch.2")
                VStack(alignment: .leading, spacing: 2) {
                    Text(setting.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Ink.text)
                    Text(Typeset.smart(setting.summary.hasSuffix(".") ? String(setting.summary.dropLast()) : setting.summary))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .accessibilityHidden(true)
            Toggle(isOn: Binding(get: { setting.value?.boolValue ?? false }, set: { model.set(setting.key, to: .bool($0)) })) {
                Text(setting.title)
            }
            .switchLabel(title: setting.title, hint: setting.summary)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(WarmInk.switchOn)
            .help(setting.summary)
            .markable(setting.key)
            .settingMenu(setting, model: model, actions: actions)
            // Where a panel has its chevron.
            Color.clear.frame(width: Spacing.hit, height: 1)
        }
    }
}

/// What a panel or tile says under it, on the page.
struct PanelFooter: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.l)
    }
}

/// A cream tile of rows with a small-caps name, and what it says under it: the panes' sections
/// that are not registry panels (Agents, Advanced).
struct TileSection<Content: View, Footer: View>: View {
    let title: String?
    /// Where the pane's index scrolls to.
    var id: String?
    let content: Content
    let footer: Footer

    init(_ title: String? = nil, id: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.id = id
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 14) {
                if let title {
                    Text(title).warmLabel().accessibilityAddTraits(.isHeader)
                }
                content
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .warmTile()
            footer
        }
        // Marked like a row when its chip or a search leads to it.
        .markable(id ?? title ?? "")
    }
}

extension TileSection where Footer == EmptyView {
    init(_ title: String? = nil, id: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, id: id, content: content) { EmptyView() }
    }
}


/// The line under a panel's name: what it does now, in a few words.
enum PanelStatus {
    @MainActor static func text(for panel: SettingsPanel, model: SettingsViewModel) -> String? {
        typealias S = EsclopSettings
        if let key = panel.switchKey, model.value(key)?.boolValue == false { return Strings.text("Off") }
        // Pause stops the clipboard and every folder: the panels under it say so.
        if panel.id.hasPrefix("automatic."), panel.id != "automatic.pause", model.value(S.pauseAutomaticOptimisations.key)?.boolValue == true {
            return Strings.text("Paused")
        }
        switch panel.id {
        case "automatic.clipboard":
            let kinds = KindChecks.keys(in: panel).filter { model.value($0)?.boolValue == true }.map(KindChecks.name)
            return kinds.isEmpty ? Strings.text("Off") : list(kinds)
        case "automatic.images", "automatic.video", "automatic.pdf", "automatic.audio":
            let count = folders(in: panel, model: model).count
            let attention = attention(in: panel, model: model)
            let watching = count - attention
            guard count > 0 else { return Strings.text("No folders yet") }
            // A folder that needs a decision is not counted as watched, closed or open; the
            // heading's amber sign says one does.
            if attention > 0 { return Strings.format("%d of %d folders watched", watching, count) }
            return count == 1 ? Strings.text("1 folder watched") : Strings.format("%d folders watched", count)
        case "general.output":
            let shown = panel.keys.compactMap { model.descriptor($0) }.map { SettingPresentation.display($0.value ?? $0.defaultValue, for: $0) }
            return Set(shown).count == 1 ? shown.first : Strings.text("Different for each kind")
        case "results.floating":
            return model.descriptor(S.floatingResultsCorner.key).map { SettingPresentation.display($0.value ?? $0.defaultValue, for: $0) }
        case "results.dropZone":
            return model.value(S.dropZoneOnlyWithOption.key)?.boolValue == true
                ? Strings.text("After tapping ⌥ during a drag") : Strings.text("While you drag files")
        default:
            return nil
        }
    }

    /// One line under a tile's label for what its rows, named by kind alone, leave out.
    static func note(for panel: SettingsPanel) -> String? {
        switch panel.id {
        // The scale, once for the three sliders.
        case "compression.normally": return Strings.text("0 to 100. Images look lossless at 30; higher is smaller, with visible loss.")
        // What starts an aggressive pass, which the sliders alone do not say.
        case "compression.aggressive": return Strings.text("Used when you hold ⌘ as you drop, or choose Optimise harder on a result.")
        default: return nil
        }
    }

    /// A folder in the panel needs a decision, and the panel is on: a feature that is off needs none.
    @MainActor static func needsAttention(_ panel: SettingsPanel, model: SettingsViewModel) -> Bool {
        if let key = panel.switchKey, model.value(key)?.boolValue == false { return false }
        return attention(in: panel, model: model) > 0
    }

    @MainActor static func folders(in panel: SettingsPanel, model: SettingsViewModel) -> [String] {
        guard panel.id.hasPrefix("automatic."), let key = panel.keys.first else { return [] }
        return model.value(key)?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    /// How many of a folder panel's folders need a decision (missing, unreadable, not watched),
    /// found without reading inside them, so opening Settings makes macOS ask nothing.
    @MainActor static func attention(in panel: SettingsPanel, model: SettingsViewModel) -> Int {
        folders(in: panel, model: model).filter { FolderListEditor.quietStatus(of: $0, model: model) != .watching }.count
    }

    /// "2 changed": how many of the panel's settings differ from their defaults, so a person
    /// finds what they changed; nil when none.
    @MainActor static func changed(_ group: SettingsViewModel.Group, model: SettingsViewModel) -> String? {
        let keys = (group.switchSetting.map { [$0.key] } ?? []) + group.settings.map(\.key)
        let count = keys.filter(model.isModified).count
        switch count {
        case 0: return nil
        case 1: return Strings.text("1 setting changed")
        default: return Strings.format("%d settings changed", count)
        }
    }

    /// "Images, videos and PDFs": names after the first in lower case, unless they are an
    /// abbreviation ("PDFs").
    static func list(_ items: [String]) -> String {
        let words = items.enumerated().map { index, item in
            index == 0 || item.filter(\.isUppercase).count > 1 ? item : item.lowercased()
        }
        guard words.count > 1 else { return words.first ?? "" }
        return Strings.format("%@ and %@", words.dropLast().joined(separator: ", "), words.last!)
    }
}

/// "What to compress": a round check for each kind of file, on when it is filled.
struct KindChecks: View {
    let keys: [String]
    var label = Strings.text("What to optimise")
    /// A row title, not a tile's section label (a tile has one of those).
    var plainLabel = false
    let model: SettingsViewModel
    let actions: SettingsActions

    /// The kinds a panel shows as round checks instead of switches.
    static func keys(in panel: SettingsPanel) -> [String] {
        typealias S = EsclopSettings
        switch panel.id {
        case "automatic.clipboard":
            return [S.enableClipboardOptimiser.key, S.optimiseVideoClipboard.key, S.optimisePDFClipboard.key, S.optimiseAudioClipboard.key]
        case "compression.aggressive":
            return [S.useAggressiveOptimisationJPEG.key, S.useAggressiveOptimisationPNG.key, S.useAggressiveOptimisationGIF.key, S.useAggressiveOptimisationMP4.key, S.useAggressiveOptimisationPDF.key]
        default:
            return []
        }
    }

    /// The label over the checks.
    static func label(in panel: SettingsPanel) -> String {
        panel.id == "compression.aggressive" ? Strings.text("Always aggressive for") : Strings.text("What to optimise")
    }

    static func name(_ key: String) -> String {
        typealias S = EsclopSettings
        switch key {
        case S.enableClipboardOptimiser.key: return Strings.text("Images")
        case S.optimiseVideoClipboard.key: return Strings.text("Videos")
        case S.optimisePDFClipboard.key: return Strings.text("PDFs")
        case S.useAggressiveOptimisationJPEG.key: return "JPEG"
        case S.useAggressiveOptimisationPNG.key: return "PNG"
        case S.useAggressiveOptimisationGIF.key: return "GIF"
        case S.useAggressiveOptimisationMP4.key: return Strings.text("Video")
        case S.useAggressiveOptimisationPDF.key: return "PDF"
        default: return Strings.text("Audio")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if plainLabel {
                Text(label).font(.system(size: 13)).foregroundStyle(Ink.text)
            } else {
                Text(label).warmLabel()
            }
            // One pitch for every circle, the names centred under them.
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    if let setting = model.descriptor(key) {
                        KindCheck(name: Self.name(key), setting: setting, model: model)
                            .markable(key)
                            .settingMenu(setting, model: model, actions: actions)
                    }
                }
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}

struct KindCheck: View {
    let name: String
    let setting: SettingDescriptor
    let model: SettingsViewModel
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let on = setting.value?.boolValue ?? false
        Button {
            model.set(setting.key, to: .bool(!on))
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    if on {
                        Circle().fill(WarmInk.chosen)
                            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(WarmInk.onChosen)
                    } else {
                        // Off: a sand disc with a ring at 3:1, as the target's unchecked kind.
                        Circle().fill(Surface.disc)
                        Circle().strokeBorder(contrast == .increased ? AnyShapeStyle(Color(nsColor: .labelColor)) : AnyShapeStyle(Ink.secondary.opacity(0.85)), lineWidth: 1)
                    }
                }
                .frame(width: 34, height: 34)
                Text(name)
                    .font(.system(size: 10, weight: .bold))
                    .textCase(.uppercase)
                    .tracking(1.6)
                    .foregroundStyle(Ink.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The ring goes round the disc and its name, not across the name's letters.
        .contentShape(.focusEffect, RoundedRectangle(cornerRadius: 12, style: .continuous))
        .help(setting.summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(setting.title)
        .accessibilityValue(on ? Strings.text("on") : Strings.text("off"))
        .accessibilityAddTraits(.isToggle)
    }
}

extension Hotkeys {
    static func rowID(_ name: KeyboardShortcuts.Name) -> String { "hotkey.\(name.rawValue)" }
}

/// The title and the one-line explanation every row carries.
struct SettingLabel: View {
    let title: String
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Typeset.smart(title))
                .font(.system(size: 13))
                .foregroundStyle(Ink.text)
            Text(Typeset.smart(summary))
                .font(.system(size: 11.5))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension View {
    /// A row a deep link or a search result can name: the pane scrolls to `id`, and while the
    /// Settings model points at it, a wash behind it that fades.
    func markable(_ id: String) -> some View { modifier(MarkableRow(id: id)) }
}

/// The row's mark, and whether it is in view, for the pane that scrolls to it.
private struct MarkableRow: ViewModifier {
    let id: String
    /// Settings' model; none on the tour, which marks nothing.
    @Environment(SettingsViewModel.self) private var model: SettingsViewModel?
    @State private var inView = false

    func body(content: Content) -> some View {
        let on = model?.highlighted == id
        content
            .id(id)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Ink.charcoal.opacity(on ? 0.16 : 0))
                    .padding(.horizontal, -8)
                    .padding(.vertical, -5)
                    .allowsHitTesting(false)
            }
            .accessibilityAddTraits(on ? .isSelected : [])
            .onGeometryChange(for: Bool.self) { Self.isInView($0) } action: { inView = $0 }
            // Only "now in view": a copy of the row the lazy Form makes or drops out of view must
            // not take back what the shown row said. Seen on the macOS 15 runner, for a row that
            // does not move; the cause is inferred. A new link clears it (`SettingsViewModel.open`).
            .onChange(of: on && inView, initial: true) { _, shown in
                if shown { model?.markInView = id }
            }
    }

    /// Whole inside the scroll view's visible part, or filling it.
    nonisolated static func isInView(_ proxy: GeometryProxy) -> Bool {
        guard let visible = proxy.bounds(of: .scrollView) else { return false }
        let row = CGRect(origin: .zero, size: proxy.size)
        let shown = visible.intersection(row).height
        return shown >= row.height - 1 || shown >= visible.height - 1
    }
}

/// Export… and Import… in Settings › General: the panels and what they say afterwards.
@MainActor
enum SettingsFilePanels {
    static func export(_ store: SettingsStore) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = Strings.text("L’Esclop settings") + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SettingsFile.export(from: store).write(to: url, options: .atomic)
        } catch {
            tell(Strings.text("Could not export the settings"), error.localizedDescription)
        }
    }

    static func `import`(into store: SettingsStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.prompt = Strings.text("Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            // A shared file must not quietly let agents run scripts, or redirect or start
            // uploads: asked first, without them by default.
            var allowPermissions = false
            let turnsOn = try SettingsFile.read(data, for: store).permissions
            if !turnsOn.isEmpty {
                let question = permissionsQuestion(turnsOn)
                let alert = NSAlert()
                alert.messageText = question.title
                alert.informativeText = question.detail
                alert.addButton(withTitle: Strings.text("Import Without Permissions"))
                alert.addButton(withTitle: Strings.text("Import With Permissions"))
                alert.addButton(withTitle: Strings.text("Cancel"))
                switch alert.runModal() {
                case .alertFirstButtonReturn: break
                case .alertSecondButtonReturn: allowPermissions = true
                default: return
                }
            }
            let read = try SettingsFile.import(data, into: store, allowPermissions: allowPermissions)
            let done = outcome(read, allowedPermissions: allowPermissions)
            tell(done.title, done.detail)
        } catch let EsclopError.invalidArgument(reason) {
            tell(Strings.text("Could not import the settings"), importFailure(reason))
        } catch {
            tell(Strings.text("Could not import the settings"), error.localizedDescription)
        }
    }

    /// Why an import was refused, in the person's language: `SettingsFile` says it in English,
    /// for the CLI. A value a setting does not take names that setting.
    // ponytail: reads SettingsFile's English sentences (SettingsFile.read); a reworded one falls
    // back to the generic line with the English reason, and SettingsImportTests catches it. Give
    // SettingsFile a typed error if a third reason appears.
    static func importFailure(_ reason: String, locale: Locale = Strings.locale) -> String {
        if reason.hasPrefix("This is not an L’Esclop settings file") {
            return Strings.text("This is not a settings file L’Esclop exported. Nothing was changed.", locale: locale)
        }
        if let end = reason.range(of: " in the file is not a value it takes"), SettingsRegistry.shared.setting(String(reason[..<end.lowerBound])) != nil {
            let name = names([String(reason[..<end.lowerBound])], locale: locale)[0]
            return Strings.format("The file’s value for “%@” is not one this setting takes. Nothing was changed.", name, locale: locale)
        }
        return Strings.text("The file is not one L’Esclop exported, or a value in it is not one its setting takes. Nothing was changed.", locale: locale) + "\n\n" + reason
    }

    /// The question before an import that turns on permissions (agents', uploads'), naming each.
    static func permissionsQuestion(_ keys: [String], locale: Locale = Strings.locale) -> (title: String, detail: String) {
        let list = names(keys, locale: locale).map { "• " + $0 }.joined(separator: "\n")
        return (
            Strings.text("This file turns on permissions", locale: locale),
            list + "\n\n" + Strings.text("Turn them on only if you made this file or trust whoever did.", locale: locale)
        )
    }

    /// What the import did: the settings it changed, by name, and what it left out.
    static func outcome(_ read: SettingsFile.Read, allowedPermissions: Bool, locale: Locale = Strings.locale) -> (title: String, detail: String) {
        let title = read.changed.isEmpty ? Strings.text("Nothing to change", locale: locale) : Strings.text("Settings imported", locale: locale)
        var lines = [read.changed.isEmpty
            ? Strings.text("This Mac already has every setting in the file.", locale: locale)
            : Strings.format("Changed: %@.", names(read.changed, locale: locale).joined(separator: ", "), locale: locale)]
        if !read.unkept.isEmpty {
            lines.append(Strings.format("Not kept, because something on this Mac sets them, such as a configuration profile: %@.", names(read.unkept, locale: locale).joined(separator: ", "), locale: locale))
        }
        if !allowedPermissions, !read.permissions.isEmpty {
            lines.append(Strings.format("Permissions left off: %@.", names(read.permissions, locale: locale).joined(separator: ", "), locale: locale))
        }
        if read.isNewer { lines.append(Strings.text("A newer version of L’Esclop wrote this file.", locale: locale)) }
        if !read.unknown.isEmpty { lines.append(Strings.format("Skipped what this version does not know: %@.", read.unknown.joined(separator: ", "), locale: locale)) }
        return (title, lines.joined(separator: "\n"))
    }

    private static func names(_ keys: [String], locale: Locale) -> [String] {
        keys.map { SettingWords.lookup(SettingWords.titleKey($0), english: SettingsRegistry.shared.setting($0)?.title ?? $0, locale: locale) }
    }

    private static func tell(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}

/// The pane's panels as small chips under its heading: a click scrolls to one. With 100
/// settings in seven panes, it shows at a glance what a pane holds and where a change was made.
struct PanelIndex: View {
    let groups: [SettingsViewModel.Group]
    /// The pane's tiles that are not registry panels, by id and name.
    var extras: [(id: String, title: String)] = []
    /// The extras come first, as they do on the page (Agents).
    var extrasFirst = false
    let model: SettingsViewModel
    let go: (String) -> Void

    var body: some View {
        let named = groups.filter { $0.panel.title != nil }
        if named.count + extras.count >= 3 {
            FlowLayout(spacing: 6) {
                // The page's order: tiles drawn before the panels come first.
                if extrasFirst { extraChips(extras.filter { $0.id != AgentsManualSection.tileID }) }
                ForEach(named) { group in
                    Button { go(group.panel.id) } label: {
                        HStack(spacing: 5) {
                            Text(Self.short(group.panel))
                            if PanelStatus.needsAttention(group.panel, model: model) {
                                // A folder inside needs a decision: the amber sign of its row.
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Ink.warm)
                            } else if PanelStatus.changed(group, model: model) != nil {
                                // A changed setting inside: a small dot, named for VoiceOver.
                                Circle().fill(Ink.text.opacity(0.55)).frame(width: 5, height: 5)
                            }
                        }
                    }
                    .buttonStyle(IndexChipStyle())
                    .accessibilityLabel([group.panel.title, PanelStatus.needsAttention(group.panel, model: model) ? Strings.text("Needs attention") : nil, PanelStatus.changed(group, model: model)].compactMap { $0 }.joined(separator: ", "))
                    .help(Strings.format("Go to %@", group.panel.title ?? ""))
                }
                if extrasFirst { extraChips(extras.filter { $0.id == AgentsManualSection.tileID }) } else { extraChips(extras) }
            }
            .padding(.horizontal, Spacing.xs)
            .padding(.bottom, Spacing.s)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Strings.text("Panels in this pane"))
        }
    }
}

extension PanelIndex {
    @ViewBuilder func extraChips(_ list: [(id: String, title: String)]) -> some View {
        ForEach(list, id: \.id) { extra in
            Button(extra.title) { go(extra.id) }
                .buttonStyle(IndexChipStyle())
                .help(Strings.format("Go to %@", extra.title))
        }
    }

    /// A panel's name on its chip, short enough for one line: the kinds in folders by kind.
    static func short(_ panel: SettingsPanel) -> String {
        switch panel.id {
        case "agents.permissions": return Strings.text("Permissions")
        case "automatic.images": return Strings.text("Images")
        case "automatic.video": return Strings.text("Videos")
        case "automatic.pdf": return Strings.text("PDFs")
        case "automatic.audio": return Strings.text("Audio")
        default: return panel.title ?? ""
        }
    }
}

/// A chip of the pane's index: quiet, on the page, a wash under the pointer.
struct IndexChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IndexChip(label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct IndexChip<Label: View>: View {
    let label: Label
    let pressed: Bool
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Ink.text)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background {
                // A hairline edge so a chip reads as pressable, quieter than the white pills.
                Capsule().fill(Color.primary.opacity(pressed ? 0.1 : hovering ? 0.07 : 0.045))
                    .overlay(Capsule().strokeBorder(contrast == .increased ? AnyShapeStyle(Color(nsColor: .labelColor)) : AnyShapeStyle(Ink.secondary.opacity(0.6)), lineWidth: contrast == .increased ? 1 : 0.75))
            }
            .contentShape(Capsule())
            .contentShape(.focusEffect, Capsule())
            .onHover { hovering = $0 }
    }
}
