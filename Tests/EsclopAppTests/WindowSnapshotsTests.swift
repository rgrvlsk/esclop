// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
@testable import EsclopAppKit
import Foundation
import Testing

@MainActor
@Suite struct WindowSnapshotsTests {
    @Test func offUnlessTheEnvironmentAsks() {
        #expect(WindowSnapshots(environment: [:]) == nil)
        #expect(WindowSnapshots(environment: [WindowSnapshots.environmentKey: ""]) == nil)
        #expect(WindowSnapshots(environment: [WindowSnapshots.environmentKey: "/tmp/shots"])?.directory.path == "/tmp/shots")
    }

    @Test func labelsNeverBecomePaths() {
        #expect(WindowSnapshots.safe("after-copy_2") == "after-copy_2")
        #expect(WindowSnapshots.safe("../../etc/passwd") == "etc-passwd")
        #expect(WindowSnapshots.safe("a b/c") == "a-b-c")
        #expect(WindowSnapshots.safe("") == "snapshot")
        #expect(WindowSnapshots.safe("///") == "snapshot")
        #expect(WindowSnapshots.safe(String(repeating: "x", count: 200)).count == 60)
    }

    @Test func windowsAreNamedByTitleOrClass() {
        #expect(WindowSnapshots.kind(title: "L'Esclop Settings", className: "NSWindow") == "l-esclop-settings")
        #expect(WindowSnapshots.kind(title: "", className: "EsclopAppKit.FloatingPanel") == "floatingpanel")
        #expect(WindowSnapshots.kind(title: "", className: "") == "window")
    }
}

/// Writes a real window, as the app does when asked. Named a render suite because it puts a
/// window on screen.
@MainActor
@Suite(.serialized) struct WindowSnapshotsRenderTests {
    @Test func writesTheVisibleWindowsAndAManifest() async throws {
        _ = NSApplication.shared
        let temp = TempDir()
        let snapshots = try #require(WindowSnapshots(environment: [WindowSnapshots.environmentKey: temp.url.path]))
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 240, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Snapshot check"
        let hidden = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 50, height: 50), styleMask: [.titled], backing: .buffered, defer: false)
        hidden.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))

        let manifest = try snapshots.write(label: "a/b", windows: [window, hidden])
        #expect(manifest.label == "a-b")
        let stored = try JSONDecoder().decode(WindowSnapshots.Manifest.self, from: Data(contentsOf: temp.url.appendingPathComponent("a-b.json")))
        #expect(stored == manifest)
        // A runner without a window server session gives no image; the manifest is still written.
        guard let entry = manifest.windows.first else { return }
        #expect(manifest.windows.count == 1, "hidden windows are left out")
        #expect(entry.file == "a-b-1-snapshot-check.png")
        #expect(entry.width == Double(window.frame.width))
        let data = try Data(contentsOf: temp.url.appendingPathComponent(entry.file))
        #expect(NSBitmapImageRep(data: data) != nil)
    }
}
