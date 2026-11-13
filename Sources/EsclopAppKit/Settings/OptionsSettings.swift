// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Settings rows for what the options popover stores in the registry: the clipboard rules
// (Settings › Clipboard), listed with a delete button, and the hover buttons (Settings ›
// Floating results), a switch each. Both write through the view model, so the CLI, search and
// links see the same values.

import EsclopCore
import EsclopIPC
import SwiftUI

struct ClipboardRuleList: View {
    let descriptor: SettingDescriptor
    let model: SettingsViewModel
    let label: AnyView

    /// The stored JSON objects, decoded; entries that do not decode are kept but not shown.
    nonisolated static func decode(_ value: JSONValue?) -> [ClipboardRule] {
        (value?.arrayValue ?? []).compactMap(\.stringValue).compactMap { text in
            try? JSONDecoder().decode(ClipboardRule.self, from: Data(text.utf8))
        }
    }

    var body: some View {
        let stored = (descriptor.value?.arrayValue ?? []).compactMap(\.stringValue)
        VStack(alignment: .leading, spacing: 8) {
            label
            if stored.isEmpty {
                Text(Strings.text("No clipboard rules yet. Tick “Always apply” in a file’s options to make one."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(stored.enumerated()), id: \.offset) { index, text in
                if let rule = try? JSONDecoder().decode(ClipboardRule.self, from: Data(text.utf8)) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.subject())
                            Text(rule.choice.summary(input: rule.inputFormat)).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            var remaining = stored
                            remaining.remove(at: index)
                            model.set(descriptor.key, to: .array(remaining.map { .string($0) }))
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help(Strings.text("Delete"))
                        .accessibilityLabel(Strings.format("Delete the rule for %@", rule.subject()))
                    }
                }
            }
        }
    }
}
