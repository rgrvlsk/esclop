// SPDX-License-Identifier: GPL-3.0-or-later
//
// Uploads from the floating results: the Share tab's Upload, and automatic uploads for the
// sources the `uploadAutomatically` setting names, from every result (a batch row shows its own).
// Each upload takes a turn at the same work gate
// as the jobs, shows its progress on the card, can be stopped, and on failure keeps the file and
// says why, with Upload Again. The link goes on the clipboard.

import AppKit
import EsclopCore
import EsclopIPC
import EsclopOptimisers
import Foundation

extension AppModel {
    /// The targets set up in Settings › Uploads.
    public var uploadTargets: [UploadTarget] { UploadTarget.all(in: settings) }

    /// Uploads the card's file to `target` (nil: the default one).
    public func upload(_ card: ResultCard, to target: String? = nil) {
        guard card.draggableFile != nil, card.upload.map({ if case .uploading = $0 { false } else { true } }) ?? true else { return }
        card.uploadTask?.cancel()
        card.uploadTarget = target
        // Stays on screen while it goes.
        card.machine.refreshed(at: now(), hideAfter: nil)
        card.uploadTask = upload(card.shownFile, to: target, on: card) { [weak self, weak card] in
            guard let self, let card else { return }
            card.uploadTask = nil
            self.settle(card)
        }
        afterChange(card)
    }

    /// Uploads `file` at a turn of the work gate, with its progress and outcome on `view` (a card,
    /// a batch row, or nothing for a result shown nowhere). The link goes on the clipboard.
    @discardableResult
    func upload(_ file: URL, to target: String?, on view: (any ShowsUpload)?, finished: @escaping @MainActor () -> Void = {}) -> Task<Void, Never> {
        let uploader = uploader, gate = gate
        view?.upload = .uploading(fraction: 0)
        return Task { [weak self] in
            await gate.acquire()
            let outcome: Result<URL, EsclopError>
            do {
                try Task.checkCancellation()
                let link = try await uploader.upload(file, to: target) { fraction in
                    Task { @MainActor in
                        guard let view, case let .uploading(current) = view.upload, fraction > current else { return }
                        view.upload = .uploading(fraction: fraction)
                    }
                }
                outcome = .success(link)
            } catch {
                outcome = .failure(Task.isCancelled ? .cancelled : .wrap(error))
            }
            await gate.release()
            guard let self else { return }
            switch outcome {
            case let .success(link):
                view?.upload = .uploaded(link)
                self.copyLink(link)
                self.announce(Strings.format("%@ uploaded, the link is on the clipboard", file.lastPathComponent))
            case .failure(.cancelled):
                view?.upload = nil
            case let .failure(error):
                view?.upload = .failed(CardPresentation.message(for: error))
                self.announce(Strings.format("%@ was not uploaded", file.lastPathComponent))
            }
            finished()
        }
    }

    /// The link on the clipboard, marked as L'Esclop's own so the clipboard watcher leaves it.
    // ponytail: written on the main thread, not on `ClipboardKeeper.queue` where the watcher
    // reads; move it there (the upload tests read the clipboard right after) if it ever races.
    public func copyLink(_ link: URL) {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, .URL, Clipboard.optimisedType], owner: nil)
        pasteboard.setString(link.absoluteString, forType: .string)
        pasteboard.setString(link.absoluteString, forType: .URL)
        pasteboard.setData(Data(), forType: Clipboard.optimisedType)
    }

    /// Whether this job's results are uploaded on their own (`uploadAutomatically`).
    func uploadsAutomatically(_ job: OptimisationJob) -> Bool {
        if case .upload = job.operation { return false }
        // A pipeline with its own upload step has uploaded already.
        if case let .pipeline(name) = job.operation, (try? service.context.pipelines.resolve(name))?.usesUploads ?? false { return false }
        let sources = EsclopSettings.uploadAutomatically.value(in: settings)
        return sources.contains(job.request.origin.rawValue) && !uploadTargets.isEmpty
    }

    /// The sources automatic uploads can follow, in the order Settings lists them.
    public static let automaticUploadSources: [RequestOrigin] = [.clipboard, .dropZone, .watchedFolder, .finder]
}

/// Where an upload shows its progress and outcome: a floating result or a batch window row.
@MainActor protocol ShowsUpload: AnyObject, Sendable {
    var upload: ResultCard.UploadState? { get set }
}
