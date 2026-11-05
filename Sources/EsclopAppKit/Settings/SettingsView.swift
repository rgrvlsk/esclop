// SPDX-License-Identifier: GPL-3.0-or-later
//
// A minimal Settings window: search at the top, every registry setting in its section with a
// native control, and the hotkey recorders. The full window with a sidebar is planned.

import EsclopCore
import EsclopIPC
import KeyboardShortcuts
import SwiftUI

public struct SettingsView: View {
    @State private var model: SettingsViewModel

    public init(model: SettingsViewModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        Form {
            Section("Hotkeys") {
                ForEach(Hotkeys.all, id: \.name.rawValue) { hotkey in
                    KeyboardShortcuts.Recorder(hotkey.title, name: hotkey.name)
                }
            }
            ForEach(model.groups) { group in
                Section(group.section.title) {
                    ForEach(group.settings, id: \.key) { setting in
                        SettingRow(setting: setting, error: model.errors[setting.key]) { model.set(setting.key, to: $0) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search settings")
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 640)
        .onAppear { model.reload() }
    }
}

private struct SettingRow: View {
    let setting: SettingDescriptor
    let error: String?
    let set: (String) -> Bool

    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .help(setting.summary)
        .onAppear { text = SettingsViewModel.text(for: setting.value) }
        .onChange(of: setting.value) { text = SettingsViewModel.text(for: setting.value) }
    }

    @ViewBuilder private var control: some View {
        switch setting.type {
        case .bool:
            Toggle(isOn: Binding(get: { setting.value?.boolValue ?? false }, set: { _ = set($0 ? "true" : "false") })) {
                label
            }
        case .choice:
            Picker(selection: Binding(get: { setting.value?.stringValue ?? "" }, set: { _ = set($0) })) {
                ForEach(setting.choices ?? [], id: \.self) { Text(Self.words($0)).tag($0) }
            } label: {
                label
            }
        case .int, .double, .string:
            LabeledContent {
                TextField(setting.title, text: $text)
                    .labelsHidden()
                    .multilineTextAlignment(setting.type == .string ? .leading : .trailing)
                    .monospacedDigit()
                    .frame(maxWidth: setting.type == .string ? 240 : 90)
                    .onSubmit { _ = set(text) }
            } label: {
                label
            }
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(setting.title)
            Text(setting.summary).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// "bottomRight" reads "Bottom right".
    static func words(_ raw: String) -> String {
        var out = ""
        for character in raw {
            if character.isUppercase { out += " " + character.lowercased() } else { out.append(character) }
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }
}
