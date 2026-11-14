// SPDX-License-Identifier: GPL-3.0-or-later
//
// The menu bar app's entry point. Everything else lives in EsclopAppKit.

import AppKit
import EsclopAppKit

// The glyph and its panel are AppKit (`StatusItemController`), for the panel's notch, corners
// and keys, so the app runs on AppKit's own loop: a SwiftUI `App` needs a scene, and its only
// candidate, an empty Settings scene, opened as a blank window at launch.
@main
enum EsclopMenuBarApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let services = AppServices()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Screenshots of both appearances without changing the system's (`open --env`).
        switch ProcessInfo.processInfo.environment["ESCLOP_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        do {
            try services.start()
            services.startStatusItem()
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
