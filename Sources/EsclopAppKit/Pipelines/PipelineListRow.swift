// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A pipeline in the editor's list: its icon and name, and a mark for a file with errors. An
/// example has no padlock: opening it offers Make It Mine.
struct PipelineListRow: View {
    let name: String
    let icon: String
    let problem: String?
    let isTemplate: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon.isEmpty ? "wand.and.rays" : icon)
                .frame(width: 18)
                .foregroundStyle(Ink.charcoalText)
                .accessibilityHidden(true)
            Text(name).lineLimit(1)
            Spacer()
            if problem != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.caution).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var label: String {
        if let problem { return Strings.format("%@, %@", name, problem) }
        return isTemplate ? Strings.format("%@, example", name) : name
    }
}
