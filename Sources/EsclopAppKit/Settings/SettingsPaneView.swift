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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                if let intro = Self.intro[pane] {
                    Section {
                        Text(intro)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if pane == .agents, let agents {
                    AgentsConnectSection(agents: agents, model: model, actions: actions)
                    AgentsTestSection(agents: agents)
                }
                ForEach(model.groups(in: pane)) { group in
                    Section {
                        // Open at login is a system setting, not a registry one; it leads the
                        // menu bar rows at the top of General.
                        if group.section == .menuBar, let login = model.login {
                            LoginItemRows(onboarding: login)
                        }
                        ForEach(group.settings.filter { !Self.besideHotkeys.contains($0.key) && SettingsViewModel.editedIn[$0.key] == nil }, id: \.key) { setting in
                            SettingRow(descriptor: setting, model: model, actions: actions)
                        }
                    } header: {
                        if let heading = group.heading { Text(heading) }
                    } footer: {
                        if let footer = pane.footer(for: group.section) {
                            Text(footer)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                // Grouped forms put footers on the trailing side; these read
                                // with the rows above.
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                extras
            }
            .formStyle(.grouped)
            // The rows mark themselves and say when the mark is in view (`markable`).
            .environment(model)
            .task(id: model.highlighted) {
                guard let row = model.highlighted else { return }
                // Scroll until the row says it is in view: a scroll before the Form has laid the
                // pane out finds no row, and on a busy Mac that takes longer than any fixed wait
                // (council C7-F1). Each try waits for the last one's animation; about five seconds.
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

    /// Registry settings shown with the keyboard shortcuts instead of their section's group.
    static let besideHotkeys = [EsclopSettings.cardKeysUnderPointer.key]

    static var intro: [SettingsPane: String] {
        [.agents: Strings.text("AI agents such as Claude, Codex and Cursor use L’Esclop through its MCP server: they can optimise, convert and crop files, and write pipelines. Connect an agent here, then restart it.")]
    }

    @ViewBuilder private var extras: some View {
        switch pane {
        case .general:
            Section(Strings.text("Keyboard shortcuts")) {
                ForEach(Hotkeys.all, id: \.name.rawValue) { hotkey in
                    KeyboardShortcuts.Recorder(hotkey.title, name: hotkey.name)
                        .markable(Hotkeys.rowID(hotkey.name))
                }
                ForEach(Self.besideHotkeys, id: \.self) { key in
                    if let setting = model.descriptor(key) { SettingRow(descriptor: setting, model: model, actions: actions) }
                }
            }
            if let store = actions.settingsStore {
                Section {
                    LabeledContent {
                        HStack {
                            Button(Strings.text("Export…")) { SettingsFilePanels.export(store) }
                            Button(Strings.text("Import…")) { SettingsFilePanels.import(into: store) }
                        }
                    } label: {
                        SettingLabel(
                            title: Strings.text("Settings on another Mac"),
                            summary: Strings.text("Export saves the settings you changed as a file; Import reads it on the other Mac. Hotkeys and upload keys stay.")
                        )
                    }
                    .markable(Self.settingsFileRow)
                }
            }
        case .advanced:
            Section(Strings.text("Maintenance")) {
                LabeledContent {
                    Button(Strings.text("Copy")) { actions.copy("esclop settings schema") }
                } label: {
                    SettingLabel(
                        title: Strings.text("The same settings in Terminal"),
                        summary: Strings.text("esclop settings schema lists them, esclop settings set and reset change them. The window follows.")
                    )
                }
                if let openPipelines = actions.openPipelines {
                    LabeledContent {
                        Button(Strings.text("Open the Pipeline Editor…")) { openPipelines() }
                    } label: {
                        SettingLabel(title: Strings.text("Pipelines"), summary: Strings.text("Make and change pipelines: their steps, what runs them and a filter, with Try it."))
                    }
                }
                if let folder = actions.supportFolder {
                    LabeledContent {
                        Button(Strings.text("Show in Finder")) { actions.reveal(folder) }
                    } label: {
                        SettingLabel(title: Strings.text("L’Esclop’s folder"), summary: Strings.text("Pipelines, backups of originals, recent results and logs."))
                    }
                }
                LabeledContent {
                    Button(Strings.text("Reset All…"), role: .destructive) { confirmingReset = true }
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

    static let resetAllRow = "advanced.resetAll"
    static let settingsFileRow = "general.settingsFile"
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
                id: AgentRow.rowID(agent), title: Strings.format("Connect %@", agent.name), summary: Strings.format("Add L’Esclop’s MCP server to %@.", agent.name),
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
                pane: .general, keywords: ["export", "import", "backup", "sync", "transfer", "json"]
            ),
            SettingsViewModel.ExtraRow(
                id: resetAllRow, title: Strings.text("Reset every setting"), summary: Strings.text("Puts every setting back to its default."),
                pane: .advanced, keywords: ["defaults", "restore", "factory", "reset every setting"]

            ),
        ]
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
            Text(title)
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
            let read = try SettingsFile.import(Data(contentsOf: url), into: store)
            let title = read.values.count == 1 ? Strings.text("Imported 1 setting") : Strings.format("Imported %d settings", read.values.count)
            let skipped = read.unknown.isEmpty ? "" : Strings.format("Skipped what this version does not know: %@.", read.unknown.joined(separator: ", "))
            tell(title, skipped)
        } catch let EsclopError.invalidArgument(reason) {
            tell(Strings.text("Could not import the settings"), Strings.text("The file is not one L’Esclop exported, or a value in it is not one its setting takes. Nothing was changed.") + "\n\n" + reason)
        } catch {
            tell(Strings.text("Could not import the settings"), error.localizedDescription)
        }
    }

    private static func tell(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
