// SPDX-License-Identifier: GPL-3.0-or-later
//
// Edits JSON and JSONC (comments, trailing commas) by splicing text, so everything outside the
// entry being changed (comments, key order, formatting) stays byte for byte.

import EsclopCore
import EsclopIPC
import Foundation

/// JSON text that keeps object keys in the order given, for entries written into agent configs.
indirect enum OrderedJSON: Equatable {
    case string(String)
    case bool(Bool)
    case array([OrderedJSON])
    case object([(String, OrderedJSON)])

    static func == (lhs: OrderedJSON, rhs: OrderedJSON) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)): return a == b
        case let (.bool(a), .bool(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)): return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    var json: JSONValue {
        switch self {
        case let .string(s): return .string(s)
        case let .bool(b): return .bool(b)
        case let .array(a): return .array(a.map(\.json))
        case let .object(o): return .object(Dictionary(o.map { ($0.0, $0.1.json) }, uniquingKeysWith: { $1 }))
        }
    }

    /// Pretty text. Lines after the first start with `indent`; nesting adds `unit`.
    func render(indent: String, unit: String) -> String {
        switch self {
        case let .string(s): return JSONText.quote(s)
        case let .bool(b): return b ? "true" : "false"
        case let .array(items):
            if items.allSatisfy({ if case .string = $0 { return true }; if case .bool = $0 { return true }; return false }) {
                return "[" + items.map { $0.render(indent: indent, unit: unit) }.joined(separator: ", ") + "]"
            }
            let inner = indent + unit
            return "[\n" + items.map { inner + $0.render(indent: inner, unit: unit) }.joined(separator: ",\n") + "\n\(indent)]"
        case let .object(members):
            if members.isEmpty { return "{}" }
            let inner = indent + unit
            return "{\n" + members.map { "\(inner)\(JSONText.quote($0.0)): \($0.1.render(indent: inner, unit: unit))" }.joined(separator: ",\n") + "\n\(indent)}"
        }
    }
}

enum JSONText {
    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

struct ConfigLayoutError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A parsed JSONC document that remembers where every value sits in the text.
struct JSONCDocument {
    private(set) var text: [UInt8]

    init(_ string: String) {
        text = Array(string.utf8)
    }

    var string: String { String(decoding: text, as: UTF8.self) }

    // MARK: Parse tree

    struct Node {
        enum Kind {
            case object([Member])
            case array([Node])
            case scalar
        }

        var start: Int
        var end: Int
        var kind: Kind
    }

    struct Member {
        var key: String
        var start: Int
        var value: Node
        /// Index of the comma after the value, if any.
        var comma: Int?
    }

    /// nil for an empty document (only whitespace and comments).
    func parse() throws -> Node? {
        var parser = Parser(bytes: text)
        parser.skipTrivia()
        if parser.atEnd { return nil }
        let node = try parser.value()
        parser.skipTrivia()
        guard parser.atEnd else { throw ConfigLayoutError("Unexpected text after the JSON value at byte \(parser.index)") }
        return node
    }

    func value(at path: [String]) throws -> JSONValue? {
        guard var node = try parse() else { return nil }
        for key in path {
            guard case let .object(members) = node.kind, let member = members.last(where: { $0.key == key }) else { return nil }
            node = member.value
        }
        return try decode(node)
    }

    func decode(_ node: Node) throws -> JSONValue {
        switch node.kind {
        case let .object(members):
            var out: [String: JSONValue] = [:]
            for member in members { out[member.key] = try decode(member.value) }
            return .object(out)
        case let .array(items):
            return .array(try items.map(decode))
        case .scalar:
            let slice = Data(text[node.start ..< node.end])
            return try JSONDecoder().decode(JSONValue.self, from: slice)
        }
    }

    // MARK: Edits

