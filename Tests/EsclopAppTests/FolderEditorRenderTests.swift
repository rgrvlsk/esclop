// SPDX-License-Identifier: GPL-3.0-or-later
//
// The watched-folder editor in the Images pane: a folder being watched, one on a disk that is
// not connected, one macOS keeps L'Esclop out of, and the screenshot location offered because it
// is not in the list. ESCLOP_LANGUAGE=ca draws it in Catalan.

import AppKit
import EsclopCore
import EsclopIPC
@testable import EsclopAppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct FolderEditorRenderTests {
    /// A fixed, generic path, so the picture shows no machine's temporary folder.
    static let locked = URL(fileURLWithPath: "/tmp/esclop-render/Shared Shots", isDirectory: true)

    @Test(arguments: [ColorScheme.light, .dark])
    func folderList(scheme: ColorScheme) async throws {
        try FileManager.default.createDirectory(at: Self.locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: Self.locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.locked.path)
            try? FileManager.default.removeItem(at: Self.locked.deletingLastPathComponent())
        }
        let settings = TestSettings()
        let model = SettingsViewModel(provider: RegistrySettingsProvider(store: settings.store), extraRows: SettingsPaneView.extraRows)
        model.set("imageDirs", to: .array(["~/Desktop", "/Volumes/Archive/Screenshots", Self.locked.path].map(JSONValue.string)))
        let descriptor = try #require(model.descriptors.first { $0.key == "imageDirs" })
        // The row as the Images pane draws it, alone: the whole pane would need a scroll, which
        // takes a varying time to land.
        let view = Form {
            Section("Images") { SettingRow(descriptor: descriptor, model: model, actions: SettingsActions()) }
        }
        .formStyle(.grouped)
        .tint(Palette.accent)
        .environment(\.screenshotLocation, "~/Pictures/Screenshots")
        let size = try await SettingsRenderTests.renderWindow(view, size: CGSize(width: 640, height: 520), name: "settings-folders", scheme: scheme, settle: .milliseconds(300))
        #expect(size.width == 640)
        #expect(FolderStatus.check(Self.locked) == .unreadable, "the picture shows the unreadable row")
    }
}
