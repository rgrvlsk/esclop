// SPDX-License-Identifier: GPL-3.0-or-later
//
// Polls NSPasteboard's change count twice a second, as Clop does, and every 2 seconds while
// paused. Every pasteboard read happens on `ClipboardKeeper.queue`, never the main thread: the
// pasteboard server answers over XPC and can be slow, and NSPasteboard is not safe to read from
// two threads. Only the decision crosses over, with the copy's change count, app and types.

import AppKit
import EsclopOptimisers
import Foundation

public final class ClipboardWatcher: @unchecked Sendable {
    // Everything below is touched only on `queue`.
    private let pasteboard: NSPasteboard
    private let queue = ClipboardKeeper.queue
    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval = 0.5
    private var lastChangeCount: Int
    private var lastPaused: Bool?
    /// The app in front at the last poll.
    private var lastApp: String?

    private let policy: ClipboardPolicy
    private let frontmostApp: @Sendable () -> String?
    private let onAction: @Sendable (ClipboardAction) -> Void
    private let onPauseChange: @Sendable (Bool) -> Void
    /// Every copy, on the queue, before the decision: a pipeline hotkey run later names its app.
    private let onCopy: @Sendable (ClipboardCopy) -> Void

    static let pausedInterval: TimeInterval = 2

    public init(
        pasteboard: NSPasteboard = .general,
        policy: ClipboardPolicy,
        frontmostApp: @escaping @Sendable () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        onPauseChange: @escaping @Sendable (Bool) -> Void = { _ in },
        onCopy: @escaping @Sendable (ClipboardCopy) -> Void = { _ in },
        onAction: @escaping @Sendable (ClipboardAction) -> Void
    ) {
        self.pasteboard = pasteboard
        self.policy = policy
        self.frontmostApp = frontmostApp
        self.onAction = onAction
        self.onPauseChange = onPauseChange
        self.onCopy = onCopy
        lastChangeCount = pasteboard.changeCount
    }

    public func start(interval: TimeInterval = 0.5) {
        queue.async { [self] in
            guard timer == nil else { return }
            // What is already on the clipboard at launch is not a new copy.
            lastChangeCount = pasteboard.changeCount
            self.interval = interval
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in _ = self?.tick() }
            self.timer = timer
            schedule(paused: policy.isPaused)
            timer.resume()
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    /// One poll, now. Returns the decision when the clipboard changed since the last poll.
    @discardableResult
    public func poll() -> ClipboardAction? {
        queue.sync { tick() }
    }

    private func schedule(paused: Bool) {
        let every = paused ? max(interval, Self.pausedInterval) : interval
        timer?.schedule(deadline: .now() + every, repeating: every, leeway: .milliseconds(100))
    }

    private func tick() -> ClipboardAction? {
        let paused = policy.isPaused
        if paused != lastPaused {
            if lastPaused != nil { schedule(paused: paused) }
            lastPaused = paused
            onPauseChange(paused)
        }
        // ponytail: the copy is attributed to the apps in front at this poll and the one before;
        // an app in front only between two polls (0.5 s) is missed. Follow app activations
        // (NSWorkspace.didActivateApplicationNotification) if an ignored app's copy gets through.
        let appBefore = lastApp
        let app = frontmostApp()
        lastApp = app
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return nil }
        lastChangeCount = count
        let copy = ClipboardCopy(changeCount: count, app: app, types: Set((pasteboard.types ?? []).map(\.rawValue)))
        onCopy(copy)
        let pasteboard = pasteboard
        let readsText = policy.readsText, readsAddresses = policy.readsAddresses
        let action = policy.decide(copy, appBefore: appBefore == app ? nil : appBefore) {
            ClipboardPolicy.read(pasteboard, text: readsText, addresses: readsAddresses)
        }
        onAction(action)
        return action
    }
}
