// SPDX-License-Identifier: GPL-3.0-or-later
//
// The watched-folder editor in the Images pane: a folder being watched, one on a disk that is
// not connected, one macOS keeps L'Esclop out of, the skip rules under each (the Desktop's
// filled in), and the screenshot location offered because it is not in the list. ESCLOP_LANGUAGE=ca draws it in Catalan.

import AppKit
import EsclopCore
import EsclopIPC
@testable import EsclopAppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct FolderEditorRenderTests {
    /// A short, generic path, so the picture shows no machine's temporary folder; its own per
    /// run, so two checkouts testing at once do not lock each other's folder.
    static let locked = URL(fileURLWithPath: "/tmp/esclop-render-\(UUID().uuidString.prefix(6))/Shared Shots", isDirectory: true)

    @Test func folderList() async throws {
        try FileManager.default.createDirectory(at: Self.locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: Self.locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.locked.path)
            try? FileManager.default.removeItem(at: Self.locked.deletingLastPathComponent())
        }
        let settings = TestSettings()
        let model = SettingsViewModel(provider: RegistrySettingsProvider(store: settings.store), extraRows: SettingsPaneView.extraRows)
        model.set("imageDirs", to: .array(["~/Desktop", "/Volumes/Archive/Screenshots", Self.locked.path].map(JSONValue.string)))
        // The Desktop skips GIFs and HEICs and takes images from 200 px on its longer side.
        let rules = FolderRules(folder: "~/Desktop", skipFormats: ["gif", "heic"], minPixels: 200)
        model.set(EsclopSettings.watchedFolderRules.key, to: .array(FolderRules.replacing(rules, in: []).map(JSONValue.string)))
        let descriptor = try #require(model.descriptors.first { $0.key == "imageDirs" })
        // The row as the Images pane draws it, alone: the whole pane would need a scroll, which
        // takes a varying time to land.
        let sizes = try await SettingsRenderTests.renderBoth({ _ in
            Form {
                Section("Images") { SettingRow(descriptor: descriptor, model: model, actions: SettingsActions()) }
            }
            .formStyle(.grouped)
            .environment(\.screenshotLocation, "~/Pictures/Screenshots")
        }, size: CGSize(width: 640, height: 520), name: "settings-folders", settle: .milliseconds(300))
        #expect(sizes.map(\.width) == [640, 640])
        #expect(FolderStatus.check(Self.locked) == .unreadable, "the picture shows the unreadable row")
    }

    /// V7: Ignore Rules… edits the folder's `.esclopignore` as plain text, and Save writes it;
    /// no patterns remove the file.
    @Test func ignoreRules() async throws {
        let folder = URL(fileURLWithPath: "/tmp/esclop-render-\(UUID().uuidString.prefix(6))/Shots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try IgnoreFile.write("# drafts stay as they are\ndraft-*\n*.mov\n!keep.mov\n", in: folder)
        #expect(IgnoreFile.text(in: folder) == "# drafts stay as they are\ndraft-*\n*.mov\n!keep.mov\n")
        let patterns = IgnoreFile.patterns(in: folder)
        #expect(IgnoreFile.ignores("draft-1.png", patterns: patterns) && IgnoreFile.ignores("clip.MOV", patterns: patterns))
        #expect(!IgnoreFile.ignores("keep.mov", patterns: patterns) && !IgnoreFile.ignores("photo.png", patterns: patterns))
        let sizes = try await SettingsRenderTests.renderBoth({ _ in
            IgnoreRulesEditor(folder: folder.path) {}
        }, size: CGSize(width: 460, height: 340), name: "settings-ignore-rules")
        #expect(sizes.map(\.width) == [460, 460])
        try IgnoreFile.write(" \n", in: folder)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".esclopignore").path))
    }
}
