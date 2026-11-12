// SPDX-License-Identifier: GPL-3.0-or-later
//
// Settings › Uploads: the targets (each with Edit and Remove, and Add Target…), the default one,
// and which sources upload on their own. A target's address and paths go to the `uploadTargets`
// setting; its keys go to the Keychain through `SettingsViewModel.uploadCredentials` and are
// never shown again, only whether they are saved.

import EsclopCore
import EsclopIPC
import SwiftUI

/// What the Uploads pane needs besides the settings: the Keychain and a test upload.
@MainActor
public struct UploadSettingsSupport {
    public var credentials: any UploadCredentialStore
    /// Uploads a small file to the target and returns its link, or throws why not.
    public var test: (UploadTarget, UploadCredentials) async throws -> URL

    public init(credentials: any UploadCredentialStore, test: @escaping (UploadTarget, UploadCredentials) async throws -> URL) {
        self.credentials = credentials
        self.test = test
    }

    /// The app's: the Keychain, and a test file through the S3 uploader.
    public static func live(credentials: any UploadCredentialStore = KeychainCredentialStore()) -> UploadSettingsSupport {
        UploadSettingsSupport(credentials: credentials) { target, keys in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("esclop-upload-test.txt")
            try Data("L'Esclop upload test\n".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            return try await S3Uploader().upload(file, to: target, key: target.key(for: file), credentials: keys)
        }
    }
}

// MARK: - Targets

struct UploadTargetList: View {
    let descriptor: SettingDescriptor
    let model: SettingsViewModel
    let label: AnyView
    @State private var editing: UploadTargetDraft?
    @State private var removing: UploadTarget?

    private var targets: [UploadTarget] {
        UploadTarget.decode((descriptor.value?.arrayValue ?? []).compactMap(\.stringValue))
    }

    var body: some View {
        let targets = targets
        VStack(alignment: .leading, spacing: 8) {
            label
            if targets.isEmpty {
                Text(Strings.text("No upload targets yet. Add an S3-compatible bucket: AWS S3, Cloudflare R2, Backblaze B2 or MinIO."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(targets) { target in
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.name)
                        Text(Self.summary(of: target, keysSaved: hasKeys(target)))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button(Strings.text("Edit…")) { editing = UploadTargetDraft(target, keysSaved: hasKeys(target)) }
                        .accessibilityLabel(Strings.format("Edit %@", target.name))
                    Button(role: .destructive) { removing = target } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help(Strings.text("Remove"))
                        .accessibilityLabel(Strings.format("Remove %@", target.name))
                }
            }
            Button(Strings.text("Add Target…")) { editing = UploadTargetDraft(nil, keysSaved: false) }
                .disabled(model.uploads == nil)
        }
        .sheet(item: $editing) { draft in
            UploadTargetEditor(draft: draft, others: targets.filter { $0.name != draft.original }, model: model) { editing = nil }
        }
        .confirmationDialog(
            Strings.format("Remove the upload target “%@”?", removing?.name ?? ""),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button(Strings.text("Remove"), role: .destructive) {
                if let target = removing { Self.remove(target, model: model) }
                removing = nil
            }
        } message: {
            Text(Strings.text("Its keys are removed from the Keychain too. Files already uploaded stay where they are."))
        }
    }

    private func hasKeys(_ target: UploadTarget) -> Bool {
        ((try? model.uploads?.credentials.credentials(for: target.name)) ?? nil) != nil
    }

    static func summary(of target: UploadTarget, keysSaved: Bool) -> String {
        let place = "\(URL(string: target.endpoint)?.host() ?? target.endpoint) › \(target.bucket)"
        return place + " · " + (keysSaved ? Strings.text("keys in the Keychain") : Strings.text("no keys yet"))
    }

    /// The target and its keys go; a default that named it falls back to the first.
    static func remove(_ target: UploadTarget, model: SettingsViewModel) {
        let all = model.uploadTargets
        _ = model.set(EsclopSettings.uploadTargets.key, to: .array(UploadTarget.encode(all.filter { $0.name != target.name }).map { .string($0) }))
        try? model.uploads?.credentials.remove(for: target.name)
        if (model.value(EsclopSettings.uploadTarget.key)?.stringValue ?? "") == target.name {
            _ = model.set(EsclopSettings.uploadTarget.key, to: .string(""))
        }
    }
}

/// A target being added or edited: its fields, and the keys typed in this sheet (empty: keep the
/// saved ones).
struct UploadTargetDraft: Identifiable {
    let id = UUID()
    /// The name the target had, nil for a new one.
    var original: String?
    var target: UploadTarget
    var keysSaved: Bool
    var accessKeyID = ""
    var secret = ""

