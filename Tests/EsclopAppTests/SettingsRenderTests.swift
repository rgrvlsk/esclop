// SPDX-License-Identifier: GPL-3.0-or-later
//
// Renders the Settings window, light and dark. ImageRenderer cannot draw AppKit-backed controls
// (switches, pop-up buttons, fields, lists), so these renders show the view in a real window and
// take the image the window server composites, sidebar glass included. Set ESCLOP_RENDER_DIR to
// keep the PNGs for pull requests.

import AppKit
import EsclopCore
import EsclopIPC
import EsclopMCP
@testable import EsclopAppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct SettingsRenderTests {
    static let folder: URL = {
        if let path = ProcessInfo.processInfo.environment["ESCLOP_RENDER_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("esclop-renders-\(UUID().uuidString)", isDirectory: true)
    }()

    /// Draws `view` in a window of `size` with the scheme's appearance; returns the PNG's size in points.
    @discardableResult
    static func renderWindow(_ view: some View, size: CGSize, name: String, scheme: ColorScheme, settle: Duration = .milliseconds(250)) async throws -> CGSize {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        let window = KeyWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()
        // SwiftUI fills the AppKit controls in over a few run loop turns; sleeping on the main
        // actor lets the main run loop turn.
        try await Task.sleep(for: settle)
        host.layoutSubtreeIfNeeded()
        let bounds = host.bounds
        // A runner without a window server session gives no image: the layout still ran.
        guard let image = capture(window) else {
            window.orderOut(nil)
            window.close()
            return bounds.size
        }
        let rep = NSBitmapImageRep(cgImage: image)
        window.orderOut(nil)
        window.close()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: folder.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
        return bounds.size
    }

    /// The window as the window server composites it, sidebar glass included. A process may
    /// always capture its own windows, so this needs no screen recording permission.
    /// `CGWindowListCreateImage` is marked unavailable in the macOS 15 SDK for new code but still
    /// ships; ScreenCaptureKit would need that permission.
    static func capture(_ window: NSWindow) -> CGImage? {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: Create.self)
        // .optionIncludingWindow, .boundsIgnoreFraming | .bestResolution
        return create(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue()
    }

    func model(_ settings: TestSettings) -> SettingsViewModel {
        SettingsViewModel(provider: RegistrySettingsProvider(store: settings.store), extraRows: SettingsPaneView.extraRows)
    }

    /// The deep link landing on a refused value: switches, sliders, fields with units, the marked
    /// row and the error, in one window. It waits longer: the row scrolls into view first.
    @Test(arguments: [ColorScheme.light, .dark])
    func deepLinkToARefusedValue(scheme: ColorScheme) async throws {
        let model = model(TestSettings())
        model.set("imageCompression", text: "45")
        model.open(SettingsRoute(pane: .images, row: "maxImageSizeMB"))
        model.set("maxImageSizeMB", text: "50000")
        let size = try await Self.renderWindow(SettingsView(model: model), size: CGSize(width: 800, height: 620), name: "settings-deep-link-error", scheme: scheme, settle: .milliseconds(600))
        #expect(size.width == 800)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func search(scheme: ColorScheme) async throws {
        let model = model(TestSettings())
        model.query = "aggressive"
        try await Self.renderWindow(SettingsView(model: model), size: CGSize(width: 800, height: 620), name: "settings-search", scheme: scheme)
    }

    /// Every pane, for a pull request's screenshots: ESCLOP_RENDER_ALL=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ESCLOP_RENDER_ALL"] == "1"), arguments: [ColorScheme.light, .dark])
    func everyPane(scheme: ColorScheme) async throws {
        let model = model(TestSettings())
        model.set("imageCompression", text: "45")
        model.set("capVideoFPS", to: .bool(false))
        for pane in SettingsPane.allCases {
            model.pane = pane
            try await Self.renderWindow(SettingsView(model: model), size: CGSize(width: 800, height: 620), name: "settings-\(pane.rawValue)", scheme: scheme)
        }
    }
}

@MainActor
@Suite(.serialized) struct AgentsRenderTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func agentsPane(scheme: ColorScheme) async throws {
        let fixture = AgentsFixture()
        fixture.populate()
        let settings = TestSettings()
        let model = SettingsViewModel(provider: RegistrySettingsProvider(store: settings.store), extraRows: SettingsPaneView.extraRows)
        model.pane = .agents
        let agents = AgentsModel(installer: fixture.installer, command: AgentsFixture.command)
        await agents.refresh()
        agents.connect(try #require(AgentCatalog.agent("codex")))
        await agents.confirm()
        agents.probe = .passed(MCPProbeReport(
            serverName: "esclop-mcp", serverVersion: "0.1.0", protocolVersion: MCPProbe.protocolVersion, toolCount: 24,
            route: "app", appRunning: true, elapsed: .milliseconds(184)
        ))
        try await SettingsRenderTests.renderWindow(SettingsView(model: model, agents: agents), size: CGSize(width: 800, height: 900), name: "settings-agents-connect", scheme: scheme)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func changePreview(scheme: ColorScheme) async throws {
        let fixture = AgentsFixture()
        fixture.populate()
        let change = try fixture.installer.planInstall(try #require(AgentCatalog.agent("cursor")), command: AgentsFixture.command)
        try await SettingsRenderTests.renderWindow(ConfigChangeSheet(change: change, onCancel: {}, onConfirm: {}), size: CGSize(width: 560, height: 470), name: "settings-agents-preview", scheme: scheme)
    }
}

/// A test process cannot become the active app, so its windows draw as inactive (grey switches,
/// grey selection). This one says it is key, so renders show the accent as it is in use.
final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}
