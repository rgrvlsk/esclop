// SPDX-License-Identifier: GPL-3.0-or-later
//
// A list setting edited as rows: watched folders (chosen with an open panel, stored with `~`)
// and ignored apps (chosen as apps, stored as bundle identifiers, shown by name).

import AppKit
import EsclopCore
import EsclopIPC
import SwiftUI
import UniformTypeIdentifiers

struct StringListEditor: View {
    let descriptor: SettingDescriptor
    let model: SettingsViewModel
    let label: AnyView

    var isApps: Bool { SettingPresentation.control(for: descriptor) == .apps }
    var items: [String] { descriptor.value?.arrayValue?.compactMap(\.stringValue) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            label
            if items.isEmpty {
                Text(isApps ? "No apps" : "No folders")
                    .foregroundStyle(.secondary)
            }
            ForEach(items, id: \.self) { item in
                HStack(spacing: 8) {
                    Image(nsImage: icon(for: item))
                        .resizable()
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                    Text(isApps ? Self.appName(item) : item)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item)
                    Spacer()
                    Button {
                        write(items.filter { $0 != item })
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove \(isApps ? Self.appName(item) : item)")
                }
            }
            Button(isApps ? "Add App…" : "Add Folder…", systemImage: "plus") { add() }
                .buttonStyle(.borderless)
        }
    }

    func write(_ list: [String]) {
        model.set(descriptor.key, to: .array(list.map(JSONValue.string)))
    }

    func add() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        if isApps {
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.prompt = "Ignore"
        } else {
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Watch"
        }
        guard panel.runModal() == .OK else { return }
        let picked = panel.urls.compactMap { url in isApps ? Bundle(url: url)?.bundleIdentifier : Self.abbreviated(url) }
        var list = items
        for item in picked where !list.contains(item) { list.append(item) }
        write(list)
    }

    func icon(for item: String) -> NSImage {
        if isApps, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let path = (item as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: path) ? NSWorkspace.shared.icon(forFile: path) : NSWorkspace.shared.icon(for: .folder)
    }

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// `~/Desktop` rather than the full home path, as the defaults are written.
    static func abbreviated(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
