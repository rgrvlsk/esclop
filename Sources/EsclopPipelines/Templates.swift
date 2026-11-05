// SPDX-License-Identifier: GPL-3.0-or-later
//
// Path templates: `%f`-style tokens, `$1` regex captures and `~`. The token set and meanings
// match Clop's so templates written for Clop land files in the same places.

import Foundation

public struct TemplateContext: Sendable {
    /// The file the tokens describe: the file the pipeline started with.
    public var file: URL
    /// Capture groups of the last `if(regex:)` that matched.
    public var captures: [String]
    /// The moment date and time tokens show.
    public var date: Date
    /// Value of `%i`.
    public var counter: Int
    public var calendar: Calendar

    public init(file: URL, captures: [String] = [], date: Date = Date(), counter: Int = 1, calendar: Calendar = .current) {
        self.file = file
        self.captures = captures
        self.date = date
        self.counter = counter
        self.calendar = calendar
    }

    /// Replaces tokens in one pass (so a file name containing `%y` is never expanded twice),
    /// then `$1`, `$2`... and finally a leading `~` or `$HOME`.
    public func resolve(_ template: String) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second], from: date)
        let stem = file.deletingPathExtension().lastPathComponent
        func two(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }

        var out = ""
        var chars = Array(template)[...]
        while let ch = chars.first {
            chars = chars.dropFirst()
            if ch == "%", let token = chars.first {
                let value: String? = switch token {
                case "f": stem
                case "e": file.pathExtension
                case "P": file.deletingLastPathComponent().path
                case "F": file.path
                case "y": String(format: "%04d", c.year ?? 0)
                case "m": two(c.month)
                case "n": calendar.monthSymbols[max(0, (c.month ?? 1) - 1)]
                case "d": two(c.day)
                case "w": String(c.weekday ?? 0)
                case "H": two(c.hour)
                case "M": two(c.minute)
                case "S": two(c.second)
                case "p": (c.hour ?? 0) >= 12 ? "PM" : "AM"
                case "r": String((0 ..< 5).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement()! })
                case "i": String(counter)
                default: nil
                }
                if let value {
                    out += value
                    chars = chars.dropFirst()
                    continue
                }
            }
            if ch == "$", let digit = chars.first, let n = digit.wholeNumberValue, n >= 1 {
                // `$12` is the twelfth capture when there are that many, else `$1` followed by "2".
                var number = n
                var used = 1
                if let next = chars.dropFirst().first?.wholeNumberValue, number * 10 + next <= captures.count {
                    number = number * 10 + next
                    used = 2
                }
                if number <= captures.count {
                    out += captures[number - 1]
                    chars = chars.dropFirst(used)
                    continue
                }
            }
            out.append(ch)
        }
        return Self.expandHome(out)
    }

    /// `~`, `~/x`, `$HOME/x` and `${HOME}/x` to absolute paths.
    public static func expandHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst() }
        for prefix in ["${HOME}", "$HOME"] where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            if rest.isEmpty || rest.hasPrefix("/") { return home + rest }
        }
        return path
    }
}
