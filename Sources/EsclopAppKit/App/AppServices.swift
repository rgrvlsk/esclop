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
    public let pipelinesWindow: PipelineEditorWindowController
    public let compareWindow: CompareWindowController
    public let onboarding: OnboardingWindowController
    let panels: FloatingPanelController
    let dropZone: DropZoneController
    let batchWindow: BatchWindowController
    public let folders: WatchedFolders
    private var folderSettings: DefaultsObserver?
    private var pipelineFiles: FolderWatcher?
    /// A disk with watched folders mounted or went away.
    private var volumeObservers: [NSObjectProtocol] = []
    let watcher: ClipboardWatcher
    let server: AppServer
    /// Pictures of the app's windows on request; only with ESCLOP_SNAPSHOT_DIR set.
    let snapshots = WindowSnapshots()
    /// Finder's Quick Actions (Services).
    let finderServices: FinderServices
    /// Sparkle: checks for, downloads and installs new versions.
    public let updater: Updater
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
        settingsModel.uploads = .live()
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
            supportFolder: model.service.context.locations.support,
            openPipelines: { [weak model] in model?.onOpenPipelines?(nil) }
        ))
        let pipelinesWindow = PipelineEditorWindowController(model: PipelineEditorModel(
            store: model.service.context.pipelines, app: model, settings: model.service.context.settings
        ))
        self.pipelinesWindow = pipelinesWindow
        model.onOpenPipelines = { [weak pipelinesWindow] name in pipelinesWindow?.show(name) }
        let compareWindow = CompareWindowController(model: CompareModel(app: model))
        self.compareWindow = compareWindow
        model.onCompare = { [weak compareWindow] result in compareWindow?.show(result) }
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
        onboarding = OnboardingWindowController(model: OnboardingModel(defaults: settings.defaults), settings: settingsWindow)
        server = AppServer(handler: AppIPCHandler(model: model))
        model.onCardsChange = { [weak panels] in panels?.update() }
        let batchWindow = BatchWindowController(model: model)
        self.batchWindow = batchWindow
        model.onBatch = { [weak batchWindow] batch in batchWindow?.show(batch) }
        let store = model.service.context.pipelines
        finderServices = FinderServices(model: model, pipelines: { (try? store.list()) ?? [] })
        let updater = Updater(settings: settings)
        self.updater = updater
        if Updater.isAvailable() {
            model.onCheckForUpdates = { [weak updater] in updater?.checkForUpdates() }
        }
        let folders = WatchedFolders(model: model, pipelines: { (try? store.list()) ?? [] })
        self.folders = folders
        model.onPauseChange = { [weak folders] in folders?.refresh() }
        // Folder lists changed here or by `esclop settings set` in another process.
        folderSettings = DefaultsObserver(defaults: settings.defaults, keys: WatchedFolders.settingKeys) { [weak folders] _ in
            Task { @MainActor in folders?.refresh(retryDenied: true) }
        }
        // A pipeline saved, attached to a folder or deleted (here, by the CLI or by an agent).
        pipelineFiles = FolderWatcher(everyChange: true) { [weak folders, weak pipelinesWindow] _ in
            Task { @MainActor in
                folders?.refresh()
                pipelinesWindow?.model.reload()
            }
        }
    }

    /// Starts everything. Throws when another L'Esclop already serves the CLI.
    public func start() throws {
        try server.start()
        watcher.start()
        dropZone.start()
        folders.refresh()
        PipelineEditorModel.removeLeftovers()
        try? FileManager.default.createDirectory(at: model.service.context.pipelines.directory, withIntermediateDirectories: true)
        pipelineFiles?.start([model.service.context.pipelines.directory])
        let workspace = NSWorkspace.shared.notificationCenter
        volumeObservers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map { name in
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak folders] _ in
                MainActor.assumeIsolated { folders?.refresh() }
            }
        }
        // Finder's Quick Actions come to this object; refreshing makes a new install's show at once.
        NSApp.servicesProvider = finderServices
        NSUpdateDynamicServices()
        // Shortcuts actions run in this process and use this model.
        ShortcutActions.model = model
        Hotkeys.register(model)
        updater.start()

        onboarding.showIfFirstRun()
        snapshots?.start()
        log.info("L'Esclop \(EsclopVersion.string, privacy: .public) is running")
    }

    /// Handles `esclop://` links: `esclop://settings/...` opens the Settings window there.
    public func open(_ urls: [URL]) {
        for url in urls where !settingsWindow.open(url) && !pipelinesWindow.open(url) && !compareWindow.open(url) {

            log.info("Ignored a link L'Esclop does not handle: \(url.absoluteString, privacy: .public)")
        }
    }

    public func stop() {
        server.stop()
        watcher.stop()
        dropZone.stop()
        folders.stop()
        pipelineFiles?.stop()
        volumeObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        volumeObservers = []
        snapshots?.stop()
    }
}
