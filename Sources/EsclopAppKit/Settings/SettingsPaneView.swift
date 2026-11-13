// SPDX-License-Identifier: GPL-3.0-or-later
//
// One pane: its registry sections as a grouped form, then the rows that are not registry
// settings (hotkeys in General, maintenance in Advanced). Scrolls to the row a deep link or a
// search result names and marks it for a moment.

import EsclopCore
import EsclopIPC
import EsclopMCP
import KeyboardShortcuts
import SwiftUI

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
                        ForEach(group.settings, id: \.key) { setting in
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
            .task(id: model.highlighted) {
                guard let row = model.highlighted else { return }
                // Let the pane lay out first when the link also switched panes.
                try? await Task.sleep(for: .milliseconds(80))
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { proxy.scrollTo(row, anchor: .center) }
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                withAnimation(Motion.crossfade) { model.highlighted = nil }
            }
        }
    }

    static var intro: [SettingsPane: String] {
        [.agents: Strings.text("AI agents such as Claude, Codex and Cursor use L'Esclop through its MCP server: they can optimise, convert and crop files, and write pipelines. Connect an agent here, then restart it.")]
    }

    @ViewBuilder private var extras: some View {
        switch pane {
        case .general:
            Section(Strings.text("Keyboard shortcuts")) {
                ForEach(Hotkeys.all, id: \.name.rawValue) { hotkey in
                    KeyboardShortcuts.Recorder(hotkey.title, name: hotkey.name)
                        .id(Hotkeys.rowID(hotkey.name))
                        .highlighted(model.highlighted == Hotkeys.rowID(hotkey.name))
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
                        SettingLabel(title: Strings.text("L'Esclop's folder"), summary: Strings.text("Pipelines, backups of originals, recent results and logs."))
                    }
                }
                LabeledContent {
                    Button(Strings.text("Reset All…"), role: .destructive) { confirmingReset = true }
                } label: {
                    SettingLabel(title: Strings.text("Reset every setting"), summary: Strings.text("Puts every setting back to its default, including the agent permissions. Hotkeys stay."))
                }
                .id(Self.resetAllRow)
                .highlighted(model.highlighted == Self.resetAllRow)
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

    /// The rows the search finds that are not registry settings.
    static var extraRows: [SettingsViewModel.ExtraRow] {
        Hotkeys.all.map { hotkey in
            SettingsViewModel.ExtraRow(
                id: Hotkeys.rowID(hotkey.name), title: hotkey.title, summary: Strings.text("Keyboard shortcut"),
                pane: .general, keywords: ["hotkey", "shortcut", "keyboard", "keyboard shortcut"]
            )
        } + AgentCatalog.all.map { agent in
            SettingsViewModel.ExtraRow(
                id: AgentRow.rowID(agent), title: Strings.format("Connect %@", agent.name), summary: Strings.format("Add L'Esclop's MCP server to %@.", agent.name),
                pane: .agents, keywords: ["mcp", "install", "agent", "ai", "connect", agent.id]
            )
        } + [
            SettingsViewModel.ExtraRow(
                id: AgentsTestSection.rowID, title: Strings.text("Test the MCP server"), summary: Strings.text("Start esclop mcp serve and ask for its tools."),
                pane: .agents, keywords: ["mcp", "smoke", "handshake", "check", "test the mcp server"]
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
    /// The mark a deep link puts on its row: an accent wash behind it that fades.
    func highlighted(_ on: Bool) -> some View {
        background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Ink.charcoal.opacity(on ? 0.16 : 0))
                .padding(.horizontal, -8)
                .padding(.vertical, -5)
                .allowsHitTesting(false)
        }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
