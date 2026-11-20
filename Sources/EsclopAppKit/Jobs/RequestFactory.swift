// SPDX-License-Identifier: GPL-3.0-or-later
//
// Turns "optimise these files" from the clipboard, the drop zone or a hotkey into jobs, the way
// the settings say: where results go for each kind of file, and which files automatic
// optimisation leaves alone (already optimised, too small, too large).

import EsclopCore
import EsclopIPC
import Foundation

public struct RequestFactory: Sendable {
    public var settings: SettingsStore

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    /// Why automatic optimisation leaves a file alone.
    public enum Skip: Equatable, Sendable {
        case unsupported, disabled, alreadyOptimised, tooSmall, tooLarge
    }

    /// Where optimised files of `kind` go, from the "Optimised … go" settings.
    public func location(for kind: MediaKind?) -> OutputLocation {
        EsclopSettings.optimisedBehaviour(for: kind).value(in: settings)
            .location(specificFolder: EsclopSettings.specificFolderTemplate.value(in: settings))
    }

    /// One job for one file. `location` overrides the settings (clipboard images work on a
    /// temporary copy in place, so the backup is the original). A copied file is optimised as a
    /// copy in the temporary folder, as Clop does: copying is not a request to change the original.
    /// Otherwise, without `location`, a result in another format follows "Converted … go".
    // Those copies go at launch with the backups' age rule (`BackupPruner.pruneAtLaunch`).
    public func job(
        for source: URL, origin: RequestOrigin, aggressive: Bool = false, location: OutputLocation? = nil
    ) -> OptimisationJob {
        var request = OptimisationRequest(
            sources: [source], origin: origin, quality: aggressive ? .aggressive : .normal,
            location: location ?? (origin == .clipboard ? .temporary : self.location(for: MediaKind.of(source)))
        )
        if location == nil, origin != .clipboard { request.locationFromSettings = true }
        // "Show floating results" off: results go only to Recent and the menu, as a pipeline's
        // `hideResult` makes them, and stay out of the batch window too. A card already on screen
        // still runs again in place (`AppModel.run(reusing:)`).
        request.showResultUI = EsclopSettings.showFloatingResults.value(in: settings)
        return OptimisationJob(request: request, operation: .optimise)
    }

    /// Whether the clipboard setting for `kind` lets a copied file through.
    public func clipboardAllows(_ kind: MediaKind) -> Bool {
        switch kind {
        case .image: return EsclopSettings.enableClipboardOptimiser.value(in: settings)
        case .video: return EsclopSettings.optimiseVideoClipboard.value(in: settings)
        case .pdf: return EsclopSettings.optimisePDFClipboard.value(in: settings)
        case .audio: return EsclopSettings.optimiseAudioClipboard.value(in: settings)
        }
    }

    /// The automatic size limits for `kind`: below `min` or above `max` bytes is skipped.
    public func sizeLimits(for kind: MediaKind) -> (min: Int, max: Int) {
        switch kind {
        case .image:
            return (EsclopSettings.minImageSizeKB.value(in: settings) * 1000, EsclopSettings.maxImageSizeMB.value(in: settings) * 1_000_000)
        case .video:
            return (EsclopSettings.minVideoSizeKB.value(in: settings) * 1000, EsclopSettings.maxVideoSizeMB.value(in: settings) * 1_000_000)
        case .pdf:
            return (0, EsclopSettings.maxPDFSizeMB.value(in: settings) * 1_000_000)
        case .audio:
            return (0, EsclopSettings.maxAudioSizeMB.value(in: settings) * 1_000_000)
        }
    }

    public func sizeSkip(_ bytes: Int, kind: MediaKind) -> Skip? {
        let limits = sizeLimits(for: kind)
        if bytes < limits.min { return .tooSmall }
        if bytes > limits.max { return .tooLarge }
        return nil
    }

    /// nil when a copied file should be optimised automatically, or why not.
    public func automaticSkip(for url: URL) -> Skip? {
        guard let kind = MediaKind.of(url) else { return .unsupported }
        guard clipboardAllows(kind) else { return .disabled }
        if OptimisedMark.isMarked(url) { return .alreadyOptimised }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        return sizeSkip(bytes, kind: kind)
    }
}
