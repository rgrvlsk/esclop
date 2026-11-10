// SPDX-License-Identifier: GPL-3.0-or-later
//
// The menu bar menu: status, the clipboard commands, pause, recent results, originals to
// restore, settings and quit.

import EsclopCore
import EsclopIPC
import KeyboardShortcuts
import SwiftUI

public struct MenuContent: View {
    let model: AppModel
    let settings: SettingsWindowController
    let onboarding: OnboardingWindowController?

    public init(model: AppModel, settings: SettingsWindowController, onboarding: OnboardingWindowController? = nil) {
        self.model = model
        self.settings = settings
        self.onboarding = onboarding
    }

    public var body: some View {
        Text(model.status)
        if let folders = Self.foldersLine(count: model.watchedFolderCount, paused: model.paused) {
            Text(folders)
        }

        Divider()

        Button(Strings.text("Optimise Files…")) { model.chooseFiles() }
            .keyboardShortcut("o")
        if model.batch != nil {
            Button(Strings.text("Show Batch Window")) { model.showBatch() }
        }
        Button(Strings.text("Optimise Clipboard")) { model.optimiseClipboardNow(aggressive: false) }
            .globalKeyboardShortcut(.optimiseClipboard)
        Button(Strings.text("Optimise Clipboard Harder")) { model.optimiseClipboardNow(aggressive: true) }
            .globalKeyboardShortcut(.optimiseClipboardHarder)
        Toggle(Strings.text("Pause Automatic Optimisation"), isOn: Binding(get: { model.paused }, set: { model.setPaused($0) }))
            .globalKeyboardShortcut(.togglePause)

        Divider()

        Menu(Strings.text("Recent Results")) {
            if model.recent.isEmpty {
                Text(Strings.text("Nothing optimised yet"))
            }
            ForEach(model.recent.prefix(12), id: \.id) { result in
                Button(Self.line(for: result)) { model.show(result) }
            }
        }
        Menu(Strings.text("Compare")) {
            let comparable = model.recent.filter { $0.backup != nil || $0.output.standardizedFileURL != $0.source.standardizedFileURL }
            if comparable.isEmpty {
                Text(Strings.text("Nothing to compare yet"))
            }
            ForEach(comparable.prefix(12), id: \.id) { result in
                Button(Self.line(for: result)) { model.onCompare?(result) }
            }
        }

        Menu(Strings.text("Restore Original")) {
            let restorable = model.restorable
            if restorable.isEmpty {
                Text(Strings.text("No originals kept"))
            }
            ForEach(restorable.prefix(12), id: \.id) { result in
                Button("\(result.source.lastPathComponent)  \(Figures.bytes(result.bytesBefore))") {
                    Task { await model.restore(result) }
                }
            }
            Divider()
            Button(Strings.text("Show Backups in Finder")) {
                model.reveal([model.service.context.locations.backups])
            }
        }

        Divider()

        if let onboarding {
            Button(Strings.text("Welcome to L'Esclop…")) { onboarding.show() }
        }
        Button(Strings.text("Pipelines…")) { model.onOpenPipelines?(nil) }
        Button(Strings.text("Settings…")) { settings.show() }
        .keyboardShortcut(",")
        Button(Strings.text("Quit L'Esclop")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// "photo.png  −72 %  1.2 MB → 340 kB"
    static func line(for result: OptimisationResult) -> String {
        "\(result.output.lastPathComponent)  \(Figures.percent(before: result.bytesBefore, after: result.bytesAfter))  \(Figures.change(before: result.bytesBefore, after: result.bytesAfter))"
    }

    /// "Watching 2 folders", or nothing while paused or with no folder to watch.
    static func foldersLine(count: Int, paused: Bool) -> String? {
        guard !paused, count > 0 else { return nil }
        return count == 1 ? Strings.text("Watching 1 folder") : Strings.format("Watching %d folders", count)
    }
}
