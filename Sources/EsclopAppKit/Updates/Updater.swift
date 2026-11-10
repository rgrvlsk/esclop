// SPDX-License-Identifier: GPL-3.0-or-later
//
// Updates through Sparkle: an appcast (SUFeedURL in Info.plist) lists the newest release, whose
// DMG is signed with the EdDSA key the app carries (SUPublicEDKey). The two registry settings
// drive Sparkle's own switches, and a choice made in Sparkle's update window ("Automatically
// download and install updates in the future") is written back to them, so the Settings window,
// `esclop settings` and Sparkle always agree. See docs/release.md › Updates.

import AppKit
import EsclopCore
import Foundation
import os
import Sparkle

@MainActor
public final class Updater: NSObject {
    /// A feed to use instead of Info.plist's, read once at launch (end-to-end tests serve one).
    public static let feedEnvironmentKey = "ESCLOP_UPDATE_FEED"

    private let settings: SettingsStore
    let feedOverride: String?
    private var controller: SPUStandardUpdaterController?
    private var settingsObserver: DefaultsObserver?
    private var sparkleObservers: [NSKeyValueObservation] = []
    private let log = Logger(subsystem: Paths.bundleIdentifier, category: "updates")

    public init(settings: SettingsStore, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.settings = settings
        feedOverride = Self.feedOverride(in: environment)
        super.init()
    }

    /// Updates need a bundle that carries the public key; `swift run` and tests have none.
    public static func isAvailable(in bundle: Bundle = .main) -> Bool {
        (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String).map { !$0.isEmpty } ?? false
    }

    public var isRunning: Bool { controller != nil }

    /// Starts Sparkle: scheduled checks follow the settings from here on.
    public func start() {
        guard controller == nil, Self.isAvailable() else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        attach(controller.updater)
        do {
            try controller.updater.start()
        } catch {
            log.error("Sparkle did not start: \(error.localizedDescription, privacy: .public)")
            return
        }
        if let feedOverride { log.info("Update feed from \(Self.feedEnvironmentKey): \(feedOverride, privacy: .public)") }
    }

    /// Ties an updater's switches to the settings, both ways. Separate from `start()` so tests
    /// can attach an updater that never checks.
    func attach(_ updater: SPUUpdater) {
        apply(to: updater)
        // Settings changed here or by `esclop settings set` in another process.
        settingsObserver = DefaultsObserver(defaults: settings.defaults, keys: Self.settingKeys) { [weak self, weak updater] _ in
            Task { @MainActor in if let updater { self?.apply(to: updater) } }
        }
        // Sparkle's update window has its own "install automatically" box: keep the setting with
        // it. KVO reports Sparkle's changes on the main thread, where Sparkle makes them.
        sparkleObservers = [
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.store(EsclopSettings.checkForUpdatesAutomatically, updater.automaticallyChecksForUpdates) }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.store(EsclopSettings.installUpdatesAutomatically, updater.automaticallyDownloadsUpdates) }
            },
        ]
    }

    /// The feed ESCLOP_UPDATE_FEED names, when it is set and not empty.
    static func feedOverride(in environment: [String: String]) -> String? {
        environment[feedEnvironmentKey].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The menu's "Check for Updates…": Sparkle's window, with what it found.
    public func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    static let settingKeys = [EsclopSettings.checkForUpdatesAutomatically.key, EsclopSettings.installUpdatesAutomatically.key]

    private func apply(to updater: SPUUpdater) {
        let check = EsclopSettings.checkForUpdatesAutomatically.value(in: settings)
        let install = EsclopSettings.installUpdatesAutomatically.value(in: settings)
        if updater.automaticallyChecksForUpdates != check { updater.automaticallyChecksForUpdates = check }
        if updater.automaticallyDownloadsUpdates != install { updater.automaticallyDownloadsUpdates = install }
    }

    private func store(_ setting: Setting<Bool>, _ value: Bool) {
        guard setting.value(in: settings) != value else { return }
        try? setting.set(value, in: settings)
    }
}

extension Updater: SPUUpdaterDelegate {
    public nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        feedOverride
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    // A menu bar app has no window in front: Sparkle's window is brought forward when it shows.
    public nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    public nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard handleShowingUpdate else { return }
        MainActor.assumeIsolated { NSApp.activate() }
    }
}
