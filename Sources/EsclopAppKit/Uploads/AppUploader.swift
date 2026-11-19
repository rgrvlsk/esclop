// SPDX-License-Identifier: GPL-3.0-or-later
//
// The app's uploads: the target from the settings, its keys from the Keychain, one S3 PUT. The
// job executor uses it for `JobOperation.upload` (the command line, MCP), the cards for the Share
// tab and automatic uploads, and the pipeline host for `upload` steps. The pipeline host also
// does what the other steps that need the app ask for.

import AppKit
import EsclopCore
import EsclopIPC
import EsclopPipelines
import Foundation
import UniformTypeIdentifiers

public struct AppUploader: FileUploading {
    public let settings: SettingsStore
    public let credentials: any UploadCredentialStore
    public let s3: S3Uploader

    public init(settings: SettingsStore, credentials: any UploadCredentialStore = KeychainCredentialStore(), s3: S3Uploader = S3Uploader()) {
        self.settings = settings
        self.credentials = credentials
        self.s3 = s3
    }

    public func upload(_ file: URL, to target: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let target = try UploadTarget.resolve(target, in: settings)
        guard let keys = try credentials.credentials(for: target.name) else {
            throw EsclopError.invalidArgument(Strings.format("The keys for “%@” are missing. Enter them in Settings › Uploads (esclop://settings/uploads).", target.name))
        }
        return try await s3.upload(file, to: target, key: target.key(for: file), credentials: keys, progress: progress)
    }
}

/// What pipelines reach in the app. `upload` steps upload and copy the link; with a desktop (the
/// person's own runs, not an agent's) the clipboard, `openWith`, shelf and upload apps and fork
/// results work too. `copyLinkForSending` has no service in L'Esclop and says so.
public struct AppPipelineHost: PipelineHost {
    let uploader: (any FileUploading)?
    let desktop: (any PipelineDesktop)?
    let copyLink: @Sendable (URL) async -> Void

    public init(uploader: (any FileUploading)?, desktop: (any PipelineDesktop)? = nil, copyLink: @escaping @Sendable (URL) async -> Void) {
        self.uploader = uploader
        self.desktop = desktop
        self.copyLink = copyLink
    }

    /// The shelf and upload apps `shelveWith` and `uploadWith` name, with their bundle ids (the
    /// Share tab offers the same apps).
    public static let shelves: [(name: String, title: String, bundleIDs: [String])] = [
        ("yoink", "Yoink", ["at.EternalStorms.Yoink", "at.EternalStorms.Yoink-setapp"]),
        ("dropover", "Dropover", ["me.damir.dropover-mac"]),
        ("dockside", "Dockside", ["com.hachipoo.Dockside"]),
        ("atoll", "Atoll", ["com.Ebullioscopic.Atoll"]),
    ]
    public static let uploadApps: [(name: String, title: String, bundleIDs: [String])] = [
        ("dropshare", "Dropshare", ["net.mkswap.Dropshare5", "net.mkswap.Dropshare5-setapp"]),
    ]

    public func perform(_ action: PipelineHostAction, file: URL, options: PipelineRunOptions) async throws -> PipelineHostOutcome {
        switch (action, desktop) {
        case let (.uploadTo(target), _):
            // Pipelines run on media files only; an upload step holds to that whatever runs it.
            guard let uploader else { return try await NoopPipelineHost().perform(action, file: file, options: options) }
            guard AgentPolicy.isUploadable(file) else {
                return .unavailable(Strings.text("Only images, videos, PDFs and audio files are uploaded."))
            }
            let link = try await uploader.upload(file, to: target) { _ in }
            await copyLink(link)
            return .handled(link.absoluteString)
        case (.copyLinkForSending, _):
            return .unavailable(Strings.text("Sending a link is not available in L’Esclop: there is no sharing service. Use upload(to:) with an upload target."))
        case (_, nil):
            return try await NoopPipelineHost().perform(action, file: file, options: options)
        case let (_, desktop?):
            return try await perform(action, file: file, on: desktop)
        }
    }

