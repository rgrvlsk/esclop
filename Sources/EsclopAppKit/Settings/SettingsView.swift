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
        NavigationSplitView {
            SettingsSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            SettingsPaneView(pane: model.pane, model: model, agents: agents, actions: actions)
                .navigationTitle(model.pane.title)
        }
        .searchable(text: $model.query, placement: .sidebar, prompt: Strings.text("Search settings"))
        .frame(minWidth: 720, idealWidth: 800, minHeight: 480, idealHeight: 620)
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

    public init(
        reveal: @escaping @MainActor (URL) -> Void = { _ in }, copy: @escaping @MainActor (String) -> Void = { _ in },
        supportFolder: URL? = nil, openPipelines: (@MainActor () -> Void)? = nil
    ) {
        self.reveal = reveal
        self.copy = copy
        self.supportFolder = supportFolder
        self.openPipelines = openPipelines
    }
}

struct SettingsSidebar: View {
    @Bindable var model: SettingsViewModel
    @State private var hit: String?

    var body: some View {
        list.onChange(of: model.query) { hit = nil }
    }

    @ViewBuilder private var list: some View {
        if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            List(selection: $model.pane) {
                ForEach(SettingsPane.allCases) { pane in
                    Label(pane.title, systemImage: pane.symbol).tag(pane)
                }
            }
        } else {
            let hits = model.hits
            if hits.isEmpty {
                ContentUnavailableView.search(text: model.query)
            } else {
                List(selection: $hit) {
                    ForEach(SettingsPane.allCases.filter { pane in hits.contains { $0.pane == pane } }) { pane in
                        Section(pane.title) {
                            ForEach(hits.filter { $0.pane == pane }) { found in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(found.title)
                                        .lineLimit(2)
                                    Text(found.summary)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .padding(.vertical, 2)
                                .tag(found.id)
                            }
                        }
                    }
                }
                .onChange(of: hit) {
                    if let id = hit, let found = hits.first(where: { $0.id == id }) { model.open(found) }
                }
            }
        }
    }
}