    init(_ target: UploadTarget?, keysSaved: Bool) {
        original = target?.name
        self.target = target ?? UploadTarget(name: "", endpoint: "https://", bucket: "")
        self.keysSaved = keysSaved
    }

    /// What stops saving, in words, or nil.
    func problem(others: [UploadTarget]) -> String? {
        if let problem = target.problem { return problem }
        if others.contains(where: { $0.name.caseInsensitiveCompare(target.name) == .orderedSame }) {
            return Strings.text("Another target has this name.")
        }
        if !keysSaved, accessKeyID.isEmpty || secret.isEmpty { return Strings.text("Enter the access key ID and the secret.") }
        if accessKeyID.isEmpty != secret.isEmpty { return Strings.text("Enter both the access key ID and the secret, or neither to keep the saved ones.") }
        return nil
    }

    /// Writes the target to the setting and the keys to the Keychain; a renamed target's keys move.
    @MainActor
    func save(model: SettingsViewModel) throws {
        guard let uploads = model.uploads else { return }
        var all = model.uploadTargets
        if let original, let index = all.firstIndex(where: { $0.name == original }) {
            all[index] = target
        } else {
            all.append(target)
        }
        if !accessKeyID.isEmpty {
            try uploads.credentials.save(UploadCredentials(accessKeyID: accessKeyID, secret: secret), for: target.name)
        } else if let original, original != target.name, let saved = try uploads.credentials.credentials(for: original) {
            try uploads.credentials.save(saved, for: target.name)
        }
        if let original, original != target.name {
            try? uploads.credentials.remove(for: original)
            if (model.value(EsclopSettings.uploadTarget.key)?.stringValue ?? "") == original {
                _ = model.set(EsclopSettings.uploadTarget.key, to: .string(target.name))
            }
        }
        _ = model.set(EsclopSettings.uploadTargets.key, to: .array(UploadTarget.encode(all).map { .string($0) }))
    }

    /// The keys for a test: the ones typed, else the saved ones.
    @MainActor
    func keys(model: SettingsViewModel) -> UploadCredentials? {
        if !accessKeyID.isEmpty, !secret.isEmpty { return UploadCredentials(accessKeyID: accessKeyID, secret: secret) }
        return ((try? model.uploads?.credentials.credentials(for: original ?? target.name)) ?? nil)
    }
}

struct UploadTargetEditor: View {
    @State var draft: UploadTargetDraft
    let others: [UploadTarget]
    let model: SettingsViewModel
    let close: () -> Void
    @State private var testing = false
    @State private var outcome: Result<URL, Error>?
    @State private var saveError: String?

