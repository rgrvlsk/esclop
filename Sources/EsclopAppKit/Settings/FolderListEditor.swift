// SPDX-License-Identifier: GPL-3.0-or-later
//
// A watched-folder list in its kind's pane: each folder as a row with its icon and path, what
// is wrong with it when something is (gone, or macOS keeps L'Esclop out), Show in Finder and
// Stop watching; under each folder what it leaves alone (formats, and pixel sizes for images
// and videos: `watchedFolderRules`) and Ignore Rules…, which edits the folder's `.esclopignore`
// as plain text; Add Folder… with an open panel; and, for screenshots and
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
    /// The folder whose ignore rules are open in a sheet.
    @State private var ignoring: String?
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
                Text(Strings.text("No folders")).foregroundStyle(Ink.secondary)
            }
            ForEach(folders, id: \.self) { folder in
                let status = status(of: folder)
                FolderRow(folder: folder, status: status, ignoreRules: status == .watching || status == .notWatching ? { ignoring = folder } : nil) {
                    write(folders.filter { $0 != folder })
                    forgetRules(of: folder)
                }
                // Rules for a folder L'Esclop cannot read or find would do nothing yet.
                if status == .watching || status == .notWatching {
                    FolderRulesRow(folder: folder, pixels: descriptor.key == EsclopSettings.imageDirs.key || descriptor.key == EsclopSettings.videoDirs.key, model: model)
                        .padding(.leading, 48)
                }
            }
            if let screenshotFolder {
                ScreenshotFolderRow(folder: screenshotFolder) { write(folders + [screenshotFolder]) }
            }
            Button { add() } label: {
                Label(Strings.text("Add Folder…"), systemImage: "plus")
            }
            .sheet(item: Binding(get: { ignoring.map(IgnoredFolder.init) }, set: { ignoring = $0?.id })) { folder in
                IgnoreRulesEditor(folder: folder.id) { ignoring = nil }
                    .designTint()
            }
            .buttonStyle(DashedAddButtonStyle(radius: 12))
            .accessibilityLabel(Strings.format("Add a folder to %@", descriptor.title))
        }
    }

    struct IgnoredFolder: Identifiable { let id: String }

    /// What the folder itself says, unless the watcher could not start. Reading the watcher's
    /// statuses redraws the row when a folder appears, moves or goes away.
    func status(of folder: String) -> FolderStatus {
        let url = WatchPlan.canonical(folder)
        if model.watchedFolders?.statuses[url] == .notWatching { return .notWatching }
        return FolderStatus.check(url)
    }

    /// The folder's status without reading inside it. The watcher's own, while it watches the
    /// folder: nothing touches the disk on a redraw, so a dropped network share cannot stall the
    /// window. Before the watcher has one, whether the folder is there and readable by its
    /// permissions. A folder macOS guards (Desktop) shows its refusal on its row, which reads it.
    static func quietStatus(of folder: String, model: SettingsViewModel) -> FolderStatus {
        let url = WatchPlan.canonical(folder)
        if let watched = model.watchedFolders?.statuses[url] { return watched }
        if FolderStatus.presence(url) == .missing { return .missing }
        return FileManager.default.isReadableFile(atPath: url.path) ? .watching : .unreadable
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
    /// Opens the folder's .esclopignore; nil while L'Esclop cannot watch it.
    var ignoreRules: (() -> Void)?
    let remove: () -> Void

    var body: some View {
        let problem = Self.short(status)
        // The disc on the panel's disc axis, the words on its title's edge: 32 + 16 here, as
        // 36 + 14 in the heading, 2 pt further in.
        HStack(spacing: Spacing.l) {
            IconBadge(symbol: status == .missing ? "folder.badge.questionmark" : "folder", size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(status == .missing ? AnyShapeStyle(Ink.secondary) : AnyShapeStyle(Ink.text))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folder)
                if let problem {
                    Text(problem)
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(Self.problem(status) ?? "")
                }
            }
            Spacer(minLength: Spacing.s)
            if status == .unreadable {
                // Opens Privacy & Security › Files & Folders, where access is given.
                Button(Strings.text("Grant Access…")) { Self.openPrivacySettings() }
                    .buttonStyle(PillButtonStyle(compact: true, decision: true))
                    .fixedSize()
                    .help(Self.problem(status) ?? "")
            }
            HStack(spacing: 6) {
                if let ignoreRules {
                    // Quiet, beside Show in Finder: the one pill on a row is the decision.
                    RoundIconButton(symbol: "line.3.horizontal.decrease.circle", help: Strings.text("Ignore Rules…"), action: ignoreRules)
                        .accessibilityLabel(Strings.format("Ignore rules for %@", folder))
                }
                RoundIconButton(symbol: "arrow.up.forward.app", help: Strings.text("Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([WatchPlan.canonical(folder)])
                }
                .disabled(status == .missing)
                .accessibilityLabel(Strings.format("Show %@ in Finder", folder))
                RoundIconButton(symbol: "minus.circle", help: Strings.text("Stop Watching"), action: remove)
                    .accessibilityLabel(Strings.format("Stop watching %@", folder))
            }
            // The last circle's centre on the reset arrows' axis.
            .padding(.trailing, -2)
        }
        // A folder L'Esclop cannot watch needs a decision: amber reaching past the row, so its
        // circle and words stay in the columns of the rows above.
        .padding(.vertical, problem == nil ? 0 : 4)
        .background {
            if problem != nil {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Surface.warmDecision).padding(.horizontal, -8)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.format("Folder %@", folder))
        .accessibilityValue(Self.problem(status) ?? "")
    }

    /// What is wrong with a folder, in a few words for its row; the whole sentence is its help.
    static func short(_ status: FolderStatus) -> String? {
        switch status {
        case .watching: return nil
        case .missing: return Strings.text("Not found: its disk may not be connected")
        case .unreadable: return Strings.text("L’Esclop can’t read this folder")
        case .notWatching: return Strings.text("Not watched yet: L’Esclop will try again")
        }
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
            Image(systemName: "camera.viewfinder").foregroundStyle(Ink.secondary).frame(width: 18).accessibilityHidden(true)
            Text(Strings.format("Screenshots are saved in %@, which is not watched.", folder))
                .font(.callout)
                .foregroundStyle(Ink.secondary)
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
    @FocusState private var focused: Field?
    enum Field { case formats, smallest, largest }

    var list: [String] { model.descriptor(EsclopSettings.watchedFolderRules.key)?.value?.arrayValue?.compactMap(\.stringValue) ?? [] }

    var rules: FolderRules {
        let folder = WatchPlan.canonical(self.folder)
        return list.compactMap { try? JSONDecoder().decode(FolderRules.self, from: Data($0.utf8)) }
            .first { WatchPlan.canonical($0.folder) == folder } ?? FolderRules(folder: self.folder)
    }

    var body: some View {
        // Two phrases on one line; the size range moves under the formats, on the same edge,
        // when the pane is too narrow for both. The prompts say what an empty field means.
        FlowLayout(spacing: 16, lineSpacing: 8) {
            HStack(spacing: 6) {
                Text(Strings.text("Skip formats")).foregroundStyle(Ink.secondary)
                field(.formats, Strings.text("none"), text: $formats, width: 80, label: Strings.format("Formats %@ skips", folder))
            }
            if pixels {
                HStack(spacing: 6) {
                    // The longer side, as the rule measures it.
                    Text(Strings.text("Longer side")).foregroundStyle(Ink.secondary)
                    field(.smallest, Strings.text("min"), text: $minPixels, width: 58, label: Strings.format("Smallest images and videos %@ takes, in pixels", folder))
                    Text(Strings.text("to")).foregroundStyle(Ink.secondary)
                    field(.largest, Strings.text("max"), text: $maxPixels, width: 58, label: Strings.format("Largest images and videos %@ takes, in pixels", folder))
                    Text(verbatim: "px").foregroundStyle(Ink.secondary)
                }
            }
        }
        .font(.system(size: 13))
        .onAppear(perform: load)
        // Leaving any of the three fields saves them.
        .onChange(of: focused) { old, now in if old != nil, now == nil { commit() } }
    }

    private func field(_ which: Field, _ prompt: String, text: Binding<String>, width: CGFloat, label: String) -> some View {
        WarmPlaceholder(text: text.wrappedValue, prompt: prompt) {
            TextField(label, text: text, prompt: Text(""))
                .labelsHidden()
                .textFieldStyle(.plain)
                .focused($focused, equals: which)
        }
            .padding(.horizontal, 7)
            .frame(width: width, height: 26)
            .background { WarmFieldGround() }
            .overlay { if focused == which { WarmFieldRing() } }
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

/// A watched folder's `.esclopignore` as plain text, saved on Save (`IgnoreFile.write`).
struct IgnoreRulesEditor: View {
    let folder: String
    let close: () -> Void
    @State private var text: String
    @State private var saveError: String?

    init(folder: String, close: @escaping () -> Void) {
        self.folder = folder
        self.close = close
        _text = State(initialValue: IgnoreFile.text(in: WatchPlan.canonical(folder)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Strings.format("Ignore Rules for “%@”", URL(fileURLWithPath: folder).lastPathComponent))
                .font(.title3.weight(.semibold))
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .frame(height: 160)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                .accessibilityLabel(Strings.format("Ignore rules for %@", folder))
            // A word joiner keeps "!" on the line of the name it takes back.
            Text(Strings.format("One pattern per line, as in .gitignore: %@ skips every MOV file, %@ takes one back, and %@ starts a comment.", "*.mov", "!\u{2060}intro.mov", "#"))
                .font(.callout)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(Strings.text("An .esclopignore file in a folder skips the names it lists, as .gitignore does; Clop’s .clopignore works too."))
                .font(.callout)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Palette.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(Strings.text("Cancel"), role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button(Strings.text("Save")) {
                    do {
                        try IgnoreFile.write(text, in: WatchPlan.canonical(folder))
                        close()
                    } catch {
                        saveError = CardPresentation.message(for: error)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .primaryButton()
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// A symbol button in a row: a 24 pt target, a wash under the pointer.
struct RoundIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(Ink.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(hovering && enabled ? 0.07 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .contentShape(.focusEffect, Circle())
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help(help)
    }
}
