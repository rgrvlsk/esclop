// SPDX-License-Identifier: GPL-3.0-or-later
//
// A planned edit of one agent's config file: the text before and after, where it goes and where
// the previous version is kept. The app shows it as a diff before writing; `AgentInstaller.apply`
// writes exactly `after`, or nothing when the file changed in between.

import Foundation

public struct ConfigChange: Sendable, Equatable {
    public enum Action: String, Sendable {
        case install, uninstall
    }

    public var agentID: String
    public var agentName: String
    public var action: Action
    /// The file written: the config path with symlinks resolved.
    public var file: URL
    /// The config path as people know it: `~/.claude.json`.
    public var shownPath: String
    public var fileExists: Bool
    public var before: String
    public var after: String
    public var command: ServerCommand?
    /// Where the previous version is kept; nil when there is no file yet.
    public var backup: URL?
    /// The backup's path as `~/Library/...`.
    public var shownBackup: String?

    public var changesNothing: Bool { before == after }

    /// The changed lines with `context` unchanged lines around them. Installer edits are one
    /// splice, so the common start and end of the two texts bound the change exactly, in linear
    /// time even for a config of many megabytes (Claude Code's `~/.claude.json` can be).
    public func diff(context: Int = 3) -> [DiffLine] {
        let old = Self.lines(before)
        let new = Self.lines(after)
        var start = 0
        while start < old.count, start < new.count, old[start] == new[start] { start += 1 }
        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > start, newEnd > start, old[oldEnd - 1] == new[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        guard start < oldEnd || start < newEnd else { return [] }
        var out: [DiffLine] = []
        let lead = max(0, start - context)
        if lead > 0 { out.append(DiffLine(kind: .skipped, text: "", number: nil, skipped: lead)) }
        for index in lead ..< start { out.append(DiffLine(kind: .same, text: old[index], number: index + 1)) }
        for index in start ..< oldEnd { out.append(DiffLine(kind: .removed, text: old[index], number: index + 1)) }
        for index in start ..< newEnd { out.append(DiffLine(kind: .added, text: new[index], number: index + 1)) }
        let tail = min(new.count, newEnd + context)
        for index in newEnd ..< tail { out.append(DiffLine(kind: .same, text: new[index], number: index + 1)) }
        if tail < new.count { out.append(DiffLine(kind: .skipped, text: "", number: nil, skipped: new.count - tail)) }
        return out
    }

    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}

public struct DiffLine: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable {
        case same, added, removed
        /// Unchanged lines left out of the preview.
        case skipped
    }

    public var kind: Kind
    public var text: String
    /// The line's number in the file it comes from (the old file for removed lines).
    public var number: Int?
    public var skipped: Int = 0
}
