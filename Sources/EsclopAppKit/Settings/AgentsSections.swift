// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Agents and MCP pane's own sections: the agents on this Mac with one-click connect and
// disconnect, the live server test, and the snippets for setting an agent up by hand. The four
// permission switches come from the registry, between the test and the snippets.

import EsclopCore
import EsclopIPC
import EsclopMCP
import SwiftUI

/// Agents found on this Mac, then the others in a folded group.
struct AgentsConnectSection: View {
    let agents: AgentsModel
    let model: SettingsViewModel
    let actions: SettingsActions
    @State private var showsOthers = false

    var body: some View {
        Section {
            if !agents.loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else if agents.command == nil {
                Label(AgentsModel.noCommand, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if agents.loaded, agents.found.isEmpty {
                Text(Strings.text("No agents found on this Mac. Pick one below to set it up anyway, or copy a snippet at the end of this pane."))
                    .foregroundStyle(.secondary)
            }
            ForEach(agents.found) { row in
                AgentRow(row: row, agents: agents, model: model, actions: actions)
            }
            if !agents.notFound.isEmpty {
                // A button, not a DisclosureGroup: in a grouped form the disclosure did not answer
                // VoiceOver's press, and "Expand" was not one of its actions.
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { showsOthers.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(showsOthers ? 90 : 0))
                            .foregroundStyle(.secondary)
                        Text(Strings.format("Not found on this Mac (%d)", agents.notFound.count))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsOthers ? Strings.text("Expanded") : Strings.text("Collapsed"))
                .accessibilityAction(named: showsOthers ? Strings.text("Collapse") : Strings.text("Expand")) { showsOthers.toggle() }
                if showsOthers {
                    ForEach(agents.notFound) { row in
                        AgentRow(row: row, agents: agents, model: model, actions: actions)
                    }
                }
            }
        } header: {
            Text(Strings.text("Connect an agent"))
        } footer: {
            Text(Strings.text("Connecting adds an esclop entry to the agent's own config file and nothing else. You see the change before it is written, and the previous version is kept in L'Esclop's folder."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                // Grouped forms put footers on the trailing side; these read with the rows above.
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { if !agents.loaded { await agents.refresh() } }
        .sheet(item: Binding(get: { agents.pending.map(PendingChange.init) }, set: { if $0 == nil { agents.cancel() } })) { pending in
            ConfigChangeSheet(change: pending.change, onCancel: agents.cancel) {
                Task { await agents.confirm() }
            }
        }
        .onChange(of: model.highlighted) {
            // A link to an agent that is not on this Mac opens the folded group.
            if let row = model.highlighted, agents.notFound.contains(where: { AgentRow.rowID($0.agent) == row }) { showsOthers = true }
        }
    }

    struct PendingChange: Identifiable {
        let change: ConfigChange
        var id: String { change.agentID + change.action.rawValue }
    }
}

struct AgentRow: View {
    let row: AgentsModel.Row
    let agents: AgentsModel
    let model: SettingsViewModel
    let actions: SettingsActions

    static func rowID(_ agent: AgentDefinition) -> String { "agent.\(agent.id)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                buttons
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    stateIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.agent.name)
                        Text(stateText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // The agent's name first, then its state: VoiceOver read the state alone.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.accessibilityLabel(name: row.agent.name, state: stateText))
            }
            switch agents.outcomes[row.id] {
            case let .done(text)?:
                Label(text, systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Palette.accent)
            case let .failed(text)?:
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            case nil:
                EmptyView()
            }
        }
        .id(Self.rowID(row.agent))
        .highlighted(model.highlighted == Self.rowID(row.agent))
    }

    static func accessibilityLabel(name: String, state: String) -> String { "\(name): \(state)" }

    @ViewBuilder private var stateIcon: some View {
        switch row.status.state {
        case .installed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
                .accessibilityLabel(Strings.text("Connected"))
        case .different:
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill").foregroundStyle(Palette.warm)
                .accessibilityLabel(Strings.text("Runs another esclop"))
        case .unreadable:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                .accessibilityLabel(Strings.text("Config unreadable"))
        case .absent, .manual:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                .accessibilityLabel(Strings.text("Not connected"))
        }
    }

    var stateText: String {
        let path = row.status.configPath ?? ""
        switch row.status.state {
        case .installed: return Strings.format("Connected in %@", path)
        case .different: return Strings.format("Runs another esclop: %@. Update it to this one.", row.status.command?.command ?? "?")
        case .absent: return row.status.present ? Strings.format("Not connected. %@", path) : Strings.format("Not found on this Mac. %@", path)
        case .unreadable: return Strings.format("%@ does not parse, so it is left alone: %@", path, row.status.detail ?? "")
        case .manual: return Strings.text("Configured in Warp's own settings: Settings → AI → MCP Servers → Add, then paste the JSON.")
        }
    }

    @ViewBuilder private var buttons: some View {
        switch row.status.state {
        case .installed:
            Button(Strings.text("Disconnect…")) { agents.disconnect(row.agent) }
        case .different:
            HStack {
                Button(Strings.text("Disconnect…")) { agents.disconnect(row.agent) }
                Button(Strings.text("Update…")) { agents.connect(row.agent) }
                    .disabled(agents.command == nil)
            }
        case .absent:
            Button(Strings.text("Connect…")) { agents.connect(row.agent) }
                .disabled(agents.command == nil)
        case .unreadable:
            Button(Strings.text("Show in Finder")) {
                if let path = row.status.configPath { actions.reveal(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) }
            }
        case .manual:
            Button(Strings.text("Copy JSON")) { if let json = agents.manualJSON { actions.copy(json) } }
                .disabled(agents.manualJSON == nil)
        }
    }
}

/// The exact edit, as a diff, before anything is written.
struct ConfigChangeSheet: View {
    let change: ConfigChange
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var verb: String { change.action == .install ? Strings.text("Connect") : Strings.text("Disconnect") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(change.action == .install ? Strings.format("Connect %@", change.agentName) : Strings.format("Disconnect %@", change.agentName))
                .font(.title2.weight(.semibold))
            Text(explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DiffView(lines: change.diff())
            HStack {
                Spacer()
                Button(Strings.text("Cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(verb, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(change.action == .install ? Palette.accent : .red)
            }
        }
        .padding(20)
        .frame(width: 560)
        .tint(Palette.accent)
    }

    var explanation: String {
        var text = change.removesFile
            ? Strings.format("L'Esclop created %@ when it connected, and the file holds nothing else, so it will be removed.", change.shownPath)
            : change.fileExists
            ? Strings.format("L'Esclop will edit %@. Only the esclop entry changes: other servers, comments and formatting stay as they are.", change.shownPath)
            : Strings.format("%@ does not exist yet. L'Esclop will create it with only the esclop entry.", change.shownPath)
        if let backup = change.shownBackup {
            text += " " + Strings.format("The current version is kept as %@.", backup)
        }
        return text
    }
}

struct DiffView: View {
    let lines: [DiffLine]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // The whole splice in view: lines wrap instead of scrolling sideways, and a short change
        // is shown whole; only a long one scrolls.
        Group {
            if lines.count <= Self.shownWhole {
                content
            } else {
                ScrollView(.vertical) { content }.frame(height: 420)
            }
        }
        .font(.system(.callout, design: .monospaced))
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Strings.format("Change to the config: %d lines added, %d removed", lines.filter { $0.kind == .added }.count, lines.filter { $0.kind == .removed }.count))
    }

    /// Changes up to this many lines show without scrolling.
    static let shownWhole = 24

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                row(line)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func row(_ line: DiffLine) -> some View {
        switch line.kind {
        case .skipped:
            Text(line.skipped == 1 ? Strings.text("⋯ 1 unchanged line") : Strings.format("⋯ %d unchanged lines", line.skipped))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
        default:
            HStack(spacing: 8) {
                Text(line.number.map(String.init) ?? "")
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 32, alignment: .trailing)
                Text(sign(line.kind))
                    .foregroundStyle(tint(line.kind) ?? .secondary)
                    .accessibilityHidden(true)
                Text(line.text.isEmpty ? " " : line.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint(line.kind).map { $0.opacity(colorScheme == .dark ? 0.22 : 0.12) } ?? .clear)
        }
    }

    func sign(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        default: return " "
        }
    }

    func tint(_ kind: DiffLine.Kind) -> Color? {
        switch kind {
        case .added: return Palette.accent
        case .removed: return .red
        default: return nil
        }
    }
}

/// Starts the server the way agents do and reports what it answered.
struct AgentsTestSection: View {
    let agents: AgentsModel

