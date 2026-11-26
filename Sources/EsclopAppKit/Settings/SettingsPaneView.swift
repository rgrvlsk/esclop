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
                if pane == .agents, let agents {
                    Section {
                        Text(Strings.text("AI agents such as Claude, Codex and Cursor use L’Esclop through its MCP server: they can optimise, convert and crop files, and write pipelines. Connect an agent here, then restart it."))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    AgentsConnectSection(agents: agents, model: model, actions: actions)
                    AgentsTestSection(agents: agents)
                }
                ForEach(model.groups(in: pane)) { group in
                    panel(group)
                }
                extras
            }
            .formStyle(.grouped)
            // The pane's one heading, on the window's ground above the panels; the panels'
            // group labels all keep the form's own style.
            .safeAreaInset(edge: .top, spacing: 0) {
                PaneHeading(pane: pane)
                    .padding(.horizontal, Spacing.xl)
                    .padding(.top, Spacing.s)
            }
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

    /// A panel: its heading (with its switch and chevron when it opens and closes), then its
    /// rows while it is open.
    @ViewBuilder private func panel(_ group: SettingsViewModel.Group) -> some View {
        let panel = group.panel
        Section {
            if panel.collapsible {
                PanelHeading(group: group, model: model, actions: actions, status: PanelStatus.text(for: panel, model: model))
            }
            if model.isOpen(panel) {
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
                if !kinds.isEmpty {
                    KindChecks(keys: kinds, model: model, actions: actions)
                }
                ForEach(group.settings.filter { !kinds.contains($0.key) && SettingsViewModel.editedIn[$0.key] == nil }, id: \.key) { setting in
                    SettingRow(descriptor: setting, model: model, actions: actions)
                }
            }
        } header: {
            if !panel.collapsible, let heading = panel.title { Text(heading) }
        } footer: {
            if let footer = pane.footer(for: panel) {
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

    @ViewBuilder private var extras: some View {
        switch pane {
        case .automatic:
            if let openPipelines = actions.openPipelines {
                Section {
                    LabeledContent {
                        Button(Strings.text("Open the Pipeline Editor…")) { openPipelines() }
                    } label: {
                        SettingLabel(title: Strings.text("Pipelines"), summary: Strings.text("Make and change pipelines: their steps, what runs them and a filter, with Try it."))
                    }
                }
            }
        case .advanced:
            if let store = actions.settingsStore {
                Section(Strings.text("Settings file")) {
                    LabeledContent {
                        HStack {
                            Button(Strings.text("Export…")) { SettingsFilePanels.export(store) }
                            Button(Strings.text("Import…")) { SettingsFilePanels.import(into: store) }
                        }
                    } label: {
                        SettingLabel(
                            title: Strings.text("Settings on another Mac"),
                            summary: Strings.text("Export saves the settings you changed as a file; Import reads it on the other Mac. Pipelines, hotkeys and upload keys stay on this Mac.")
                        )
                    }
                    .markable(Self.settingsFileRow)
                }
            }
            Section(Strings.text("Maintenance")) {
                LabeledContent {
                    Button(Strings.text("Copy")) { actions.copy("esclop settings schema") }
                } label: {
                    SettingLabel(
                        title: Strings.text("The same settings in Terminal"),
                        summary: Strings.text("esclop settings schema lists them, esclop settings set and reset change them. The window follows.")
                    )
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
                .font(Typeface.heading)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Text(pane.subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
        }
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

    var body: some View {
        let panel = group.panel
        let open = model.isOpen(panel)
        HStack(spacing: Spacing.m) {
            Button(action: toggle) {
                HStack(spacing: Spacing.m) {
                    if let symbol = panel.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 15))
                            .foregroundStyle(Ink.charcoalText)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(NeutralFill.resting))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(panel.title ?? "")
                            .font(Typeface.title)
                        if let status {
                            Text(status)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(panel.title ?? "")
            .accessibilityValue([status, open ? Strings.text("open") : Strings.text("closed")].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint(open ? Strings.text("Hides its settings") : Strings.text("Shows its settings"))
            if let setting = group.switchSetting {
                Toggle(isOn: Binding(get: { setting.value?.boolValue ?? false }, set: { model.set(setting.key, to: .bool($0)) })) {
                    Text(setting.title)
                }
                .switchLabel(title: setting.title, hint: setting.summary)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Ink.charcoal)
                .help(setting.summary)
                .markable(setting.key)
                .settingMenu(setting, model: model, actions: actions)
            }
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: Spacing.hit, height: Spacing.hit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { model.toggle(group.panel) }
    }
}

/// The line under a panel's name: what it does now, in a few words.
enum PanelStatus {
    @MainActor static func text(for panel: SettingsPanel, model: SettingsViewModel) -> String? {
        typealias S = EsclopSettings
        if let key = panel.switchKey, model.value(key)?.boolValue == false { return Strings.text("Off") }
        switch panel.id {
        case "automatic.clipboard":
            let kinds = KindChecks.keys(in: panel).filter { model.value($0)?.boolValue == true }.map(KindChecks.name)
            return kinds.isEmpty ? Strings.text("Off") : list(kinds)
        case "automatic.images", "automatic.video", "automatic.pdf", "automatic.audio":
            let count = panel.keys.first.flatMap { model.value($0)?.arrayValue?.count } ?? 0
            switch count {
            case 0: return Strings.text("No folders yet")
            case 1: return Strings.text("Watching 1 folder")
            default: return Strings.format("Watching %d folders", count)
            }
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
    let model: SettingsViewModel
    let actions: SettingsActions

    /// The kinds a panel shows as round checks instead of switches.
    static func keys(in panel: SettingsPanel) -> [String] {
        guard panel.id == "automatic.clipboard" else { return [] }
        typealias S = EsclopSettings
        return [S.enableClipboardOptimiser.key, S.optimiseVideoClipboard.key, S.optimisePDFClipboard.key, S.optimiseAudioClipboard.key]
    }

    static func name(_ key: String) -> String {
        typealias S = EsclopSettings
        switch key {
        case S.enableClipboardOptimiser.key: return Strings.text("Images")
        case S.optimiseVideoClipboard.key: return Strings.text("Videos")
        case S.optimisePDFClipboard.key: return Strings.text("PDFs")
        default: return Strings.text("Audio")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(Strings.text("What to optimise"))
                .sectionLabel()
            HStack(spacing: Spacing.xl) {
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

    var body: some View {
        let on = setting.value?.boolValue ?? false
        Button {
            model.set(setting.key, to: .bool(!on))
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(on ? AnyShapeStyle(Ink.charcoal) : AnyShapeStyle(NeutralFill.button))
                    Circle().strokeBorder(Ink.secondary.opacity(0.35), lineWidth: on ? 0 : 1)
                    if on {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Ink.onCharcoal)
                    }
                }
                .frame(width: 36, height: 36)
                Text(name)
                    .sectionLabel()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
