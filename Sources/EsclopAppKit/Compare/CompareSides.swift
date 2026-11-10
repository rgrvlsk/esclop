// SPDX-License-Identifier: GPL-3.0-or-later
//
// Which two files a comparison shows. The optimised file is the result's output; the original
// is its backup (for results written over the original) or the original itself when the result
// went next to it. Both outlive the floating result, so the comparison opens from the menu or a
// link long after. When the original is no longer kept, the window says so instead of guessing.

import EsclopCore
import Foundation

public enum CompareSides: Equatable, Sendable {
    /// Both files are there.
    case ready(before: URL, after: URL)
    /// The result was undone: the original is back and the optimised version is gone.
    case restored
    /// The original is no longer kept (the backup was pruned, or none was made); the optimised
    /// file is still there.
    case pruned(after: URL)
    /// The optimised file is gone (moved or deleted).
    case gone

    public static func resolve(
        _ result: OptimisationResult, restored: Bool, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> CompareSides {
        if restored { return .restored }
        let after = result.output
        guard exists(after) else { return .gone }
        if let backup = result.backup, exists(backup) { return .ready(before: backup, after: after) }
        let source = result.source.standardizedFileURL
        if source != after.standardizedFileURL, exists(source) { return .ready(before: source, after: after) }
        return .pruned(after: after)
    }

    public var before: URL? { if case let .ready(before, _) = self { return before } else { return nil } }

    public var after: URL? {
        switch self {
        case let .ready(_, after), let .pruned(after): return after
        case .restored, .gone: return nil
        }
    }
}
