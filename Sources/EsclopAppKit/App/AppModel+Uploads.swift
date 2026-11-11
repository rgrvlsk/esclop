// SPDX-License-Identifier: GPL-3.0-or-later
//
// Uploads from the floating results: the Share tab's Upload, and automatic uploads for the
// sources the `uploadAutomatically` setting names. Each upload takes a turn at the same work gate
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
        let file = card.shownFile
        let uploader = uploader, gate = gate
        card.uploadTask?.cancel()
        card.uploadTarget = target
        card.upload = .uploading(fraction: 0)
        // Stays on screen while it goes.
        card.machine.refreshed(at: now(), hideAfter: nil)
        afterChange(card)
        let cardID = card.id
        card.uploadTask = Task { [weak self, weak card] in
            await gate.acquire()
            let outcome: Result<URL, EsclopError>
            do {
                try Task.checkCancellation()
                let link = try await uploader.upload(file, to: target) { [weak self] fraction in
                    Task { @MainActor in self?.uploadProgress(fraction, cardID: cardID) }
                }
                outcome = .success(link)
            } catch {
                outcome = .failure(Task.isCancelled ? .cancelled : .wrap(error))
            }
            await gate.release()
            guard let self, let card else { return }
            switch outcome {
            case let .success(link):
                card.upload = .uploaded(link)
                self.copyLink(link)
                self.announce(Strings.format("%@ uploaded, the link is on the clipboard", file.lastPathComponent))
            case .failure(.cancelled):
                card.upload = nil
            case let .failure(error):
                card.upload = .failed(CardPresentation.message(for: error))
                self.announce(Strings.format("%@ was not uploaded", file.lastPathComponent))
            }
            card.uploadTask = nil
            self.settle(card)
        }
    }

    private func uploadProgress(_ fraction: Double, cardID: UUID) {
        guard let card = cards.first(where: { $0.id == cardID }), case let .uploading(current) = card.upload, fraction > current else { return }
        card.upload = .uploading(fraction: fraction)
    }

    /// The link on the clipboard, marked as L'Esclop's own so the clipboard watcher leaves it.
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
        let sources = EsclopSettings.uploadAutomatically.value(in: settings)
        return sources.contains(job.request.origin.rawValue) && !uploadTargets.isEmpty
    }

    /// The sources automatic uploads can follow, in the order Settings lists them.
    public static let automaticUploadSources: [RequestOrigin] = [.clipboard, .dropZone, .watchedFolder, .finder]
}
