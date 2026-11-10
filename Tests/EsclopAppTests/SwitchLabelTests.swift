// SPDX-License-Identifier: GPL-3.0-or-later
//
// Every switch is named by its title. A toggle whose label is a title and a line under it
// reaches accessibility as that line; such toggles must be a `TitledToggle` or carry
// `.switchLabel(title:hint:)`. This walks the app's sources, so a new switch cannot slip by.

@testable import EsclopAppKit
import Foundation
import Testing

@Suite struct SwitchLabelTests {
    struct Switch: CustomStringConvertible {
        var file: String
        var line: Int
        var label: String
        var description: String { "\(file):\(line) \(label)" }
    }

    /// Every toggle in the app and the name it declares.
    static func switches() throws -> [Switch] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/EsclopAppKit")
        var found: [Switch] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for file in files where file.pathExtension == "swift" && file.lastPathComponent != "TitledToggle.swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                if let range = code.range(of: "TitledToggle(") {
                    // The title is the first argument, on this line or the next.
                    let call = ([String(code[range.upperBound...])] + lines.dropFirst(index + 1).prefix(2)).joined(separator: " ")
                    found.append(Switch(file: file.lastPathComponent, line: index + 1, label: Self.argument("title", in: call) ?? ""))
                } else if code.contains("Toggle(isOn:") {
                    // A toggle with a view label: its name must be declared within the next lines.
                    let following = lines.dropFirst(index).prefix(6).joined(separator: " ")
                    found.append(Switch(file: file.lastPathComponent, line: index + 1, label: Self.argument("switchLabel(title", in: following) ?? ""))
                } else if let range = code.range(of: "Toggle(") {
                    // `Toggle(title, isOn:)`: the title is the name.
                    let rest = code[range.upperBound...]
                    found.append(Switch(file: file.lastPathComponent, line: index + 1, label: String(rest.prefix { $0 != "," })))
                }
            }
        }
        return found
    }

    static func argument(_ name: String, in text: String) -> String? {
        guard let range = text.range(of: name + ":") else { return nil }
        let rest = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        var depth = 0
        var out = ""
        for character in rest {
            if character == "(" { depth += 1 }
            if character == ")" { if depth == 0 { break }; depth -= 1 }
            if character == ",", depth == 0 { break }
            out.append(character)
        }
        return out.isEmpty ? nil : out
    }

    @Test func everySwitchIsNamedByItsTitle() throws {
        let switches = try Self.switches()
        #expect(switches.count >= 11, "the walk found the app's switches: \(switches)")
        let unnamed = switches.filter { $0.label.isEmpty }
        #expect(unnamed.isEmpty, "switches without a declared name: \(unnamed)")
        // The two the live check heard read their explanation: now their titles.
        #expect(switches.contains { $0.file == "PipelineFilterSection.swift" && $0.label.contains("\"Only some files\"") })
        #expect(switches.contains { $0.file == "SettingRow.swift" && $0.label == "descriptor.title" })
        // No name is a subtitle.
        let subtitles = ["Files that do not match are left alone.", "descriptor.summary", "Nothing appears on screen"]
        #expect(!switches.contains { label in subtitles.contains { label.label.contains($0) } })
    }
}
