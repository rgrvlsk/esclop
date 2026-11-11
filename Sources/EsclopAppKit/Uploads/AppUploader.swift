// SPDX-License-Identifier: GPL-3.0-or-later
//
// The app's uploads: the target from the settings, its keys from the Keychain, one S3 PUT. The
// job executor uses it for `JobOperation.upload` (the command line, MCP), the cards for the Share
// tab and automatic uploads, and the pipeline host for `upload` steps.

import EsclopCore
import EsclopIPC
import EsclopPipelines
import Foundation

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

/// What pipelines reach in the app: `upload` steps upload and copy the link; everything else is
/// what it was before (not available here).
public struct AppPipelineHost: PipelineHost {
    let uploader: any FileUploading
    let copyLink: @Sendable (URL) async -> Void

    public init(uploader: any FileUploading, copyLink: @escaping @Sendable (URL) async -> Void) {
        self.uploader = uploader
        self.copyLink = copyLink
    }

    public func perform(_ action: PipelineHostAction, file: URL, options: PipelineRunOptions) async throws -> PipelineHostOutcome {
        guard case let .uploadTo(target) = action else { return try await NoopPipelineHost().perform(action, file: file, options: options) }
        // Pipelines run on media files only; an upload step holds to that whatever runs it.
        guard AgentPolicy.isUploadable(file) else {
            return .unavailable(Strings.text("Only images, videos, PDFs and audio files are uploaded."))
        }
        let link = try await uploader.upload(file, to: target) { _ in }
        await copyLink(link)
        return .handled(link.absoluteString)
    }
}