    var body: some View {
        Section(Strings.text("Test the server")) {
            LabeledContent {
                Button(agents.probe == .running ? Strings.text("Testing…") : Strings.text("Run Test")) {
                    Task { await agents.test() }
                }
                .disabled(agents.probe == .running)
            } label: {
                SettingLabel(title: Strings.text("Talk to the MCP server"), summary: Strings.text("Starts esclop mcp serve as an agent would, then asks for its tools and status."))
            }
            .id(Self.rowID)
            switch agents.probe {
            case .idle:
                EmptyView()
            case .running:
                ProgressView().controlSize(.small)
            case let .passed(report):
                Label(AgentsModel.summary(of: report), systemImage: "checkmark.circle.fill")

                    .foregroundStyle(Palette.accent)
                    .monospacedDigit()
            case let .failed(why):
                Label(why, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    static let rowID = "agents.test"
}

/// What to paste into an agent L'Esclop cannot set up itself.
struct AgentsManualSection: View {
    let agents: AgentsModel
    let actions: SettingsActions

    var body: some View {
        Section {
            ForEach(agents.snippets) { snippet in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(snippet.title)
                        Spacer()
                        Button(Strings.text("Copy")) { actions.copy(snippet.text) }
                            .accessibilityLabel(Strings.format("Copy %@", snippet.title))
                    }
                    Text(snippet.text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .id("agents.snippet.\(snippet.id)")
            }
        } header: {
            Text(Strings.text("Set up by hand"))
        } footer: {
            Text(Strings.text("Agents start the server with this command and talk to it over standard input and output. Each agent keeps it in its own settings file; Connect above writes it for you."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
