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
    /// The picture of the current file, at its own aspect ratio.
    public var thumbnail: NSImage?
    /// The original's picture, for the before and after comparison in the detail.
    public var originalThumbnail: NSImage?
    /// Level, hover, activity and auto-hide (DESIGN.md › Floating result).
    public var machine: FloatingResultMachine
    /// How long the job should take; over two seconds it gets the activity capsule.
    public var expectedDuration: TimeInterval
    /// When the work started, for the time left.
    public var startedAt = Date()
    /// The deflate plays once per card, the first time the result is drawn.
    public var hasPlayedArrival = false
    /// Where the file came from and the format it arrived in (DESIGN.md › Origin rules).
    public var fileOrigin: FileOrigin?
    public var inputType: String?
    /// How the current result was made: the default, a suggestion, a rule or a popover choice.
    public var choice: OptimiseChoice = .standard
    /// The clipboard rule that chose `choice`, shown as a glyph on the capsule.
    public var appliedRule: ClipboardRule?
    /// The hover buttons the person kept (`hoverButtons`); "…" always shows.
    public var hoverButtons = ["undo", "convert", "downscale", "crop"]
    /// Which tab the options popover opens on (Crop opens Size).
    public var optionsTab: OptionsTab = .optimise
    /// Where the pointer was when the dwell started counting.
    var dwellAnchor: CGPoint?
    /// Runs the job again after an error.
    var retry: (() -> Void)?
    var cancelWork: (() -> Void)?
    var timer: Task<Void, Never>?

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
        let expected = JobEstimate.expectedSeconds(kind: MediaKind.of(source), bytes: bytesBefore, aggressive: aggressive)
        expectedDuration = expected
        // A card that starts finished (a recent result shown again) never gets the activity capsule.
        var isWorking = false
        if case .working = phase { isWorking = true }
        var machine = FloatingResultMachine(expectedDuration: isWorking ? expected : 0)
        switch phase {
        case .working: break
        case .failed: machine.failed(at: Date(), hideAfter: nil)
        case .notice: machine.notice(at: Date(), hideAfter: 3)
        default: machine.finished(at: Date(), hideAfter: nil)
        }
        self.machine = machine
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

    /// The file the card stands for: the optimised output, the original once restored, else the
    /// source. Show in Finder and Copy use it.
    public var shownFile: URL {
        switch phase {
        case let .done(result): return result.output
        case let .restored(result): return result.source
        default: return source
        }
    }

    /// The file the thumbnail can be dragged out as, or nil while there is nothing finished to give.
    public var draggableFile: URL? {
        switch phase {
        case .done, .unchanged, .restored: return shownFile
        default: return nil
        }
    }
}
