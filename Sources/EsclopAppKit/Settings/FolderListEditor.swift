// SPDX-License-Identifier: GPL-3.0-or-later
//
// A watched-folder list in its kind's pane: each folder as a row with its icon and path, what
// is wrong with it when something is (gone, or macOS keeps L'Esclop out), Show in Finder and
// Stop watching; Add Folder… with an open panel; and, for screenshots and screen recordings, the
// folder macOS saves them to when it is not watched yet. Values go through the settings model.

import AppKit
import EsclopCore
import EsclopIPC
import SwiftUI

extension EnvironmentValues {
    /// Where macOS saves screenshots and screen recordings, `~` abbreviated. Renders set a fixed one.
    @Entry var screenshotLocation: String = PathInput.abbreviate(OriginSignals.screenshotFolder())
}

struct FolderListEditor: View {
    let descriptor: SettingDescriptor
    let model: SettingsViewModel
    let label: AnyView
    @Environment(\.screenshotLocation) private var screenshotLocation

    var folders: [String] { descriptor.value?.arrayValue?.compactMap(\.stringValue) ?? [] }

    /// Where macOS saves screenshots and screen recordings, when this list should offer it.
    var screenshotFolder: String? {
        guard descriptor.key == EsclopSettings.imageDirs.key || descriptor.key == EsclopSettings.videoDirs.key else { return nil }
        let watched = folders.map { WatchPlan.canonical($0).path }
        return watched.contains(WatchPlan.canonical(screenshotLocation).path) ? nil : screenshotLocation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            label
            if folders.isEmpty {
                Text(Strings.text("No folders")).foregroundStyle(.secondary)
            }
            ForEach(folders, id: \.self) { folder in
                FolderRow(folder: folder, status: FolderStatus.check(WatchPlan.canonical(folder))) {
                    write(folders.filter { $0 != folder })
                }
            }
            if let screenshotFolder {
                HStack(spacing: 8) {
                    Image(systemName: "camera.viewfinder").foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
                    Text(Strings.format("Screenshots are saved in %@, which is not watched.", screenshotFolder))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(Strings.text("Watch It")) { write(folders + [screenshotFolder]) }
                        .controlSize(.small)
                        .accessibilityLabel(Strings.format("Watch %@", screenshotFolder))
                }
            }
            Button(Strings.text("Add Folder…"), systemImage: "plus") { add() }
                .buttonStyle(.borderless)
                .accessibilityLabel(Strings.format("Add a folder to %@", descriptor.title))
        }
    }

    func write(_ list: [String]) {
        model.set(descriptor.key, to: .array(list.map(JSONValue.string)))
    }

    func add() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = Strings.text("Watch")
        guard panel.runModal() == .OK else { return }
        var list = folders
        for url in panel.urls {
            let item = StringListEditor.abbreviated(url)
            if !list.contains(item) { list.append(item) }
        }
        write(list)
    }
}

struct FolderRow: View {
    let folder: String
    let status: FolderStatus
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18).accessibilityHidden(true)
                Text(folder).lineLimit(1).truncationMode(.middle).help(folder)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([WatchPlan.canonical(folder)])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .disabled(status == .missing)
                .help(Strings.text("Show in Finder"))
                .accessibilityLabel(Strings.format("Show %@ in Finder", folder))
                Button(action: remove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help(Strings.text("Stop Watching"))
                .accessibilityLabel(Strings.format("Stop watching %@", folder))
            }
            .foregroundStyle(status == .missing ? .secondary : .primary)
            if let problem = Self.problem(status) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.caution).accessibilityHidden(true)
                    Text(problem).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if status == .unreadable {
                        Button(Strings.text("Open Privacy Settings")) { Self.openPrivacySettings() }
                            .controlSize(.small)
                    }
                }
                .padding(.leading, 26)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.format("Folder %@", folder))
    }

    private var icon: NSImage {
        let path = WatchPlan.canonical(folder).path
        return FileManager.default.fileExists(atPath: path) ? NSWorkspace.shared.icon(forFile: path) : NSWorkspace.shared.icon(for: .folder)
    }

    /// What is wrong with a folder, in words, or nil when it is watched.
    static func problem(_ status: FolderStatus) -> String? {
        switch status {
        case .watching: return nil
        case .missing: return Strings.text("This folder no longer exists, or its disk is not connected. It is skipped until it is back.")
        case .unreadable: return Strings.text("macOS does not let L’Esclop read this folder. Allow it in System Settings › Privacy & Security › Files and Folders.")
        }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }
}
