// SPDX-License-Identifier: GPL-3.0-or-later

import EsclopCore
import Foundation
import Sparkle
import Testing
@testable import EsclopAppKit

/// A bundle Sparkle accepts as a host: an Info.plist with a version, a feed and a public key,
/// and an identifier of its own, whose defaults domain is removed afterwards.
final class UpdaterHost: @unchecked Sendable {
    let temp = TempDir()
    let identifier = "dev.esclop.app-tests.updater-\(UUID().uuidString)"
    let bundle: Bundle

    init() {
        let contents = temp.url.appendingPathComponent("Host.app/Contents", isDirectory: true)
        try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleName": "Host", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "1",
            "SUFeedURL": "https://example.invalid/appcast.xml",
            // Any non-empty key: these tests never verify a signature.
            "SUPublicEDKey": "test-key",
        ]
        let data = try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try! data.write(to: contents.appendingPathComponent("Info.plist"))
        bundle = Bundle(url: contents.deletingLastPathComponent())!
    }

    deinit { UserDefaults.standard.removePersistentDomain(forName: identifier) }
}

@MainActor
@Suite(.serialized) struct UpdaterTests {
    @Test func theFeedComesFromTheEnvironmentOnlyWhenSet() {
        #expect(Updater.feedOverride(in: [:]) == nil)
        #expect(Updater.feedOverride(in: ["ESCLOP_UPDATE_FEED": ""]) == nil)
        #expect(Updater.feedOverride(in: ["ESCLOP_UPDATE_FEED": "http://127.0.0.1:8123/appcast.xml"]) == "http://127.0.0.1:8123/appcast.xml")
        let settings = TestSettings()
        let updater = Updater(settings: settings.store, environment: ["ESCLOP_UPDATE_FEED": "http://127.0.0.1:1/a.xml"])
        #expect(updater.feedOverride == "http://127.0.0.1:1/a.xml")
        #expect(Updater(settings: settings.store, environment: [:]).feedOverride == nil)
    }

    @Test func updatesNeedABundleWithThePublicKey() {
        // The test runner has no key; a bundled app does.
        #expect(!Updater.isAvailable(in: .main))
        let host = UpdaterHost()
        #expect(Updater.isAvailable(in: host.bundle))
        // Without the key, nothing starts and the menu offers no check.
        let services = AppServices(settings: TestSettings().store)
        #expect(services.model.onCheckForUpdates == nil)
        services.updater.start()
        #expect(!services.updater.isRunning)
    }

    @Test func theSettingsAndSparkleSwitchesFollowEachOther() async throws {
        let host = UpdaterHost()
        let settings = TestSettings()
        let sparkle = SPUUpdater(hostBundle: host.bundle, applicationBundle: host.bundle, userDriver: SPUStandardUserDriver(hostBundle: host.bundle, delegate: nil), delegate: nil)
        let updater = Updater(settings: settings.store, environment: [:])
        updater.attach(sparkle)
        // The defaults: check daily, ask before installing.
        #expect(sparkle.automaticallyChecksForUpdates)
        #expect(!sparkle.automaticallyDownloadsUpdates)

        // A setting changed (Settings window, `esclop settings set`) reaches Sparkle.
        try EsclopSettings.installUpdatesAutomatically.set(true, in: settings.store)
        #expect(await eventually(.seconds(5)) { sparkle.automaticallyDownloadsUpdates })
        try EsclopSettings.checkForUpdatesAutomatically.set(false, in: settings.store)
        #expect(await eventually(.seconds(5)) { !sparkle.automaticallyChecksForUpdates })

        // Sparkle's own box in its update window reaches the setting.
        sparkle.automaticallyDownloadsUpdates = false
        #expect(await eventually(.seconds(5)) { !EsclopSettings.installUpdatesAutomatically.value(in: settings.store) })
        sparkle.automaticallyChecksForUpdates = true
        #expect(await eventually(.seconds(5)) { EsclopSettings.checkForUpdatesAutomatically.value(in: settings.store) })
    }

    @Test func installingDependsOnChecking() {
        #expect(SettingPresentation.dependsOn[EsclopSettings.installUpdatesAutomatically.key] == EsclopSettings.checkForUpdatesAutomatically.key)
        #expect(SettingsPane.pane(for: .updates) == .general)
        #expect(EsclopSettings.all.contains { $0.key == EsclopSettings.checkForUpdatesAutomatically.key })
    }
}
