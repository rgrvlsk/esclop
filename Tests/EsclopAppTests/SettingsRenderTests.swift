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
import EsclopPipelines
@testable import EsclopAppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct SettingsRenderTests {
    /// Draws the view in a light and a dark window at once, so both share one wait; writes
    /// `<name>-light.png` and `<name>-dark.png` and returns the content sizes in points.
    @discardableResult
    static func renderBoth(
        _ view: (ColorScheme) -> some View, size: CGSize, name: String, settle: Duration = .milliseconds(250),
        before: (() async throws -> Void)? = nil
    ) async throws -> [CGSize] {
        _ = NSApplication.shared
        let schemes: [ColorScheme] = [.light, .dark]
        let windows = schemes.map { scheme in
            let host = NSHostingView(rootView: view(scheme).environment(\.screenshotLocation, "~/Desktop").environment(\.colorScheme, scheme))
            let window = KeyWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: 40, y: 40))
            window.orderFrontRegardless()
            return window
        }
        try await Task.sleep(for: settle)
        // What happens in the open windows before the pictures.
        try await before?()
        var sizes: [CGSize] = []
        for (scheme, window) in zip(schemes, windows) {
            window.contentView?.layoutSubtreeIfNeeded()
            sizes.append(window.contentView?.bounds.size ?? .zero)
            defer {
                window.orderOut(nil)
                window.close()
            }
            guard let image = WindowSnapshots.image(of: window) else { continue }
            try keepRender(NSBitmapImageRep(cgImage: image), name: name, scheme: scheme)
        }
        return sizes
    }

    /// Draws `view` in a window of `size` with the scheme's appearance; returns the PNG's size in points.
    @discardableResult
    static func renderWindow(
        _ view: some View, size: CGSize, name: String, scheme: ColorScheme, settle: Duration = .milliseconds(250),
        before: (() async throws -> Void)? = nil
    ) async throws -> CGSize {
        _ = NSApplication.shared
        // A fixed screenshot location: the machine's own stays out of the pictures.
        let host = NSHostingView(rootView: view.environment(\.screenshotLocation, "~/Desktop").environment(\.colorScheme, scheme))
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
        // What happens in the open window before the picture.
        try await before?()
        host.layoutSubtreeIfNeeded()
        let bounds = host.bounds
        // A runner without a window server session gives no image: the layout still ran.
        guard let image = WindowSnapshots.image(of: window) else {
            window.orderOut(nil)
            window.close()
            return bounds.size
        }
        let rep = NSBitmapImageRep(cgImage: image)
        window.orderOut(nil)
        window.close()
        try keepRender(rep, name: name, scheme: scheme)
        return bounds.size
    }

    /// Without ESCLOP_RENDER_DIR a render writes nothing: test runs left a folder of PNGs in the
    /// temporary folder each time, 2.4 GB over a day of runs on one Mac.
    @Test func aRenderWithoutTheFolderLeavesNothing() async throws {
        let temp = FileManager.default.temporaryDirectory
        func entries() -> Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []) }
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let before = entries()
        #expect(try keepRender(rep, name: "probe", scheme: .light, in: nil) == nil)
        if renderFolder == nil {
            try await Self.renderWindow(Text(verbatim: "probe"), size: CGSize(width: 80, height: 40), name: "probe", scheme: .light)
        }
        // The renders' old folders, not BatchRenderTests' own `esclop-render-backup`.
        #expect(entries().subtracting(before).filter { $0.hasPrefix("esclop-renders-") }.isEmpty)
        // With a folder, the PNG lands there under its name.
        let folder = TempDir()
        #expect(try keepRender(rep, name: "probe", scheme: .dark, in: folder.url)?.lastPathComponent == "probe-dark.png")
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

    /// General › Updates, reached by its link (the section sits at the end of the pane).
    @Test(arguments: [ColorScheme.light, .dark])
    func updates(scheme: ColorScheme) async throws {
        let model = model(TestSettings())
        model.open(SettingsRoute(pane: .general, row: "installUpdatesAutomatically"))
        let size = try await Self.renderWindow(SettingsView(model: model), size: CGSize(width: 800, height: 620), name: "settings-updates", scheme: scheme, settle: .milliseconds(600)) {
            // While the window is open: a closed one never reports the row (council C7-F1).
            #expect(await eventually(.seconds(10)) { model.markInView == "installUpdatesAutomatically" }, "scrolled into view and marked")
        }
        #expect(size.width > 0)
    }

    /// Search hits and links to rows low in General, with the window already open on another pane:
    /// each row comes into view marked, however late the pane lays out (council C7-F1). The picture
    /// is the last one, the pause hotkey.
    @Test(arguments: [ColorScheme.light, .dark])
    func linksReachRowsLowInGeneral(scheme: ColorScheme) async throws {
        let settings = TestSettings()
        let model = model(settings)
        model.login = OnboardingModel(defaults: settings.store.defaults)
        model.pane = .images
        let rows = [
            "installUpdatesAutomatically", EsclopSettings.cardKeysUnderPointer.key, SettingsPaneView.openAtLoginRow,
            // Twice: again after the pane was left while it was marked.
            EsclopSettings.showInScreenshots.key, EsclopSettings.showInScreenshots.key, Hotkeys.rowID(.togglePause),
        ]
        try await Self.renderWindow(SettingsView(model: model), size: CGSize(width: 800, height: 620), name: "settings-link-low-row", scheme: scheme, settle: .milliseconds(400)) {
            for row in rows {
                // Away while the last row is still marked, as a person moving on would be.
                model.pane = .images
                try await Task.sleep(for: .milliseconds(150))
                model.query = row
                let hit = try #require(model.hits.first { $0.id == row }, "the search finds \(row)")
                model.query = ""
                model.open(hit)
                #expect(model.markInView == nil, "\(row): a new link waits for its row to say it is in view")
                #expect(await eventually(.seconds(10)) { model.markInView == row }, "\(row) in view and marked")
            }
        }
    }

    /// General › Keyboard shortcuts with the switch for the card keys under the pointer.
    @Test(arguments: [ColorScheme.light, .dark])
    func keyboardShortcuts(scheme: ColorScheme) async throws {
        let model = model(TestSettings())
        model.open(SettingsRoute(pane: .general, row: EsclopSettings.cardKeysUnderPointer.key))
        try await Self.renderWindow(SettingsView(model: model), size: CGSize(width: 800, height: 620), name: "settings-keyboard-shortcuts", scheme: scheme, settle: .milliseconds(600)) {
            #expect(await eventually(.seconds(10)) { model.markInView == EsclopSettings.cardKeysUnderPointer.key }, "scrolled into view and marked")
        }
    }

    /// General › Settings on another Mac: Export… and Import…, reached by its search row.
    @Test(arguments: [ColorScheme.light, .dark])
    func settingsFile(scheme: ColorScheme) async throws {
        let settings = TestSettings()
        let model = model(settings)
        model.open(SettingsRoute(pane: .general, row: SettingsPaneView.settingsFileRow))
        let view = SettingsView(model: model, actions: SettingsActions(settingsStore: settings.store))
        try await Self.renderWindow(view, size: CGSize(width: 800, height: 620), name: "settings-export-import", scheme: scheme, settle: .milliseconds(600))
    }

    /// "Show floating results" in its pane (the hotkeys, with ⌃⇧N, show on onboarding's last page).
    @Test(arguments: [ColorScheme.light, .dark])
    func floatingResults(scheme: ColorScheme) async throws {
        let model = model(TestSettings())
        model.pane = .floatingResults
        try await Self.renderWindow(SettingsView(model: model), size: CGSize(width: 800, height: 620), name: "settings-floating-results", scheme: scheme)
    }

    /// Floating results › Preset zones: a saved pipeline and a template on, the rest off.
    @Test(arguments: [ColorScheme.light, .dark])
    func presetZones(scheme: ColorScheme) async throws {
        let temp = TempDir()
        let store = PipelineStore(directory: temp.url, useTrash: false)
        var mine = try PipelineParser.parse("optimise", name: "Screenshots for the blog")
        mine.icon = "camera.viewfinder"
        mine.triggers = [.presetZone]
        try store.save(mine)
        let model = model(TestSettings())
        model.pipelines = store
        model.set("presetZones", to: .array([.string("to WebP")]))
        model.open(SettingsRoute(pane: .floatingResults, row: "presetZones"))
        try await Self.renderWindow(SettingsView(model: model), size: CGSize(width: 800, height: 620), name: "settings-preset-zones", scheme: scheme, settle: .milliseconds(600))
    }

    /// Settings › Uploads with two targets, one with its keys saved, and automatic uploads from
    /// the clipboard; then the editor sheet for the first.
    @Test(arguments: [ColorScheme.light, .dark])
    func uploads(scheme: ColorScheme) async throws {
        let model = model(TestSettings())
        let keychain = MemoryCredentialStore(["R2": UploadCredentials(accessKeyID: "AKIDEXAMPLE", secret: "x")])
        model.uploads = UploadSettingsSupport(credentials: keychain) { _, _ in URL(string: "https://files.example.com/x")! }
        let targets = [
            UploadTarget(name: "R2", endpoint: "https://account.r2.cloudflarestorage.com", bucket: "pictures", region: "auto", publicURL: "https://files.example.com/{path}"),
            UploadTarget(name: "MinIO", endpoint: "http://127.0.0.1:9000", bucket: "test"),
        ]
        model.set("uploadTargets", to: .array(UploadTarget.encode(targets).map { .string($0) }))
        model.set("uploadAutomatically", to: .array([.string("clipboard")]))
        model.pane = .uploads
        try await Self.renderWindow(SettingsView(model: model), size: CGSize(width: 800, height: 620), name: "settings-uploads", scheme: scheme)
        var draft = UploadTargetDraft(targets[0], keysSaved: true)
        draft.accessKeyID = ""
        let editor = UploadTargetEditor(draft: draft, others: [targets[1]], model: model) {}
        try await Self.renderWindow(editor, size: CGSize(width: 520, height: 720), name: "settings-upload-editor", scheme: scheme)
        // R2 without a public link: its links do not open for the people they are sent to.
        var privateLink = targets[0]
        privateLink.publicURL = ""
        let warned = UploadTargetEditor(draft: UploadTargetDraft(privateLink, keysSaved: true), others: [targets[1]], model: model) {}
        try await Self.renderWindow(warned, size: CGSize(width: 520, height: 760), name: "settings-upload-editor-private-link", scheme: scheme)
    }

    /// Settings › Clipboard, tall enough for every row, with an ignored app shown by its name.
    @Test(arguments: [ColorScheme.light, .dark])
    func clipboardPane(scheme: ColorScheme) async throws {
        let model = model(TestSettings())
        model.set("clipboardIgnoredAppBundleIds", to: .array([.string("com.apple.TextEdit")]))
        model.pane = .clipboard
        try await Self.renderWindow(SettingsView(model: model), size: CGSize(width: 800, height: 1100), name: "settings-clipboard", scheme: scheme)
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

    /// The note under the permission switches, which states who they bind.
    @Test(arguments: [ColorScheme.light, .dark])
    func permissionsNote(scheme: ColorScheme) async throws {
        let fixture = AgentsFixture()
        let settings = TestSettings()
        let model = SettingsViewModel(provider: RegistrySettingsProvider(store: settings.store), extraRows: SettingsPaneView.extraRows)
        model.pane = .agents
        let agents = AgentsModel(installer: fixture.installer, command: AgentsFixture.command)
        await agents.refresh()
        try await SettingsRenderTests.renderWindow(SettingsView(model: model, agents: agents), size: CGSize(width: 800, height: 1500), name: "settings-agents-permissions", scheme: scheme)
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
