// SPDX-License-Identifier: GPL-3.0-or-later
//
// What runs a pipeline on its own: the switches for each source and the watched folders.

import AppKit
import EsclopCore
import EsclopIPC
import EsclopPipelines
import SwiftUI

struct PipelineTriggersSection: View {
    @Bindable var model: PipelineEditorModel

    static let simple: [PipelineTrigger] = [.clipboard, .dropZone, .presetZone, .rightClick, .cli, .mcp]

    var body: some View {
        Section {
            ForEach(Self.simple, id: \.self) { trigger in
                Toggle(PipelineVocabulary.triggerTitle(trigger.name), isOn: $model.draft[trigger: trigger])
            }
            ForEach(model.draft.folders, id: \.self) { folder in
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Strings.text("New files in a folder"))
                        Text(folder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if FolderStatus.check(WatchPlan.canonical(folder)) != .watching {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.caution)
                            .help(Strings.text("This folder cannot be watched now."))
                            .accessibilityLabel(Strings.text("This folder cannot be watched now."))
                    }
                    Button(Strings.text("Stop Watching"), systemImage: "minus.circle") {
                        model.draft.set(.folder(folder), on: false)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Strings.format("Stop watching %@", folder))
                }
            }
            Button(Strings.text("Watch a Folder…"), systemImage: "plus") { addFolder() }
                .buttonStyle(.borderless)
        } header: {
            Text(Strings.text("Runs on its own for"))
        } footer: {
            Text(Strings.text("A pipeline also runs when you choose it: from a result’s Share tab, with Run on Files…, or in Terminal with esclop pipeline run."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = Strings.text("Watch")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { model.draft.set(.folder(PathInput.abbreviate(url)), on: true) }
    }
}
