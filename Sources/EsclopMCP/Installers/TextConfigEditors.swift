// SPDX-License-Identifier: GPL-3.0-or-later
//
// Line-based editors for the TOML (Codex) and YAML (Goose) agent configs. They replace or remove
// one table / one mapping entry and leave every other line as it was. A layout they cannot follow
// safely (the entry written inline, flow style) is refused with a message instead of guessed at.

import EsclopCore
import Foundation

// MARK: - Lines

struct ConfigLines {
    var lines: [String]
    let endsWithNewline: Bool
    /// `\r\n` when the file uses it, so a Windows-edited file keeps its line endings.
    let newline: String

    init(_ text: String) {
        newline = text.contains("\r\n") ? "\r\n" : "\n"
        var parts = text.components(separatedBy: "\n")
        endsWithNewline = text.isEmpty || text.hasSuffix("\n")
        if text.hasSuffix("\n") || text.isEmpty, parts.last == "" { parts.removeLast() }
        lines = parts.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    var text: String {
        lines.isEmpty ? "" : lines.joined(separator: newline) + (endsWithNewline ? newline : "")
    }

    /// Shrinks `range` so trailing blank and comment lines stay with whatever follows.
    func trimmed(_ range: Range<Int>) -> Range<Int> {
        var end = range.upperBound
        while end > range.lowerBound + 1, Self.isBlankOrComment(lines[end - 1]) { end -= 1 }
        return range.lowerBound ..< end
    }

    static func indent(of line: String) -> Int { line.prefix { $0 == " " || $0 == "\t" }.count }
    static func isBlankOrComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }

    /// Replaces `range`, keeping the blank lines that ended it (they separate it from what follows).
    mutating func replaceBlock(_ range: Range<Int>, with body: [String]) {
        var end = range.upperBound
        while end > range.lowerBound + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        lines.replaceSubrange(range.lowerBound ..< end, with: body)
    }

    mutating func removeBlock(_ range: Range<Int>) {
        var start = range.lowerBound
        var end = range.upperBound
        // Take one separating blank line with it.
        if start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty { start -= 1 }
        else if end < lines.count, lines[end].trimmingCharacters(in: .whitespaces).isEmpty { end += 1 }
        lines.removeSubrange(start ..< end)
    }

    mutating func append(_ body: [String]) {
        if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
        lines.append(contentsOf: body)
    }
}

// MARK: - TOML

/// One `[a.b]` table in a TOML file, sub-tables included.
struct TOMLTableEditor {
    var file: ConfigLines
    let table: [String]

    init(_ text: String, table: [String]) {
        file = ConfigLines(text)
        self.table = table
    }

    var text: String { file.text }

