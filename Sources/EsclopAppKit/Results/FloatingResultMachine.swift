// SPDX-License-Identifier: GPL-3.0-or-later
//
// What one floating result is doing, as a value (DESIGN.md › Floating result): its level, whether
// the hover buttons show, the activity capsule and when it hides. Time comes in from outside as
// `now`, so tests drive it with a fixed clock and the app with the real one; the app model sleeps
// until `nextDeadline` and calls `advance(to:)`.

import Foundation

public struct FloatingResultMachine: Equatable, Sendable {
    public enum Level: Equatable, Sendable {
        /// The ~200 pt thumbnail with its capsule.
        case thumbnail
        /// The 320 pt card: comparison, metrics, actions.
        case detail
    }

    public enum Stage: Equatable, Sendable {
        case working
        /// A result, "already optimised" or a restored original: something to act on.
        case finished
        /// A short message with no file (the pause hotkey). No detail, no buttons.
        case notice
        case failed
    }

    public enum Activity: Equatable, Sendable {
        case hidden
        /// The capsule out of the thumbnail's left edge, with the ring and the time left.
        case running
        /// Showing the result until the date, then it retracts.
        case finished(until: Date)
    }

    public enum Effect: Equatable, Sendable {
        case dismiss
        case retry
    }

    /// A still pointer opens the detail after this long; a plain pass only shows the buttons.
    public static let dwell: TimeInterval = 0.6
    /// Jobs expected to take longer than this get the activity capsule.
    public static let activityThreshold: TimeInterval = 2
    /// The activity capsule shows the result this long, then retracts.
    public static let activityLinger: TimeInterval = 2
    /// The pointer can cross the gap between the thumbnail and its buttons without them fading.
    public static let leaveGrace: TimeInterval = 0.15
    /// A result whose time ran out while dismissal was paused goes this long after the pause ends.
    public static let lateHide: TimeInterval = 2

    public private(set) var level: Level = .thumbnail
    public private(set) var stage: Stage = .working
    public private(set) var activity: Activity
    public private(set) var hovering = false
    public private(set) var focused = false
    public private(set) var dragging = false
    /// The options popover is open.
    public private(set) var menuOpen = false
    public private(set) var dwellDeadline: Date?
    public private(set) var leaveDeadline: Date?
    public private(set) var hideDeadline: Date?

    public init(expectedDuration: TimeInterval) {
        activity = expectedDuration > Self.activityThreshold ? .running : .hidden
    }

    // MARK: Derived

    /// The pointer is on the object, or just crossed to its buttons.
    var pointerInside: Bool { hovering || leaveDeadline != nil }

    public var showsHoverButtons: Bool {
        stage == .finished && level == .thumbnail && (pointerInside || focused || menuOpen)
    }

    /// Dismissal pauses while the object is hovered, focused, dragged or open.
    public var isDismissalPaused: Bool {
        pointerInside || focused || dragging || menuOpen || level == .detail
    }

    public var nextDeadline: Date? {
        var dates = [dwellDeadline, leaveDeadline].compactMap { $0 }
        if case let .finished(until) = activity { dates.append(until) }
        if !isDismissalPaused, let hideDeadline { dates.append(hideDeadline) }
        return dates.min()
    }

    // MARK: Job

    /// A better estimate arrived while the job runs (a video's metadata loaded).
    public mutating func estimateChanged(_ expectedDuration: TimeInterval) {
        guard stage == .working else { return }
        activity = expectedDuration > Self.activityThreshold ? .running : .hidden
    }

    public mutating func finished(at now: Date, hideAfter: TimeInterval?) {
        stage = .finished
        if activity == .running { activity = .finished(until: now + Self.activityLinger) }
        hideDeadline = hideAfter.map { now + max($0, activityDeadline.map { $0.timeIntervalSince(now) } ?? 0) }
        if hovering { armDwell(now) }
    }

    public mutating func failed(at now: Date, hideAfter: TimeInterval?) {
        stage = .failed
        level = .thumbnail
        activity = .hidden
        dwellDeadline = nil
        hideDeadline = hideAfter.map { now + $0 }
    }

    public mutating func notice(at now: Date, hideAfter: TimeInterval) {
        stage = .notice
        activity = .hidden
        hideDeadline = now + hideAfter
    }

    /// The result changed in place (a restore): start its time again at the thumbnail.
    public mutating func refreshed(at now: Date, hideAfter: TimeInterval?) {
        level = .thumbnail
        dwellDeadline = nil
        hideDeadline = hideAfter.map { now + $0 }
    }

    // MARK: Pointer and focus

    public mutating func pointerEntered(at now: Date) {
        hovering = true
        leaveDeadline = nil
        armDwell(now)
    }

    /// The pointer is on the row of buttons: the object stays hovered, but resting on a button
    /// never opens the detail.
    public mutating func pointerEnteredButtons(at now: Date) {
        hovering = true
        leaveDeadline = nil
        dwellDeadline = nil
    }

    /// Any movement restarts the dwell: only a still pointer opens the detail.
    public mutating func pointerMoved(at now: Date) {
        guard hovering else { return }
        armDwell(now)
    }

    public mutating func pointerExited(at now: Date) {
        guard hovering else { return }
        hovering = false
        dwellDeadline = nil
        leaveDeadline = now + Self.leaveGrace
    }

    public mutating func setFocused(_ value: Bool, at now: Date) {
        focused = value
        resumeHide(now)
    }

    public mutating func setDragging(_ value: Bool, at now: Date) {
        dragging = value
        if value { dwellDeadline = nil }
        resumeHide(now)
    }

    public mutating func setMenuOpen(_ value: Bool, at now: Date) {
        menuOpen = value
        dwellDeadline = nil
        resumeHide(now)
    }

    // MARK: Levels

    /// A click on the capsule: the detail for a result, another try for an error.
    public mutating func capsuleClicked(at now: Date) -> Effect? {
        switch stage {
        case .failed: return .retry
        case .finished: openDetail(at: now)
        case .working, .notice: break
        }
        return nil
    }

    public mutating func openDetail(at now: Date) {
        guard stage == .finished else { return }
        level = .detail
        dwellDeadline = nil
    }

    public mutating func closeDetail(at now: Date) {
        guard level == .detail else { return }
        level = .thumbnail
        dwellDeadline = nil
        resumeHide(now)
    }

    // MARK: Time

    /// Applies every deadline that has passed. Returns what the owner has to do.
    public mutating func advance(to now: Date) -> Effect? {
        if let leaveDeadline, leaveDeadline <= now {
            self.leaveDeadline = nil
            resumeHide(now)
        }
        if let dwellDeadline, dwellDeadline <= now {
            self.dwellDeadline = nil
            if hovering, stage == .finished, !menuOpen, !dragging { level = .detail }
        }
        if let until = activityDeadline, until <= now { activity = .hidden }
        if !isDismissalPaused, let hideDeadline, hideDeadline <= now {
            self.hideDeadline = nil
            return .dismiss
        }
        return nil
    }

    // MARK: Private

    private var activityDeadline: Date? {
        if case let .finished(until) = activity { return until }
        return nil
    }

    private mutating func armDwell(_ now: Date) {
        dwellDeadline = stage == .finished && level == .thumbnail && !menuOpen && !dragging ? now + Self.dwell : nil
    }

    /// When the pause ends after the time ran out, the result goes a little later, not at once.
    private mutating func resumeHide(_ now: Date) {
        guard !isDismissalPaused, let hideDeadline, hideDeadline <= now else { return }
        self.hideDeadline = now + Self.lateHide
    }
}
