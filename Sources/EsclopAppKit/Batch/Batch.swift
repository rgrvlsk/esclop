// SPDX-License-Identifier: GPL-3.0-or-later
//
// Many files at once (a dropped folder, "Optimise Files…", the CLI or an agent with a list):
// one row per file in the batch window instead of a floating result each, an aggregate saving,
// and controls for the whole lot: pause, cancel, restore all. The rows run through the same
// `AppModel.run` and work gate as single files.

import EsclopCore
import Foundation
import Observation

@MainActor @Observable
public final class BatchRow: Identifiable {
    public enum State: Equatable {
        case waiting
        /// 0...1, or -1 when the engine cannot tell.
        case working(Double)
        case done(OptimisationResult)
        /// Nothing smaller was found; the file was left as it was.
        case unchanged
        case failed(String)
        case cancelled
        case restored(OptimisationResult)

        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.waiting, .waiting), (.unchanged, .unchanged), (.cancelled, .cancelled): return true
            case let (.working(a), .working(b)): return a == b
            case let (.done(a), .done(b)), let (.restored(a), .restored(b)): return a.id == b.id
            case let (.failed(a), .failed(b)): return a == b
            default: return false
            }
        }
    }

    public let id = UUID()
    public let source: URL
    public let bytesBefore: Int
    public var state: State = .waiting
    /// Runs the file again (after an error or a cancel).
    var retry: (() -> Void)?
    var cancel: (() -> Void)?

    init(source: URL, bytesBefore: Int) {
        self.source = source
        self.bytesBefore = bytesBefore
    }

    public var result: OptimisationResult? {
        if case let .done(result) = state { return result }
        return nil
    }

    public var isFinished: Bool {
        switch state {
        case .waiting, .working: return false
        default: return true
        }
    }

    public var isRunning: Bool { !isFinished }

    /// The file the row stands for now: the result, the original once restored, else the source.
    public var shownFile: URL {
        switch state {
        case let .done(result): return result.output
        case let .restored(result): return result.source
        default: return source
        }
    }

    /// Bytes the file takes now, for the aggregate: the result, or the original.
    var bytesNow: Int {
        if case let .done(result) = state { return result.bytesAfter }
        return bytesBefore
    }
}

@MainActor @Observable
public final class Batch: Identifiable {
    public let id = UUID()
    public let origin: RequestOrigin
    public private(set) var rows: [BatchRow] = []
    /// Waiting files hold until resumed; files already running finish.
    public private(set) var paused = false
    public let startedAt: Date

    init(origin: RequestOrigin, startedAt: Date = Date()) {
        self.origin = origin
        self.startedAt = startedAt
    }

    @discardableResult
    func add(_ source: URL, bytes: Int) -> BatchRow {
        let row = BatchRow(source: source, bytesBefore: bytes)
        rows.append(row)
        return row
    }

    /// The row added for `source` ahead of its job, or a new one.
    func row(for source: URL, bytes: Int) -> BatchRow {
        rows.first { $0.source == source && $0.state == .waiting && $0.cancel == nil } ?? add(source, bytes: bytes)
    }

    public func remove(_ row: BatchRow) {
        guard row.isFinished else { return }
        rows.removeAll { $0.id == row.id }
    }

    // MARK: Figures

    public var total: Int { rows.count }
    public var finished: Int { rows.filter(\.isFinished).count }
    public var isRunning: Bool { rows.contains(where: \.isRunning) }
    public var optimised: Int { rows.filter { $0.result != nil }.count }
    public var unchanged: Int { rows.filter { $0.state == .unchanged }.count }
    public var failed: Int { rows.filter { if case .failed = $0.state { return true } else { return false } }.count }
    public var cancelled: Int { rows.filter { $0.state == .cancelled }.count }
    public var restorable: [BatchRow] { rows.filter { $0.result?.backup != nil } }

    public var restored: Int { rows.filter { if case .restored = $0.state { return true } else { return false } }.count }

    /// The originals of the files the engine went through (optimised, already optimised or
    /// restored), and what they take now: the aggregate saving. Stopped and failed files were
    /// never changed, so they would only dilute it.
    public var bytesBefore: Int { counted.map(\.bytesBefore).reduce(0, +) }
    public var bytesAfter: Int { counted.map(\.bytesNow).reduce(0, +) }

    private var counted: [BatchRow] {
        rows.filter {
            switch $0.state {
            case .done, .unchanged, .restored: return true
            default: return false
            }
        }
    }

    /// 0...1 across every file, counting each running file by its own progress.
    public var progress: Double {
        guard total > 0 else { return 1 }
        let done = rows.reduce(0.0) { sum, row in
            switch row.state {
            case .waiting: return sum
            case let .working(fraction): return sum + max(0, min(1, fraction))
            default: return sum + 1
            }
        }
        return done / Double(total)
    }

    // MARK: Control

    public func pause() { paused = true }
    public func resume() { paused = false }

    /// Stops every file still waiting or running; finished ones stay as they are.
    public func cancelAll() {
        paused = false
        for row in rows where row.isRunning { row.cancel?() }
    }

    /// Holds a waiting file while the batch is paused.
    func waitWhilePaused() async {
        while paused, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
