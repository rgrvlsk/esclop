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

    /// Uploads the card's file to `target` (nil: the default one). `automatic` (the
    /// `uploadAutomatically` setting) keeps a copy the person made meanwhile on the clipboard.
    public func upload(_ card: ResultCard, to target: String? = nil, automatic: Bool = false) {
        guard card.draggableFile != nil, card.upload.map({ if case .uploading = $0 { false } else { true } }) ?? true else { return }
        card.uploadTask?.cancel()
        card.uploadTarget = target
        // Stays on screen while it goes.
        card.machine.refreshed(at: now(), hideAfter: nil)
        card.uploadTask = upload(card.shownFile, to: target, on: card, automatic: automatic) { [weak self, weak card] in
            guard let self, let card else { return }
            card.uploadTask = nil
            self.settle(card)
        }
        afterChange(card)
    }

    /// Uploads `file` at a turn of the work gate, with its progress and outcome on `view` (a card,
    /// a batch row, or nothing for a result shown nowhere). The link goes on the clipboard; an
    /// automatic upload's only if nothing was copied since it started, and a batch's links all at
    /// once when the batch and its uploads are over.
    // ponytail: a card whose automatic link stayed off the clipboard still reads "link copied";
    // its Copy Link works. Give `UploadState.uploaded` a flag if that ever confuses someone.
    @discardableResult
    func upload(
        _ file: URL, to target: String?, on view: (any ShowsUpload)?, batch: Batch? = nil, automatic: Bool = false,
        finished: @escaping @MainActor () -> Void = {}
    ) -> Task<Void, Never> {
        let uploader = uploader, gate = gate
        view?.upload = .uploading(fraction: 0)
        return Task { [weak self] in
            var since: Int?
            if automatic, let self {
                since = await self.clipboard.run { $0.changeCount() }
                if let batch, batch.linksSince == nil { batch.linksSince = since }
            }
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
                if batch != nil {
                    view?.upload = .uploaded(link)
                    self.announce(Strings.format("%@ uploaded", file.lastPathComponent))
                } else {
                    // On the clipboard before the card says so.
                    let copied = await self.copyToClipboard(links: [link], since: since)
                    view?.upload = .uploaded(link)
                    self.announce(copied
                        ? Strings.format("%@ uploaded, the link is on the clipboard", file.lastPathComponent)
                        : Strings.format("%@ uploaded", file.lastPathComponent))
                }
            case .failure(.cancelled):
                view?.upload = nil
            case let .failure(error):
                view?.upload = .failed(CardPresentation.message(for: error))
                self.announce(Strings.format("%@ was not uploaded", file.lastPathComponent))
                // A result shown nowhere (a quiet pipeline) has no other place to say why.
                if view == nil { self.notice(Strings.format("%@ was not uploaded", file.lastPathComponent), CardPresentation.message(for: error)) }
            }
            // Whichever upload ends last, whatever its outcome, puts the batch's links on the clipboard.
            if let batch { self.copyLinks(of: batch) }
            finished()
        }
    }

    /// Copy Link: the link on the clipboard as L'Esclop's own, whatever it holds (the person asked).
    public func copyLink(_ link: URL) {
        Task { await copyToClipboard(links: [link]) }
    }

    /// A batch's links, one per line in row order, once the batch has ended and none of its
    /// uploads is still going; only if nothing was copied since its first upload started.
    func copyLinks(of batch: Batch) {
        guard !batch.isRunning, !batch.rows.contains(where: { if case .uploading = $0.upload { true } else { false } }) else { return }
        let links = batch.rows.compactMap { row -> URL? in if case let .uploaded(link) = row.upload { link } else { nil } }
        guard !links.isEmpty else { return }
        let since = batch.linksSince
        Task { await copyToClipboard(links: links, since: since) }
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
