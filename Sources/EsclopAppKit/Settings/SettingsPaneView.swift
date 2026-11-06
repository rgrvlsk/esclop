// SPDX-License-Identifier: GPL-3.0-or-later
//
// One pane: its registry sections as a grouped form, then the rows that are not registry
// settings (hotkeys in General, maintenance in Advanced). Scrolls to the row a deep link or a
// search result names and marks it for a moment.

import EsclopCore
import EsclopIPC
import KeyboardShortcuts
import SwiftUI

struct SettingsPaneView: View {
    let pane: SettingsPane
    let model: SettingsViewModel
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
                ForEach(model.groups(in: pane)) { group in
                    Section {
                        ForEach(group.settings, id: \.key) { setting in
                            SettingRow(descriptor: setting, model: model, actions: actions)
                        }
                    } header: {
                        if let heading = group.heading { Text(heading) }
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

    static let intro: [SettingsPane: String] = [
        .agents: "AI agents reach L'Esclop through its MCP server. Every request they make is checked against these switches, by the server and again by the app. They start off, and agents cannot turn them on. The esclop command line acts for you and is not limited by them.",
        .advanced: "Watching folders for new screenshots and recordings is configured here; the app does not watch folders yet.",
    ]

    @ViewBuilder private var extras: some View {
        switch pane {
        case .general:
            Section("Keyboard shortcuts") {
                ForEach(Hotkeys.all, id: \.name.rawValue) { hotkey in
                    KeyboardShortcuts.Recorder(hotkey.title, name: hotkey.name)
                        .id(Hotkeys.rowID(hotkey.name))
                        .highlighted(model.highlighted == Hotkeys.rowID(hotkey.name))
                }
            }
        case .advanced:
            Section("Maintenance") {
                LabeledContent {
                    Button("Copy") { actions.copy("esclop settings schema") }
                } label: {
                    SettingLabel(
                        title: "The same settings in Terminal",
                        summary: "esclop settings schema lists them, esclop settings set and reset change them. The window follows."
                    )
                }
                if let folder = actions.supportFolder {
                    LabeledContent {
                        Button("Show in Finder") { actions.reveal(folder) }
                    } label: {
                        SettingLabel(title: "L'Esclop's folder", summary: "Pipelines, backups of originals, recent results and logs.")
                    }
                }
                LabeledContent {
                    Button("Reset All…", role: .destructive) { confirmingReset = true }
                } label: {
                    SettingLabel(title: "Reset every setting", summary: "Puts every setting back to its default, including the agent permissions. Hotkeys stay.")
                }
                .id(Self.resetAllRow)
                .highlighted(model.highlighted == Self.resetAllRow)
                .confirmationDialog("Reset every setting to its default?", isPresented: $confirmingReset) {
                    Button("Reset All Settings", role: .destructive) { model.resetAll() }
                } message: {
                    Text("Agent permissions are switched off again. This cannot be undone.")
                }
            }
        default:
            EmptyView()
        }
    }

    static let resetAllRow = "advanced.resetAll"

    /// The rows the search finds that are not registry settings.
    static var extraRows: [SettingsViewModel.ExtraRow] {
        Hotkeys.all.map { hotkey in
            SettingsViewModel.ExtraRow(
                id: Hotkeys.rowID(hotkey.name), title: hotkey.title, summary: "Keyboard shortcut",
                pane: .general, keywords: ["hotkey", "shortcut", "keyboard"]
            )
        } + [
            SettingsViewModel.ExtraRow(
                id: resetAllRow, title: "Reset every setting", summary: "Puts every setting back to its default.",
                pane: .advanced, keywords: ["defaults", "restore", "factory"]
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
                .fill(Palette.accent.opacity(on ? 0.16 : 0))
                .padding(.horizontal, -8)
                .padding(.vertical, -5)
                .allowsHitTesting(false)
        }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
