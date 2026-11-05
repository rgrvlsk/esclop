// SPDX-License-Identifier: GPL-3.0-or-later
//
// Helpers on EsclopCore's `JSONValue` for the CLI, the MCP server and the wire protocol, and the
// encoders they share.

import EsclopCore
import Foundation

extension JSONValue {
    /// The form a person types: `true`, `42`, `webp` (strings unquoted). Arrays and objects as JSON.
    public var plain: String {
        switch self {
        case .null: return "null"
        case let .bool(v): return v ? "true" : "false"
        case let .int(v): return String(v)
        case let .double(v): return v.rounded() == v && abs(v) < 1e15 ? String(Int(v)) : String(v)
        case let .string(v): return v
        case .array, .object: return jsonString()
        }
    }

    /// Encodes any value with the presentation encoder (ISO 8601 dates, sorted keys).
    public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONCoding.presentationEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: jsonData())
    }
}

/// Encoders and decoders shared by the wire protocol and the human/agent-facing output.
public enum JSONCoding {
    /// Exact round-trips over IPC: dates as reference-date seconds, nothing lost.
    public static func wireEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func wireDecoder() -> JSONDecoder { JSONDecoder() }

    /// What people and agents read: ISO 8601 dates, sorted keys, unescaped slashes.
    public static func presentationEncoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty
            ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
            : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func presentationString<T: Encodable>(_ value: T, pretty: Bool = true) -> String {
        guard let data = try? presentationEncoder(pretty: pretty).encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}
