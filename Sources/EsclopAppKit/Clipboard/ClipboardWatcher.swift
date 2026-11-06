// SPDX-License-Identifier: GPL-3.0-or-later
//
// Polls NSPasteboard's change count twice a second, as Clop does. Every pasteboard read happens
// on one serial queue, never the main thread: the pasteboard server answers over XPC and can be
// slow, and NSPasteboard is not safe to read from two threads. Only the decision crosses over.

import AppKit
import EsclopOptimisers
import Foundation

public final class ClipboardWatcher: @unchecked Sendable {
    // Everything below is touched only on `queue`.
    private let pasteboard: NSPasteboard
    private let queue = DispatchQueue(label: "dev.esclop.app.clipboard", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastChangeCount: Int
    private var lastPaused: Bool?

    private let policy: ClipboardPolicy
    private let frontmostApp: @Sendable () -> String?
    private let onAction: @Sendable (ClipboardAction) -> Void
    private let onPauseChange: @Sendable (Bool) -> Void

    public init(
        pasteboard: NSPasteboard = .general,
        policy: ClipboardPolicy,
        frontmostApp: @escaping @Sendable () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        onPauseChange: @escaping @Sendable (Bool) -> Void = { _ in },
        onAction: @escaping @Sendable (ClipboardAction) -> Void
    ) {
        self.pasteboard = pasteboard
        self.policy = policy
        self.frontmostApp = frontmostApp
        self.onAction = onAction
        self.onPauseChange = onPauseChange
        lastChangeCount = pasteboard.changeCount
    }

    public func start(interval: TimeInterval = 0.5) {
        queue.async { [self] in
            guard timer == nil else { return }
            // What is already on the clipboard at launch is not a new copy.
            lastChangeCount = pasteboard.changeCount
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in _ = self?.tick() }
            timer.resume()
            self.timer = timer
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

    private func tick() -> ClipboardAction? {
        let paused = policy.isPaused
        if paused != lastPaused {
            lastPaused = paused
            onPauseChange(paused)
        }
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return nil }
        lastChangeCount = count
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        let pasteboard = pasteboard
        let action = policy.decide(types: types, content: { Clipboard.read(pasteboard) }, frontmostApp: frontmostApp())
        onAction(action)
        return action
    }
}
