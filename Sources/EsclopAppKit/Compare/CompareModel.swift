// SPDX-License-Identifier: GPL-3.0-or-later
//
// The compare window's state: which result it shows (following its floating result when that
// runs again with another choice), the two files, how they are laid out, zoom and pan, the
// difference overlay, the PDF page and the players. Actions go through the app model, so keep,
// restore and "try another" do what the floating result's buttons do.

import AppKit
import EsclopCore
import Foundation
import Observation

@MainActor @Observable
public final class CompareModel {
    public enum Mode: String, CaseIterable, Sendable {
        /// The original left of a draggable divider, the optimised file right of it.
        case split
        /// Both side by side, zoomed and panned together.
        case sideBySide
        /// One at a time in place; Space flips.
        case flip
    }

    /// The result shown when its floating result is gone.
    public private(set) var stored: OptimisationResult?
    /// The last link named a result the app no longer knows; the window says so.
    public private(set) var isUnknown = false
    /// The floating result the window follows, when there is one.
    @ObservationIgnored private var cardID: UUID?
    /// Undone from this window (the app's own list is not observed).
    private var restoredHere = Set<UUID>()

    public var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }
    public var viewport = CompareViewport()
    /// Flip mode shows the original.
    public var showsOriginal = false
    public var showsDifference = false
    /// The PDF page both sides show.
    public var page = 0 {
        didSet { if page != oldValue { Task { await load() } } }
    }

    public private(set) var pageCount = 0
    public private(set) var beforeImage: CGImage?
    public private(set) var afterImage: CGImage?
    private(set) var difference: CompareMedia.Difference?
    private(set) var players: ComparePlayers?
    /// What the loaded media belong to, so a reload only happens when that changes.
    @ObservationIgnored private var loadedKey: String?

    @ObservationIgnored let app: AppModel
    nonisolated static let modeKey = "compareMode"

    public init(app: AppModel) {
        self.app = app
        mode = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(Mode.init(rawValue:)) ?? .split
    }

    // MARK: What is shown

    var card: ResultCard? {
        guard let cardID else { return nil }
        return app.cards.first { $0.id == cardID }
    }

    /// The result on screen: the card's latest when it has one, else the one opened.
    public var result: OptimisationResult? { card?.result ?? stored }

    /// The card is running again ("try another").
    public var isWorking: Bool { card?.isWorking ?? false }

    public var sides: CompareSides {
        guard let result else { return .gone }
        let restored = restoredHere.contains(result.id) || app.restoredIDs.contains(result.id)
            || { if case .restored = card?.phase { return true } else { return false } }()
        return CompareSides.resolve(result, restored: restored)
    }

    public var kind: MediaKind? { result?.kind }

    /// The size the picture is laid out at, in pixels: the original's, so both sides line up.
    public var pixels: CGSize {
        let image = beforeImage ?? afterImage
        return image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
    }

    // MARK: Opening

    /// Shows `result`, following its floating result if there is one.
    public func open(_ result: OptimisationResult) {
        stored = result
        cardID = app.cards.first { $0.result?.id == result.id }?.id
        isUnknown = false
        reset()
    }

    /// Opens a result by id: the app's recent results, then the shared log. False when unknown,
    /// and then the comparison on screen is cleared, so the window never shows another result.
    @discardableResult
    public func open(id: UUID) -> Bool {
        if let card = app.cards.first(where: { $0.result?.id == id }), let result = card.result {
            open(result)
            return true
        }
        let known = app.recent + app.service.results.recent(limit: 500)
        guard let result = known.first(where: { $0.id == id }) else {
            stored = nil
            cardID = nil
            isUnknown = true
            reset()
            return false
        }
        open(result)
        return true
    }

    private func reset() {
        players?.stop()
        players = nil
        loadedKey = nil
        beforeImage = nil
        afterImage = nil
        difference = nil
        viewport = CompareViewport()
        showsOriginal = false
        page = 0
        pageCount = 0
    }

    /// Changes when something on screen needs loading: another result, page or state.
    public var loadKey: String { "\(result?.id.uuidString ?? "-")|\(page)|\(sides)" }

    /// Loads what the current result and page need; does nothing when they are loaded.
    public func load() async {
        guard let result else { return }
        let sides = sides
        let key = loadKey

        guard key != loadedKey else { return }
        loadedKey = key
        guard let after = sides.after else {
            beforeImage = nil
            afterImage = nil
            difference = nil
            return
        }
        let before = sides.before
        switch result.kind {
        case .image, .pdf:
            let page = page, isPDF = result.kind == .pdf
            let loaded = await Task.detached(priority: .userInitiated) { () -> (CGImage?, CGImage?, Int, CompareMedia.Difference?) in
                let count = isPDF ? max(CompareMedia.pageCount(of: after), before.map(CompareMedia.pageCount(of:)) ?? 0) : 1
                let a = before.flatMap { isPDF ? CompareMedia.page(page, of: $0) : CompareMedia.image(at: $0) }
                let b = isPDF ? CompareMedia.page(page, of: after) : CompareMedia.image(at: after)
                let diff = a.flatMap { a in b.flatMap { CompareMedia.difference(a, $0) } }
                return (a, b, count, diff)
            }.value
            guard key == loadedKey else { return }
            beforeImage = loaded.0
            afterImage = loaded.1
            pageCount = loaded.2
            difference = loaded.3
        case .video, .audio:
            players?.stop()
            players = before.map { ComparePlayers(before: $0, after: after, isAudio: result.kind == .audio) }
        }
    }

    // MARK: Actions

    /// Keeps the optimised file: the floating result goes and the window closes.
    public func keep() {
        if let card { app.dismiss(card) }
        close()
    }

    /// Puts the original back; the window then says so.
    public func restore() async {
        guard let result else { return }
        players?.stop()
        await app.restore(result)
        restoredHere.insert(result.id)
    }

    /// Runs the file again from the original with `choice`; the window follows the new result.
    public func tryAgain(with choice: OptimiseChoice) {
        guard let result else { return }
        players?.stop()
        players = nil
        let card = card ?? app.cardShowing(result)
        cardID = card.id
        app.apply(choice, to: card)
    }

    /// The choice the result was made with, to start "try another" from.
    public var choice: OptimiseChoice { card?.choice ?? .standard }

    public func copy() {
        guard let after = sides.after else { return }
        app.writeClipboard(files: [after])
    }

    public func reveal() {
        guard let file = sides.after ?? result?.source else { return }
        app.reveal([file])
    }

    @ObservationIgnored var onClose: () -> Void = {}

    public func close() {
        players?.stop()
        onClose()
    }

    // MARK: Pages

    public func nextPage() { if page + 1 < pageCount { page += 1 } }
    public func previousPage() { if page > 0 { page -= 1 } }
}