    /// Sets the value at `path` (creating objects on the way), leaving the rest of the text alone.
    mutating func set(_ path: [String], to value: OrderedJSON) throws {
        precondition(!path.isEmpty)
        let unit = indentUnit()
        guard let root = try parse() else {
            let nested = path.reversed().reduce(value) { inner, key in .object([(key, inner)]) }
            text = Array((nested.render(indent: "", unit: unit) + "\n").utf8)
            return
        }
        var node = root
        for (depth, key) in path.enumerated() {
            guard case let .object(members) = node.kind else {
                throw ConfigLayoutError("\(path.prefix(depth).joined(separator: ".")) is not an object")
            }
            let remaining = Array(path[(depth + 1)...])
            if let member = members.last(where: { $0.key == key }) {
                if remaining.isEmpty {
                    let indent = lineIndent(at: member.start)
                    replace(member.value.start ..< member.value.end, with: value.render(indent: indent, unit: unit))
                    return
                }
                node = member.value
                continue
            }
            let nested = remaining.reversed().reduce(value) { inner, key in .object([(key, inner)]) }
            insert(member: key, value: nested, into: node, members: members, unit: unit)
            return
        }
    }

    /// Removes the member at `path`. Returns false when it was not there.
    @discardableResult
    mutating func remove(_ path: [String]) throws -> Bool {
        guard var node = try parse() else { return false }
        var parentMembers: [Member] = []
        var target: Member?
        for key in path {
            guard case let .object(members) = node.kind, let member = members.last(where: { $0.key == key }) else { return false }
            parentMembers = members
            target = member
            node = member.value
        }
        guard let target, let index = parentMembers.lastIndex(where: { $0.start == target.start }) else { return false }
        // The member's own text, with its indentation when it starts its line.
        var start = target.start
        while start > 0, text[start - 1] == 0x20 || text[start - 1] == 0x09 { start -= 1 }
        let ownLine = start == 0 || text[start - 1] == 0x0A
        if !ownLine { start = target.start }
        var end = target.comma.map { $0 + 1 } ?? target.value.end
        var probe = end
        while probe < text.count, text[probe] == 0x20 || text[probe] == 0x09 || text[probe] == 0x0D { probe += 1 }
        if ownLine, probe < text.count, text[probe] == 0x0A { end = probe + 1 }
        text.replaceSubrange(start ..< end, with: [])
        // The last member leaves the previous one's comma behind; remove just that character, so a
        // comment after it stays where it was.
        if target.comma == nil, index > 0, let previousComma = parentMembers[index - 1].comma {
            text.remove(at: previousComma)
        }
        return true
    }

    private mutating func insert(member key: String, value: OrderedJSON, into object: Node, members: [Member], unit: String) {
        let parentIndent = lineIndent(at: object.start)
        let indent = parentIndent + unit
        let rendered = "\(JSONText.quote(key)): \(value.render(indent: indent, unit: unit))"
        if let last = members.last {
            if let comma = last.comma {
                // A trailing comma already separates: add ours after it, keeping one too.
                replace(comma + 1 ..< comma + 1, with: "\n\(indent)\(rendered),")
            } else {
                replace(last.value.end ..< last.value.end, with: ",\n\(indent)\(rendered)")
            }
        } else {
            let inner = (object.start + 1) ..< (object.end - 1)
            let onlyWhitespace = text[inner].allSatisfy { [0x20, 0x09, 0x0A, 0x0D].contains($0) }
            if onlyWhitespace {
                replace(inner, with: "\n\(indent)\(rendered)\n\(parentIndent)")
            } else {
                replace(object.start + 1 ..< object.start + 1, with: "\n\(indent)\(rendered)")
            }
        }
    }

    private mutating func replace(_ range: Range<Int>, with string: String) {
        text.replaceSubrange(range, with: Array(string.utf8))
    }

    /// The whitespace at the start of the line holding `index`.
    private func lineIndent(at index: Int) -> String {
        var start = index
        while start > 0, text[start - 1] != 0x0A { start -= 1 }
        var end = start
        while end < text.count, text[end] == 0x20 || text[end] == 0x09 { end += 1 }
        return String(decoding: text[start ..< end], as: UTF8.self)
    }

