// SPDX-License-Identifier: GPL-3.0-or-later
//
// Lets a fixed number of files be optimised at once, first come first served. The engines start
// processes and use every core on their own; a few files in parallel keep the machine usable.

import Foundation

public actor WorkGate {
    public let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)) {
        self.limit = max(1, limit)
    }

    public func acquire() async {
        if running < limit {
            running += 1
            return
        }
        // The slot is handed over by `release`, so `running` does not change here.
        await withCheckedContinuation { waiting.append($0) }
    }

    public func release() {
        if waiting.isEmpty {
            running = max(0, running - 1)
        } else {
            waiting.removeFirst().resume()
        }
    }

    public var inUse: Int { running }
    public var queued: Int { waiting.count }
}
