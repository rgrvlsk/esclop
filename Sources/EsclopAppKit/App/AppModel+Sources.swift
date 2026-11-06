// SPDX-License-Identifier: GPL-3.0-or-later
//
// Where work comes from inside the app: the clipboard watcher, the drop zone and the hotkeys.

import AppKit
import EsclopCore
import EsclopIPC
import EsclopOptimisers
import Foundation
import UniformTypeIdentifiers

extension AppModel {
    // MARK: Clipboard

    /// What the clipboard watcher decided. Runs on the main actor, after the pasteboard reads.
    public func handleClipboard(_ action: ClipboardAction) {
        if case .ignore = action { return }
        if skipNextCopy {
            skipNextCopy = false
            return
        }
        switch action {
        case .ignore:
            return
        case let .optimiseImage(data, type):
            optimiseImageData(data, type: type, aggressive: false)
        case let .optimiseFiles(urls):
            optimise(urls, origin: .clipboard)
        }
    }

    /// Optimises files; results go back on the clipboard when they came from it and the setting
    /// says so.
    public func optimise(_ urls: [URL], origin: RequestOrigin, aggressive: Bool = false) {
        let copyBack = origin == .clipboard && EsclopSettings.autoCopyToClipboard.value(in: settings)
        for url in urls {
            let job = factory.job(for: url, origin: origin, aggressive: aggressive)
            Task {
                await run(job, onResult: { result in
                    guard copyBack else { return }
                    Clipboard.write(files: [result.output], to: self.pasteboard)
                })
            }
        }
    }

    /// Copied pixels: saved to a temporary file, optimised in place (the backup is the original),
    /// then put back on the clipboard.
    func optimiseImageData(_ data: Data, type: UTType, aggressive: Bool) {
        let file: URL
        do {
            guard let url = try Clipboard.materialise(.image(data, type)).first else { return }
            file = url
        } catch {
            notice("Could not read the copied image", CardPresentation.message(for: error))
            return
        }
        let copyBack = EsclopSettings.autoCopyToClipboard.value(in: settings)
        let job = factory.job(for: file, origin: .clipboard, aggressive: aggressive, location: .inPlace)
        Task {
            await run(job, displayName: "Copied image", onResult: { result in
                guard copyBack else { return }
                Clipboard.write(files: [result.output], to: self.pasteboard)
            })
        }
    }

    /// The hotkey and menu command: whatever is on the clipboard now, whatever the automatic
    /// rules say. Harder re-runs the last optimised copy from its original, as Clop does.
    public func optimiseClipboardNow(aggressive: Bool) {
        let content = Clipboard.read(pasteboard)
        if aggressive, Clipboard.isOwnWrite(pasteboard), case let .files(urls) = content,
           let result = recent.first(where: { r in urls.contains { $0.standardizedFileURL == r.output.standardizedFileURL } }),
           result.backup != nil
        {
            Task {
                await restore(result)
                if let card = cards.first(where: { $0.result?.id == result.id || $0.jobID == result.id }) { dismiss(card) }
                optimiseAgain(result.source, wasClipboardImage: result.source.path.hasPrefix(Paths.temporary.path))
            }
            return
        }
        switch content {
        case let .files(urls):
            let media = urls.filter { MediaKind.of($0) != nil }
            guard !media.isEmpty else { return notice("Nothing to optimise", "The copied files are not images, videos, PDFs or audio.") }
            optimise(media, origin: .clipboard, aggressive: aggressive)
        case let .path(url):
            optimise([url], origin: .clipboard, aggressive: aggressive)
        case let .image(data, type), let .base64Image(data, type):
            optimiseImageData(data, type: type, aggressive: aggressive)
        case .empty:
            notice("Nothing to optimise", "Copy an image or a file first.")
        }
    }

    private func optimiseAgain(_ source: URL, wasClipboardImage: Bool) {
        let location: OutputLocation? = wasClipboardImage ? .inPlace : nil
        let job = factory.job(for: source, origin: .clipboard, aggressive: true, location: location)
        let copyBack = EsclopSettings.autoCopyToClipboard.value(in: settings)
        Task {
            await run(job, displayName: wasClipboardImage ? "Copied image" : nil, onResult: { result in
                guard copyBack else { return }
                Clipboard.write(files: [result.output], to: self.pasteboard)
            })
        }
    }

    // MARK: Drop zone

    public func optimiseDropped(_ urls: [URL], harder: Bool) {
        let files = PathInput.expand(urls, recursive: true).filter { MediaKind.of($0) != nil }
        guard !files.isEmpty else { return notice("Nothing to optimise", "Drop images, videos, PDFs or audio files.") }
        optimise(files, origin: .dropZone, aggressive: harder)
    }

    // MARK: Pause

    /// The pause hotkey cycles like Clop's: running, then skip the next copy, then paused.
    public func cyclePause() {
        if paused {
            setPaused(false)
            notice("Running", "Watching the clipboard again.")
        } else if skipNextCopy {
            skipNextCopy = false
            setPaused(true)
            notice("Paused", "Automatic optimisation is off until you resume it.")
        } else {
            skipNextCopy = true
            notice("Skipping the next copy", "Press again to pause everything.")
        }
    }
}