    /// The file's own indentation step: the first indented line's leading whitespace, or two spaces.
    private func indentUnit() -> String {
        var index = 0
        while index < text.count {
            if text[index] == 0x0A, index + 1 < text.count, text[index + 1] == 0x20 || text[index + 1] == 0x09 {
                var end = index + 1
                while end < text.count, text[end] == text[index + 1] { end += 1 }
                if end < text.count, text[end] != 0x0A { return String(decoding: text[(index + 1) ..< end], as: UTF8.self) }
            }
            index += 1
        }
        return "  "
    }

    // MARK: Parser

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        var atEnd: Bool { index >= bytes.count }

        mutating func skipTrivia() {
            while index < bytes.count {
                let b = bytes[index]
                if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0xEF || b == 0xBB || b == 0xBF {
                    index += 1
                } else if b == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2F {
                    while index < bytes.count, bytes[index] != 0x0A { index += 1 }
                } else if b == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2A {
                    index += 2
                    while index + 1 < bytes.count, !(bytes[index] == 0x2A && bytes[index + 1] == 0x2F) { index += 1 }
                    index = min(bytes.count, index + 2)
                } else {
                    return
                }
            }
        }

        mutating func value() throws -> Node {
            skipTrivia()
            guard !atEnd else { throw ConfigLayoutError("Unexpected end of JSON") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""):
                let start = index
                try skipString()
                return Node(start: start, end: index, kind: .scalar)
            default:
                let start = index
                while index < bytes.count, !",}] \t\r\n/".utf8.contains(bytes[index]) { index += 1 }
                guard index > start else { throw ConfigLayoutError("Unexpected character at byte \(start)") }
                return Node(start: start, end: index, kind: .scalar)
            }
        }

        mutating func skipString() throws {
            index += 1
            while index < bytes.count {
                if bytes[index] == UInt8(ascii: "\\") { index += 2; continue }
                if bytes[index] == UInt8(ascii: "\"") { index += 1; return }
                index += 1
            }
            throw ConfigLayoutError("Unterminated string")
        }

        mutating func object() throws -> Node {
            let start = index
            index += 1
            var members: [Member] = []
            while true {
                skipTrivia()
                guard !atEnd else { throw ConfigLayoutError("Unclosed object starting at byte \(start)") }
                if bytes[index] == UInt8(ascii: "}") { index += 1; break }
                guard bytes[index] == UInt8(ascii: "\"") else { throw ConfigLayoutError("Expected a key at byte \(index)") }
                let keyStart = index
                try skipString()
                let key = try JSONDecoder().decode(String.self, from: Data(bytes[keyStart ..< index]))
                skipTrivia()
                guard !atEnd, bytes[index] == UInt8(ascii: ":") else { throw ConfigLayoutError("Expected : after \(key)") }
                index += 1
                let value = try value()
                skipTrivia()
                var comma: Int?
                if !atEnd, bytes[index] == UInt8(ascii: ",") { comma = index; index += 1 }
                members.append(Member(key: key, start: keyStart, value: value, comma: comma))
                if comma == nil {
                    skipTrivia()
                    guard !atEnd, bytes[index] == UInt8(ascii: "}") else { throw ConfigLayoutError("Expected , or } after \(key)") }
                }
            }
            return Node(start: start, end: index, kind: .object(members))
        }

        mutating func array() throws -> Node {
            let start = index
            index += 1
            var items: [Node] = []
            while true {
                skipTrivia()
                guard !atEnd else { throw ConfigLayoutError("Unclosed array starting at byte \(start)") }
                if bytes[index] == UInt8(ascii: "]") { index += 1; break }
                items.append(try value())
                skipTrivia()
                if !atEnd, bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                skipTrivia()
                guard !atEnd, bytes[index] == UInt8(ascii: "]") else { throw ConfigLayoutError("Expected , or ] in array") }
            }
            return Node(start: start, end: index, kind: .array(items))
        }
    }
}
