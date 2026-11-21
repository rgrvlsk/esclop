// SPDX-License-Identifier: GPL-3.0-or-later
//
// A watched-folder list in its kind's pane: each folder as a row with its icon and path, what
// is wrong with it when something is (gone, or macOS keeps L'Esclop out), Show in Finder and
// Stop watching; under each folder what it leaves alone (formats, and pixel sizes for images
// and videos: `watchedFolderRules`); Add Folder… with an open panel; and, for screenshots and
// screen recordings, the folder macOS saves them to when it is not watched yet. Values go
// through the settings model.

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
        return Self.unwatched(screenshotLocation, in: folders)
    }

    /// `location`, unless `folders` already has it.
    static func unwatched(_ location: String, in folders: [String]) -> String? {
        let watched = folders.map { WatchPlan.canonical($0).path }
        return watched.contains(WatchPlan.canonical(location).path) ? nil : location
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            label
            if folders.isEmpty {
                Text(Strings.text("No folders")).foregroundStyle(.secondary)
            }
            ForEach(folders, id: \.self) { folder in
                FolderRow(folder: folder, status: status(of: folder)) {
                    write(folders.filter { $0 != folder })
                    forgetRules(of: folder)
                }
                FolderRulesRow(folder: folder, pixels: descriptor.key == EsclopSettings.imageDirs.key || descriptor.key == EsclopSettings.videoDirs.key, model: model)
                    .padding(.leading, 26)
            }
            if !folders.isEmpty {
                Text(Strings.text("An .esclopignore file in a folder skips the names it lists, as .gitignore does; Clop’s .clopignore works too."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let screenshotFolder {
                ScreenshotFolderRow(folder: screenshotFolder) { write(folders + [screenshotFolder]) }
            }
            Button(Strings.text("Add Folder…"), systemImage: "plus") { add() }
                .buttonStyle(.borderless)
                .accessibilityLabel(Strings.format("Add a folder to %@", descriptor.title))
        }
    }

    /// What the folder itself says, unless the watcher could not start. Reading the watcher's
    /// statuses redraws the row when a folder appears, moves or goes away.
    func status(of folder: String) -> FolderStatus {
        let url = WatchPlan.canonical(folder)
        if model.watchedFolders?.statuses[url] == .notWatching { return .notWatching }
        return FolderStatus.check(url)
    }

    func write(_ list: [String]) {
        model.set(descriptor.key, to: .array(list.map(JSONValue.string)))
    }

    /// A folder no list watches any more takes its rules with it: added again later, it starts clean.
    func forgetRules(of folder: String) {
        let canonical = WatchPlan.canonical(folder)
        let lists = WatchPlan.lists.map(\.2.key).compactMap { model.descriptor($0)?.value?.arrayValue?.compactMap(\.stringValue) }
        guard !lists.joined().contains(where: { WatchPlan.canonical($0) == canonical }),
              let rules = model.descriptor(EsclopSettings.watchedFolderRules.key)?.value?.arrayValue?.compactMap(\.stringValue)
        else { return }
        let kept = FolderRules.replacing(FolderRules(folder: folder), in: rules)
        if kept != rules { model.set(EsclopSettings.watchedFolderRules.key, to: .array(kept.map(JSONValue.string))) }
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
        case .unreadable: return Strings.text("macOS does not let L’Esclop read this folder. Allow it in System Settings › Privacy & Security › Files & Folders.")
        case .notWatching: return Strings.text("L’Esclop could not start watching this folder. It tries again when the folder lists change, or the next time L’Esclop opens.")
        }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The folder macOS saves screenshots to, not watched yet, with Watch It: in a folder list and
/// on the tour's Permissions page.
struct ScreenshotFolderRow: View {
    let folder: String
    let watch: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "camera.viewfinder").foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            Text(Strings.format("Screenshots are saved in %@, which is not watched.", folder))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(Strings.text("Watch It"), action: watch)
                .controlSize(.small)
                .accessibilityLabel(Strings.format("Watch %@", folder))
        }
    }
}

/// What one watched folder leaves alone: formats, and for images and videos the longer side's
/// smallest and largest size in pixels. Written to `watchedFolderRules` on Return or when a
/// field loses focus.
struct FolderRulesRow: View {
    let folder: String
    let pixels: Bool
    let model: SettingsViewModel

    @State private var formats = ""
    @State private var minPixels = ""
    @State private var maxPixels = ""
    @FocusState private var focused: Bool

    var list: [String] { model.descriptor(EsclopSettings.watchedFolderRules.key)?.value?.arrayValue?.compactMap(\.stringValue) ?? [] }

    var rules: FolderRules {
        let folder = WatchPlan.canonical(self.folder)
        return list.compactMap { try? JSONDecoder().decode(FolderRules.self, from: Data($0.utf8)) }
            .first { WatchPlan.canonical($0.folder) == folder } ?? FolderRules(folder: self.folder)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(Strings.text("Skip")).foregroundStyle(.secondary)
            field(Strings.text("Formats"), text: $formats, width: 110, label: Strings.format("Formats %@ skips", folder))
            if pixels {
                Text(Strings.text("Pixels")).foregroundStyle(.secondary).padding(.leading, 6)
                field(Strings.text("Smallest"), text: $minPixels, width: 70, label: Strings.format("Smallest images and videos %@ takes, in pixels", folder))
                Text(verbatim: "–").foregroundStyle(.secondary)
                field(Strings.text("Largest"), text: $maxPixels, width: 70, label: Strings.format("Largest images and videos %@ takes, in pixels", folder))
            }
        }
        .font(.callout)
        .controlSize(.small)
        .onAppear(perform: load)
        .onChange(of: focused) { if !focused { commit() } }
    }

    private func field(_ prompt: String, text: Binding<String>, width: CGFloat, label: String) -> some View {
        TextField(label, text: text, prompt: Text(prompt))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
            .focused($focused)
            .onSubmit(commit)
            .accessibilityLabel(label)
    }

    private func load() {
        let rules = rules
        formats = (rules.skipFormats ?? []).joined(separator: ", ")
        minPixels = rules.minPixels.map(String.init) ?? ""
        maxPixels = rules.maxPixels.map(String.init) ?? ""
    }

    private func commit() {
        let skip = formats.split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.filter { !$0.isEmpty }
        let updated = FolderRules(
            folder: folder, skipFormats: skip.isEmpty ? nil : skip,
            minPixels: Int(minPixels.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil },
            maxPixels: Int(maxPixels.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
        )
        guard updated != rules, !(updated.isEmpty && rules.isEmpty) else { return load() }
        model.set(EsclopSettings.watchedFolderRules.key, to: .array(FolderRules.replacing(updated, in: list).map(JSONValue.string)))
        load()
    }
}