    var body: some View {
        let problem = draft.problem(others: others)
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.original == nil ? Strings.text("New Upload Target") : Strings.format("Edit “%@”", draft.original ?? ""))
                .font(.title3.weight(.semibold))
            Form {
                TextField(Strings.text("Name"), text: $draft.target.name, prompt: Text(verbatim: "R2"))
                TextField(Strings.text("Endpoint"), text: $draft.target.endpoint, prompt: Text(verbatim: "https://<account>.r2.cloudflarestorage.com"))
                TextField(Strings.text("Bucket"), text: $draft.target.bucket)
                TextField(Strings.text("Region"), text: $draft.target.region, prompt: Text(verbatim: "us-east-1"))
                TextField(Strings.text("Path"), text: $draft.target.path, prompt: Text(verbatim: UploadTarget.defaultPath))
                TextField(Strings.text("Public link"), text: $draft.target.publicURL, prompt: Text(verbatim: "https://files.example.com/{path}"))
                TitledToggle(
                    title: Strings.text("Bucket in the path"),
                    subtitle: Strings.text("endpoint/bucket/file; off: bucket.endpoint/file"),
                    isOn: $draft.target.pathStyle
                )
                TextField(Strings.text("Access key ID"), text: $draft.accessKeyID, prompt: draft.keysSaved ? Text(Strings.text("Saved in the Keychain")) : nil)
                SecureField(Strings.text("Secret access key"), text: $draft.secret, prompt: draft.keysSaved ? Text(Strings.text("Saved in the Keychain")) : nil)
            }
            .formStyle(.grouped)
            Text(Strings.text("Path tokens: %f name, %e extension, %y %m %d date, %r five random letters. In the public link, {path} is the uploaded path; leave it empty to use the endpoint's address."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            status(problem: problem)
            HStack {
                Button(Strings.text("Test Upload")) { test() }
                    .disabled(testing || draft.target.problem != nil || draft.keys(model: model) == nil)
                Spacer()
                Button(Strings.text("Cancel"), role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button(Strings.text("Save")) {
                    do {
                        try draft.save(model: model)
                        close()
                    } catch {
                        saveError = CardPresentation.message(for: error)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private func status(problem: String?) -> some View {
        if let saveError {
            Label(saveError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        } else if testing {
            HStack { ProgressView().controlSize(.small); Text(Strings.text("Uploading a test file…")) }
        } else if case let .success(link) = outcome {
            Label(Strings.format("Uploaded: %@", link.absoluteString), systemImage: "checkmark.circle").foregroundStyle(.green)
                .textSelection(.enabled)
        } else if case let .failure(error) = outcome {
            Label(CardPresentation.message(for: error), systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        } else if let problem {
            Text(problem).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func test() {
        guard let uploads = model.uploads, let keys = draft.keys(model: model) else { return }
        testing = true
        outcome = nil
        let target = draft.target
        Task {
            do { outcome = .success(try await uploads.test(target, keys)) } catch { outcome = .failure(error) }
            testing = false
        }
    }
}

// MARK: - Default target and automatic uploads

struct UploadTargetPicker: View {
    let descriptor: SettingDescriptor
    let model: SettingsViewModel
    let label: AnyView

    var body: some View {
        let names = model.uploadTargets.map(\.name)
        let current = descriptor.value?.stringValue ?? ""
        LabeledContent {
            Picker(Strings.text("Upload to"), selection: Binding(get: { names.contains(current) ? current : "" }, set: { _ = model.set(descriptor.key, to: .string($0)) })) {
                Text(Strings.text("The first in the list")).tag("")
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        } label: {
            label
        }
    }
}

struct UploadSourceSwitches: View {
    let descriptor: SettingDescriptor
    let model: SettingsViewModel
    let label: AnyView

    nonisolated static func title(_ origin: RequestOrigin) -> String {
        switch origin {
        case .clipboard: return Strings.text("Copied files")
        case .dropZone: return Strings.text("Files dropped on the drop zone")
        case .watchedFolder: return Strings.text("Files in watched folders")
        case .finder: return Strings.text("Files from Finder’s Quick Actions")
        default: return origin.rawValue
        }
    }

    var body: some View {
        let shown = Set((descriptor.value?.arrayValue ?? []).compactMap(\.stringValue))
        VStack(alignment: .leading, spacing: 6) {
            label
            ForEach(AppModel.automaticUploadSources, id: \.self) { origin in
                Toggle(Self.title(origin), isOn: Binding(
                    get: { shown.contains(origin.rawValue) },
                    set: { on in
                        var next = shown
                        if on { next.insert(origin.rawValue) } else { next.remove(origin.rawValue) }
                        let ordered = AppModel.automaticUploadSources.map(\.rawValue).filter(next.contains)
                        _ = model.set(descriptor.key, to: .array(ordered.map { .string($0) }))
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.leading, 12)
            }
        }
    }
}
