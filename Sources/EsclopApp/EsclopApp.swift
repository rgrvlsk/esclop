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
            MenuContent(model: delegate.services.model, settings: delegate.services.settingsWindow)
        } label: {
            MenuBarLabel(model: delegate.services.model)
        }
        .menuBarExtraStyle(.menu)
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

    func application(_ application: NSApplication, open urls: [URL]) {
        services.open(urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        services.stop()
    }
}
