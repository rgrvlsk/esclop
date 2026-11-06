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
    @Environment(\.openSettings) private var openSettings

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Text(model.status)

        Divider()

        Button("Optimise Clipboard") { model.optimiseClipboardNow(aggressive: false) }
            .globalKeyboardShortcut(.optimiseClipboard)
        Button("Optimise Clipboard Harder") { model.optimiseClipboardNow(aggressive: true) }
            .globalKeyboardShortcut(.optimiseClipboardHarder)
        Toggle("Pause Automatic Optimisation", isOn: Binding(get: { model.paused }, set: { model.setPaused($0) }))
            .globalKeyboardShortcut(.togglePause)

        Divider()

        Menu("Recent Results") {
            if model.recent.isEmpty {
                Text("Nothing optimised yet")
            }
            ForEach(model.recent.prefix(12), id: \.id) { result in
                Button(Self.line(for: result)) { model.show(result) }
            }
        }
        Menu("Restore Original") {
            let restorable = model.restorable
            if restorable.isEmpty {
                Text("No originals kept")
            }
            ForEach(restorable.prefix(12), id: \.id) { result in
                Button("\(result.source.lastPathComponent)  \(ByteSize.format(result.bytesBefore))") {
                    Task { await model.restore(result) }
                }
            }
            Divider()
            Button("Show Backups in Finder") {
                model.reveal([model.service.context.locations.backups])
            }
        }

        Divider()

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Quit L'Esclop") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// "photo.png  −72 %  1.2 MB → 340 kB"
    static func line(for result: OptimisationResult) -> String {
        "\(result.output.lastPathComponent)  \(Figures.percent(before: result.bytesBefore, after: result.bytesAfter))  \(Figures.change(before: result.bytesBefore, after: result.bytesAfter))"
    }
}
