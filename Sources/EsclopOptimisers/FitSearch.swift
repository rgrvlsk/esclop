// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Fit under size" when the encoder cannot search by itself. Quality first, size second:
//   1. the normal compression; done if it fits;
//   2. the strongest compression; if that fits, binary search for the gentlest one that does;
//   3. otherwise keep a strong compression and binary search the scale, starting from the
//      estimate sqrt(target / size) because bytes grow roughly with pixel count.
// Each attempt is a full encode, so the search stops when steps get small (about ten encodes).

import EsclopCore
import Foundation

enum FitSearch {
    struct Outcome {
        var produced: Produced
        var factor: Int
        var scale: Double
    }

    static func run(
        target: Int, baseFactor: Int, maxFactor: Int = 100, minScale: Double = 0.05,
        progress: ProgressSink, encode: (_ factor: Int, _ scale: Double) async throws -> Produced
    ) async throws -> Outcome {
        guard target > 0 else { throw EsclopError.invalidArgument("The target size must be above zero") }
        var best: Outcome?
        var smallest = Int.max
        var attempts = 0

        /// Encodes once; returns the size, or nil when the encoder could not go below the source.
        func attempt(_ factor: Int, _ scale: Double) async throws -> Int? {
            try Task.checkCancellation()
            attempts += 1
            progress(min(0.95, Double(attempts) / 12), "Trying compression \(factor), scale \(String(format: "%.2f", scale))")
            let produced: Produced
            do {
                produced = try await encode(factor, scale)
            } catch EsclopError.alreadySmaller {
                return nil
            }
            let size = fileSize(produced.url)
            smallest = min(smallest, size)
            if size <= target {
                let candidate = Outcome(produced: produced, factor: factor, scale: scale)
                if let current = best {
                    if scale > current.scale + 0.0001 || (abs(scale - current.scale) < 0.0001 && factor < current.factor) {
                        best = candidate
                    }
                } else {
                    best = candidate
                }
            }
            return size
        }

        let base = clamp(baseFactor, 0, maxFactor)
        if let size = try await attempt(base, 1), size <= target, let best { return best }

        if base < maxFactor, let size = try await attempt(maxFactor, 1), size <= target {
            var low = base
            var high = maxFactor
            while high - low > 4 {
                let mid = (low + high) / 2
                if let size = try await attempt(mid, 1), size <= target { high = mid } else { low = mid }
            }
            if let best { return best }
        }

        let factor = max(base, min(maxFactor, 70))
        let full = try await attempt(factor, 1) ?? Int.max
        var low = minScale
        var high = 1.0
        var next = full == Int.max ? 0.5 : clamp(sqrt(Double(target) / Double(full)) * 0.95, minScale, 0.95)
        for _ in 0 ..< 7 {
            if let size = try await attempt(factor, next), size <= target { low = next } else { high = next }
            if high - low < 0.02 { break }
            next = (low + high) / 2
        }
        if best == nil, low == minScale {
            _ = try await attempt(factor, minScale)
        }
        guard let best else {
            let smallestText = smallest == Int.max ? "nothing smaller than the original" : ByteFormat.string(smallest)
            throw EsclopError.other("Could not fit under \(ByteFormat.string(target)); the smallest attempt was \(smallestText)")
        }
        return best
    }
}