    /// The keys of a `[table]` header, or nil when the line is not one. `[[...]]` returns its keys too.
    static func header(_ line: String) -> [String]? {
        var body = Substring(line.trimmingCharacters(in: .whitespaces))
        guard body.hasPrefix("[") else { return nil }
        body = body.hasPrefix("[[") ? body.dropFirst(2) : body.dropFirst()
        var keys: [String] = []
        var current = ""
        var quote: Character?
        for char in body {
            if let q = quote {
                if char == q { quote = nil } else { current.append(char) }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == "." {
                keys.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else if char == "]" {
                keys.append(current.trimmingCharacters(in: .whitespaces))
                return keys
            } else {
                current.append(char)
            }
        }
        return nil
    }

    /// Lines of the table and its sub-tables.
    func block() throws -> Range<Int>? {
        try checkLayout()
        guard let start = file.lines.firstIndex(where: { Self.header($0) == table }) else { return nil }
        var end = start + 1
        while end < file.lines.count {
            if let keys = Self.header(file.lines[end]), !(keys.count > table.count && Array(keys.prefix(table.count)) == table) { break }
            end += 1
        }
        return file.trimmed(start ..< end)
    }

    /// The table's own lines, without its sub-tables.
    func ownBlock() throws -> Range<Int>? {
        guard let block = try block() else { return nil }
        let end = (block.lowerBound + 1 ..< block.upperBound).first { Self.header(file.lines[$0]) != nil } ?? block.upperBound
        return file.trimmed(block.lowerBound ..< end)
    }

    /// Refuses files that define the entry somewhere this editor would not see it.
    func checkLayout() throws {
        let parent = Array(table.dropLast())
        let inline = ConfigLayoutError("\(table.joined(separator: ".")) is written inline. Move it to a [\(table.joined(separator: "."))] table or remove it, then install again")
        var current: [String] = []
        for line in file.lines {
            if let keys = Self.header(line) { current = keys; continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let dotted = trimmed[..<eq].split(separator: ".").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
            let path = current + dotted
            guard !current.starts(with: table) else { continue }
            if path.starts(with: table) { throw inline }
            if path == parent {
                throw ConfigLayoutError("\(parent.joined(separator: ".")) is an inline table, which TOML does not let esclop add a [\(table.joined(separator: "."))] table to. Rewrite it as [\(parent.joined(separator: "."))...] tables, then install again")
            }
        }
    }

    mutating func set(_ entries: [(String, String)]) throws {
        let body = ["[\(table.joined(separator: "."))]"] + entries.map { "\($0.0) = \($0.1)" }
        // Sub-tables the person added (env, per-tool settings) stay.
        if let range = try ownBlock() {
            file.lines.replaceSubrange(range, with: body)
        } else {
            file.append(body)
        }
    }

    @discardableResult
    mutating func remove() throws -> Bool {
        guard let range = try block() else { return false }
        file.removeBlock(range)
        return true
    }

    /// `key = value` pairs of the table itself (not its sub-tables), values as raw TOML text.
    func entries() throws -> [String: String]? {
        guard let range = try block() else { return nil }
        var out: [String: String] = [:]
        var index = range.lowerBound + 1
        while index < range.upperBound {
            let line = file.lines[index]
            if Self.header(line) != nil { break }
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            var value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            // Multi-line arrays: gather until the brackets balance.
            while value.filter({ $0 == "[" }).count > value.filter({ $0 == "]" }).count, index < range.upperBound {
                value += " " + file.lines[index].trimmingCharacters(in: .whitespaces)
                index += 1
            }
            out[key] = value
        }
        return out
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case let c where c.value < 0x20: out += String(format: "\\u%04X", c.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// The strings in a TOML string or array-of-strings value. Comments after the value are ignored.
    static func strings(_ raw: String) -> [String] {
        var out: [String] = []
        var index = raw.startIndex
        while index < raw.endIndex {
            let char = raw[index]
            if char == "#" { break }
            if char == "\"" || char == "'" {
                let literal = char == "'"
                var value = ""
                index = raw.index(after: index)
                while index < raw.endIndex, raw[index] != char {
                    if !literal, raw[index] == "\\", raw.index(after: index) < raw.endIndex {
                        index = raw.index(after: index)
                        switch raw[index] {
                        case "n": value.append("\n")
                        case "t": value.append("\t")
                        case "u", "U":
                            let count = raw[index] == "u" ? 4 : 8
                            let hexStart = raw.index(after: index)
                            let hexEnd = raw.index(hexStart, offsetBy: count, limitedBy: raw.endIndex) ?? raw.endIndex
                            if let code = UInt32(raw[hexStart ..< hexEnd], radix: 16), let scalar = Unicode.Scalar(code) {
                                value.unicodeScalars.append(scalar)
                            }
                            index = raw.index(before: hexEnd)
                        default: value.append(raw[index])
                        }
                    } else {
                        value.append(raw[index])
                    }
                    index = raw.index(after: index)
                }
                out.append(value)
            }
            if index < raw.endIndex { index = raw.index(after: index) }
        }
        return out
    }
}

// MARK: - YAML

/// One child of a top-level mapping in a block-style YAML file, e.g. `extensions:` → `esclop:`.
struct YAMLMappingEditor {
    var file: ConfigLines
    let parent: String
    let child: String

    init(_ text: String, parent: String, child: String) {
        file = ConfigLines(text)
        self.parent = parent
        self.child = child
    }

    var text: String { file.text }

    static func key(of line: String) -> (key: String, rest: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("-") else { return nil }
        var key = ""
        var rest = ""
        if let first = trimmed.first, first == "\"" || first == "'" {
            guard let close = trimmed.dropFirst().firstIndex(of: first) else { return nil }
            key = String(trimmed[trimmed.index(after: trimmed.startIndex) ..< close])
            let after = trimmed[trimmed.index(after: close)...]
            guard after.hasPrefix(":") else { return nil }
            rest = String(after.dropFirst())
        } else {
            guard let colon = trimmed.range(of: ":") else { return nil }
            let tail = trimmed[colon.upperBound...]
            guard tail.isEmpty || tail.hasPrefix(" ") || tail.hasPrefix("\t") else { return nil }
            key = String(trimmed[..<colon.lowerBound])
            rest = String(tail)
        }
        let value = rest.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return (key.trimmingCharacters(in: .whitespaces), value.trimmingCharacters(in: .whitespaces))
    }

    /// Index of the parent line and the end of its block.
    func parentBlock() throws -> (line: Int, end: Int)? {
        guard let line = file.lines.firstIndex(where: { ConfigLines.indent(of: $0) == 0 && Self.key(of: $0)?.key == parent }) else { return nil }
        let rest = Self.key(of: file.lines[line])?.rest ?? ""
        guard rest.isEmpty || rest == "{}" || rest == "null" || rest == "~" else {
            throw ConfigLayoutError("\(parent) is written in flow style (\(rest.prefix(30))). Rewrite it as an indented block, then install again")
        }
        var end = line + 1
        while end < file.lines.count {
            let candidate = file.lines[end]
            if !ConfigLines.isBlankOrComment(candidate), ConfigLines.indent(of: candidate) == 0 { break }
            end += 1
        }
        return (line, end)
    }

    func childIndent(in block: (line: Int, end: Int)) -> Int {
        for index in (block.line + 1) ..< block.end where !ConfigLines.isBlankOrComment(file.lines[index]) {
            return ConfigLines.indent(of: file.lines[index])
        }
        return 2
    }

    func childBlock() throws -> Range<Int>? {
        guard let block = try parentBlock() else { return nil }
        let indent = childIndent(in: block)
        guard let start = ((block.line + 1) ..< block.end).first(where: {
            ConfigLines.indent(of: file.lines[$0]) == indent && Self.key(of: file.lines[$0])?.key == child
        }) else { return nil }
        if let rest = Self.key(of: file.lines[start])?.rest, !rest.isEmpty {
            throw ConfigLayoutError("\(parent).\(child) is written in flow style; rewrite it as an indented block or remove it")
        }
        var end = start + 1
        while end < block.end {
            let line = file.lines[end]
            if !ConfigLines.isBlankOrComment(line), ConfigLines.indent(of: line) <= indent { break }
            end += 1
        }
        return file.trimmed(start ..< end)
    }

    /// `body` lines are relative to the child's own indentation; nested lines start with `  `.
    mutating func set(_ body: [String]) throws {
        if let range = try childBlock(), let block = try parentBlock() {
            file.replaceBlock(range, with: indented(body, by: childIndent(in: block)))
        } else if let block = try parentBlock() {
            if Self.key(of: file.lines[block.line])?.rest.isEmpty == false { file.lines[block.line] = "\(parent):" }
            var insertAt = block.end
            // Before trailing blank lines and top-level comments: those belong to what follows.
            while insertAt > block.line + 1 {
                let line = file.lines[insertAt - 1]
                let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
                guard blank || (ConfigLines.isBlankOrComment(line) && ConfigLines.indent(of: line) == 0) else { break }
                insertAt -= 1
            }
            file.lines.insert(contentsOf: indented(body, by: childIndent(in: block)), at: insertAt)
        } else {
            file.append(["\(parent):"] + indented(body, by: 2))
        }
    }

    @discardableResult
    mutating func remove() throws -> Bool {
        guard let range = try childBlock() else { return false }
        var end = range.upperBound
        while end > range.lowerBound + 1, file.lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        file.lines.removeSubrange(range.lowerBound ..< end)
        return true
    }

    /// Scalars and string lists directly under the child.
    func entries() throws -> [String: [String]]? {
        guard let range = try childBlock() else { return nil }
        var out: [String: [String]] = [:]
        var lastKey: String?
        let base = ConfigLines.indent(of: file.lines[range.lowerBound])
        for index in (range.lowerBound + 1) ..< range.upperBound {
            let line = file.lines[index]
            guard !ConfigLines.isBlankOrComment(line), ConfigLines.indent(of: line) > base else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- "), let key = lastKey {
                out[key, default: []].append(Self.scalar(String(trimmed.dropFirst(2))))
            } else if let (key, rest) = Self.key(of: line) {
                lastKey = key
                if rest.hasPrefix("["), rest.hasSuffix("]") {
                    out[key] = rest.dropFirst().dropLast().split(separator: ",").map { Self.scalar(String($0)) }
                } else {
                    out[key] = rest.isEmpty ? [] : [Self.scalar(rest)]
                }
            }
        }
        return out
    }

    private func indented(_ body: [String], by indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        return body.map { pad + $0.replacingOccurrences(of: "  ", with: pad, options: .anchored) }
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func scalar(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            return String(trimmed.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        if trimmed.count >= 2, trimmed.hasPrefix("'"), trimmed.hasSuffix("'") {
            return String(trimmed.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return trimmed
    }
}
