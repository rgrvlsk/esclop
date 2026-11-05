// SPDX-License-Identifier: GPL-3.0-or-later
//
// One floating result: a file being optimised, then what came of it. The app model owns the
// cards; the floating stack draws them.

import AppKit
import EsclopCore
import Foundation
import Observation

@MainActor @Observable
public final class ResultCard: Identifiable {
    public enum Phase {
        /// `fraction` is 0...1; the engine reports -1 when it cannot tell.
        case working(fraction: Double)
        case done(OptimisationResult)
        /// The optimiser found nothing smaller; the file was left as it was.
        case unchanged(bytes: Int)
        /// The backup went back in place of the result.
        case restored(OptimisationResult)
        case failed(String)
        /// A short message with no file (the pause hotkey's states).
        case notice(title: String, detail: String)
    }

    public let id = UUID()
    public let jobID: UUID
    public let source: URL
    public let origin: RequestOrigin
    public let aggressive: Bool
    /// The source size when the job started, so the working card can show it.
    public let bytesBefore: Int
    public var phase: Phase
    /// Shown instead of the file name, for files the person never named ("Copied image").
    public var displayName: String?
    public var thumbnail: NSImage?
    public var isHovered = false {
        didSet { if oldValue != isHovered { onHoverChange?(isHovered) } }
    }

    /// The deflate plays once per card, the first time the result is drawn.
    public var hasPlayedArrival = false
    var hideTask: Task<Void, Never>?
    var hideDeadline: Date?
    var cancelWork: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    public init(
        jobID: UUID, source: URL, origin: RequestOrigin, aggressive: Bool = false,
        bytesBefore: Int, phase: Phase = .working(fraction: 0)
    ) {
        self.jobID = jobID
        self.source = source
        self.origin = origin
        self.aggressive = aggressive
        self.bytesBefore = bytesBefore
        self.phase = phase
    }

    public var result: OptimisationResult? {
        if case let .done(result) = phase { return result }
        return nil
    }

    public var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    public var presentation: CardPresentation {
        CardPresentation(card: self)
    }
}
