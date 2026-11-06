// SPDX-License-Identifier: GPL-3.0-or-later
//
// The menu bar app's entry point. Everything else lives in EsclopAppKit.

import AppKit
import EsclopAppKit
import SwiftUI

@main
struct EsclopMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.services.model)
        } label: {
            MenuBarLabel(model: delegate.services.model)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: delegate.services.settingsModel)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let services = AppServices()

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try services.start()
        } catch {
            // Another copy already serves the CLI and the clipboard: one is enough.
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        services.stop()
    }
}