    private func perform(_ action: PipelineHostAction, file: URL, on desktop: any PipelineDesktop) async throws -> PipelineHostOutcome {
        switch action {
        case let .copyToClipboard(format, relativeTo):
            guard format == .imageData else {
                let text = clipboardText(file: file, format: format, relativeTo: relativeTo)
                await desktop.copy(text: text)
                return .handled("copied \(text)")
            }
            guard MediaKind.of(file) == .image, let type = UTType(filenameExtension: file.pathExtension.lowercased()) else {
                return .unavailable(Strings.text("Only images can be copied as image data."))
            }
            await desktop.copy(imageData: try Data(contentsOf: file), type: type)
            return .handled("copied the image")
        case let .open(app):
            // A name, never a path: a pipeline must not reach an app outside where apps live.
            guard !app.contains("/"), let url = await desktop.app(named: app, toOpen: file) else {
                throw EsclopError.invalidArgument(Strings.format("There is no app called “%@” on this Mac.", app))
            }
            try await desktop.open(file, with: url)
            return .handled(nil)
        case let .shelve(app):
            return try await handOver(file, to: app, from: Self.shelves, desktop: desktop)
        case let .upload(app):
            return try await handOver(file, to: app, from: Self.uploadApps, desktop: desktop)
        case .presentFork:
            await desktop.presentFork(file)
            return .handled(nil)
        case .uploadTo, .copyLinkForSending:
            // Handled before a desktop is needed.
            return .handled(nil)
        }
    }

    /// Opens the file with the installed app `name` stands for, as the Share tab does.
    private func handOver(_ file: URL, to name: String, from apps: [(name: String, title: String, bundleIDs: [String])], desktop: any PipelineDesktop) async throws -> PipelineHostOutcome {
        guard let entry = apps.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return .unavailable(Strings.format("L’Esclop does not know the app “%@”.", name))
        }
        guard let app = await desktop.installed(entry.bundleIDs).first else {
            return .unavailable(Strings.format("%@ is not installed.", entry.title))
        }
        try await desktop.open(file, with: app)
        return .handled(nil)
    }
}

/// The person's Mac as pipeline steps reach it: the clipboard (as L'Esclop's own writes, so the
/// clipboard watcher leaves them), apps, and the floating results. `AppDesktop` is the app's.
public protocol PipelineDesktop: Sendable {
    func copy(text: String) async
    func copy(imageData: Data, type: UTType) async
    /// The app with this name or bundle id, preferring the ones that open `file`.
    func app(named name: String, toOpen file: URL) async -> URL?
    /// The installed apps among these bundle ids, in their order.
    func installed(_ bundleIDs: [String]) async -> [URL]
    func open(_ file: URL, with app: URL) async throws
    /// A `fork` step's file, shown as a result of its own.
    func presentFork(_ file: URL) async
}

/// The app's desktop for one run. `fork` shows a result only for a single file with a floating
/// result: `original` is that file and its size before the run. The model is held weakly: a batch
/// row's retry keeps its executor, and with it this desktop.
public struct AppDesktop: PipelineDesktop {
    weak var model: AppModel?
    let original: (url: URL, bytes: Int)?

    public init(model: AppModel, original: (url: URL, bytes: Int)?) {
        self.model = model
        self.original = original
    }

    public func copy(text: String) async { await model?.copyToClipboard(text: text, automatic: true) }

    public func copy(imageData: Data, type: UTType) async { await model?.copyToClipboard(imageData: imageData, type: type) }

    public func app(named name: String, toOpen file: URL) async -> URL? {
        let workspace = NSWorkspace.shared
        if let url = workspace.urlForApplication(withBundleIdentifier: name) { return url }
        func named(_ url: URL) -> Bool {
            url.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
        }
        if let url = workspace.urlsForApplications(toOpen: file).first(where: named) { return url }
        // Apps that do not claim the file's type, where macOS keeps apps.
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        return folders.map { URL(fileURLWithPath: $0).appendingPathComponent(name).appendingPathExtension("app") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func installed(_ bundleIDs: [String]) async -> [URL] { await AppModel.installed(bundleIDs) }

    public func open(_ file: URL, with app: URL) async throws {
        // The Share tab's "Open with" and shelf rows.
        do {
            _ = try await NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            throw EsclopError.other(error.localizedDescription)
        }
    }

    public func presentFork(_ file: URL) async {
        guard let original else { return }
        await model?.presentFork(file, of: original.url, bytesBefore: original.bytes)
    }
}
