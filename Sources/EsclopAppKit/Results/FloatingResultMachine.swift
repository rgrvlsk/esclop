// SPDX-License-Identifier: GPL-3.0-or-later
//
// What one floating result is doing, as a value (DESIGN.md › Floating result): its level, whether
// the hover buttons show and when it hides. Time comes in from outside as
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

    public enum Effect: Equatable, Sendable {
        case dismiss
    }

    /// A still pointer opens the detail after this long; a plain pass only shows the buttons.
    public static let dwell: TimeInterval = 0.6
    /// The pointer can cross the gap between the thumbnail and its buttons without them fading.
    public static let leaveGrace: TimeInterval = 0.15
    /// A result whose time ran out while dismissal was paused goes this long after the pause ends.
    public static let lateHide: TimeInterval = 2

    public private(set) var level: Level = .thumbnail
    public private(set) var stage: Stage = .working
    public private(set) var hovering = false
    public private(set) var focused = false
    public private(set) var dragging = false
    /// The options popover is open.
    public private(set) var menuOpen = false
    public private(set) var dwellDeadline: Date?
    public private(set) var leaveDeadline: Date?
    public private(set) var hideDeadline: Date?
    /// The result's own hide delay, given again when the person closes its detail.
    private var hideAfter: TimeInterval?

    public init() {}

    // MARK: Derived

    /// The pointer is on the object, or just crossed to its buttons.
    var pointerInside: Bool { hovering || leaveDeadline != nil }

    /// The row stays while the options popover is open, even while a choice from it runs again,
    /// so the popover keeps its anchor.
    public var showsHoverButtons: Bool {
        guard level == .thumbnail else { return false }
        return menuOpen || stage == .finished && (pointerInside || focused)
    }

    /// Dismissal pauses while the object is hovered, focused, dragged or open.
    public var isDismissalPaused: Bool {
        pointerInside || focused || dragging || menuOpen || level == .detail
    }

    public var nextDeadline: Date? {
        var dates = [dwellDeadline, leaveDeadline].compactMap { $0 }
        if !isDismissalPaused, let hideDeadline { dates.append(hideDeadline) }
        return dates.min()
    }

    // MARK: Job

    /// The same file runs again with another choice (from the options popover or a hover
    /// button): back to working, keeping the level, the pointer and the open popover.
    public mutating func restarted() {
        stage = .working
        dwellDeadline = nil
        hideDeadline = nil
    }

    public mutating func finished(at now: Date, hideAfter: TimeInterval?) {
        stage = .finished
        self.hideAfter = hideAfter
        hideDeadline = hideAfter.map { now + $0 }
        if hovering { armDwell(now) }
    }

    public mutating func failed(at now: Date, hideAfter: TimeInterval?) {
        stage = .failed
        level = .thumbnail
        dwellDeadline = nil
        self.hideAfter = hideAfter
        hideDeadline = hideAfter.map { now + $0 }
    }

    public mutating func notice(at now: Date, hideAfter: TimeInterval) {
        stage = .notice
        self.hideAfter = hideAfter
        hideDeadline = now + hideAfter
    }

    /// The result changed in place (a restore): start its time again at the thumbnail.
    public mutating func refreshed(at now: Date, hideAfter: TimeInterval?) {
        level = .thumbnail
        dwellDeadline = nil
        self.hideAfter = hideAfter
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

    public mutating func openDetail(at now: Date) {
        guard stage == .finished else { return }
        level = .detail
        dwellDeadline = nil
    }

    /// Back to the thumbnail. Closed by hand, the result gets its whole hide delay again: its
    /// time may have run out while the detail was open, and it would vanish moments later.
    public mutating func closeDetail(at now: Date) {
        guard level == .detail else { return }
        level = .thumbnail
        dwellDeadline = nil
        if let hideAfter, let deadline = hideDeadline {
            hideDeadline = max(deadline, now + hideAfter)
        }
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
        if !isDismissalPaused, let hideDeadline, hideDeadline <= now {
            self.hideDeadline = nil
            return .dismiss
        }
        return nil
    }

    // MARK: Private

    private mutating func armDwell(_ now: Date) {
        dwellDeadline = stage == .finished && level == .thumbnail && !menuOpen && !dragging ? now + Self.dwell : nil
    }

    /// When the pause ends after the time ran out, the result goes a little later, not at once.
    private mutating func resumeHide(_ now: Date) {
        guard !isDismissalPaused, let hideDeadline, hideDeadline <= now else { return }
        self.hideDeadline = now + Self.lateHide
    }
}
