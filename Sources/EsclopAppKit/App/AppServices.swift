// SPDX-License-Identifier: GPL-3.0-or-later
//
// Everything the menu bar app runs, started once at launch: the model, the floating results,
// the drop zone, the clipboard watcher, the hotkeys and the IPC server for the CLI and MCP.

import AppKit
import EsclopCore
import EsclopIPC
import EsclopOptimisers
import Foundation
import os

@MainActor
public final class AppServices {
    public let model: AppModel
    public let settingsModel: SettingsViewModel
    public let settingsWindow: SettingsWindowController
    let panels: FloatingPanelController
    let dropZone: DropZoneController
    let watcher: ClipboardWatcher
    let server: AppServer
    private let log = Logger(subsystem: Paths.bundleIdentifier, category: "app")

    public init(settings: SettingsStore = .shared) {
        let model = AppModel(settings: settings, service: AppModel.makeService(settings: settings))
        self.model = model
        let settingsModel = SettingsViewModel(
            provider: model.service.context.settings, defaults: settings.defaults, extraRows: SettingsPaneView.extraRows
        ) { [weak model] key, value in
            if key == EsclopSettings.pauseAutomaticOptimisations.key { model?.pauseChanged(value.boolValue ?? false) }
            if key == EsclopSettings.hoverButtons.key { model?.hoverButtonsChanged() }
        }
        self.settingsModel = settingsModel
        settingsWindow = SettingsWindowController(model: settingsModel, agents: AgentsModel(), actions: SettingsActions(
            reveal: { [weak model] in model?.reveal([$0]) },
            copy: { text in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                // Marked as L'Esclop's own write, so the clipboard watcher leaves it alone.
                pasteboard.declareTypes([.string, Clipboard.optimisedType], owner: nil)
                pasteboard.setString(text, forType: .string)
                pasteboard.setData(Data(), forType: Clipboard.optimisedType)
            },
            supportFolder: model.service.context.locations.support
        ))
        let panels = FloatingPanelController(model: model)
        self.panels = panels
        dropZone = DropZoneController(model: model) { [weak panels] in panels?.visibleFrame }
        watcher = ClipboardWatcher(
            policy: ClipboardPolicy(factory: model.factory),
            onPauseChange: { [weak model] paused in
                Task { @MainActor in if model?.paused != paused { model?.pauseChanged(paused) } }
            },
            onAction: { [weak model] action in
                Task { @MainActor in model?.handleClipboard(action) }
            }
        )
        server = AppServer(handler: AppIPCHandler(model: model))
        model.onCardsChange = { [weak panels] in panels?.update() }
    }

    /// Starts everything. Throws when another L'Esclop already serves the CLI.
    public func start() throws {
        try server.start()
        watcher.start()
        dropZone.start()
        Hotkeys.register(model)
        log.info("L'Esclop \(EsclopVersion.string, privacy: .public) is running")
    }

    /// Handles `esclop://` links: `esclop://settings/...` opens the Settings window there.
    public func open(_ urls: [URL]) {
        for url in urls where !settingsWindow.open(url) {
            log.info("Ignored a link L'Esclop does not handle: \(url.absoluteString, privacy: .public)")
        }
    }

    public func stop() {
        server.stop()
        watcher.stop()
        dropZone.stop()
    }
}
