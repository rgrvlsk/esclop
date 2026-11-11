// SPDX-License-Identifier: GPL-3.0-or-later
//
// A named pipeline: what triggers it and which steps run for each kind of file.

import EsclopCore
import Foundation

/// What makes a pipeline run on its own.
public enum PipelineTrigger: Hashable, Codable, Sendable, CustomStringConvertible {
    /// Files and images copied to the clipboard.
    case clipboard
    /// Files dropped on the drop zone.
    case dropZone
    /// Shown as a preset zone beside the drop zone while dragging.
    case presetZone
    /// New files in a watched folder. The path may start with `~`.
    case folder(String)
    /// Listed in Finder's right-click menu.
    case rightClick
    /// Offered as a quick action by the command line.
    case cli
    /// Offered to AI agents by the MCP server.
    case mcp

    public static let simpleNames = ["clipboard", "dropZone", "presetZone", "rightClick", "cli", "mcp"]
    public static let allNames = simpleNames + ["folder"]

    public var name: String {
        switch self {
        case .clipboard: "clipboard"
        case .dropZone: "dropZone"
        case .presetZone: "presetZone"
        case .folder: "folder"
        case .rightClick: "rightClick"
        case .cli: "cli"
        case .mcp: "mcp"
        }
    }

    /// As written in a `.pipeline` file: `clipboard`, `folder("~/Downloads")`.
    public var description: String {
        if case let .folder(path) = self { return "folder(\(PipelineSerializer.quote(path)))" }
        return name
    }

    public init?(name: String, argument: String? = nil) {
        switch name {
        case "clipboard": self = .clipboard
        case "dropZone": self = .dropZone
        case "presetZone": self = .presetZone
        case "rightClick": self = .rightClick
        case "cli": self = .cli
        case "mcp": self = .mcp
        case "folder":
            guard let argument, !argument.isEmpty else { return nil }
            self = .folder(argument)
        default: return nil
        }
    }
}

/// The steps for one kind of file, or for every kind when `kind` is nil.
public struct PipelineSection: Hashable, Codable, Sendable {
    public var kind: MediaKind?
    public var steps: [PipelineStep]

    public init(kind: MediaKind? = nil, steps: [PipelineStep]) {
        self.kind = kind
        self.steps = steps
    }
}

public struct Pipeline: Hashable, Codable, Sendable, Identifiable {
    /// Also the file name in the store (`<name>.pipeline`).
    public var name: String
    public var description: String?
    /// A global shortcut such as `ctrl+alt+cmd+w`. The app registers it; the format is the app's.
    public var hotkey: String?
    /// SF Symbol shown for the pipeline in preset zones and menus.
    public var icon: String?
    public var triggers: [PipelineTrigger]
    /// Optimise the file before the steps run (Clop's saved-pipeline default). Skipped when the
    /// first real step re-encodes anyway (convert, crop, downscale).
    public var optimiseFirst: Bool
    /// Run without showing the floating result.
    public var hideResult: Bool
    /// In file order. At most one section per kind; a nil kind is the "any file" section.
    public var sections: [PipelineSection]

    public var id: String { name }

    public init(
        name: String, description: String? = nil, hotkey: String? = nil, icon: String? = nil,
        triggers: [PipelineTrigger] = [], optimiseFirst: Bool = false, hideResult: Bool = false,
        sections: [PipelineSection] = []
    ) {
        self.name = name
        self.description = description
        self.hotkey = hotkey
        self.icon = icon
        self.triggers = triggers
        self.optimiseFirst = optimiseFirst
        self.hideResult = hideResult
        self.sections = sections
    }

    /// A pipeline with one list of steps for every kind of file, like an inline Clop pipeline.
    public init(name: String = "inline", steps: [PipelineStep]) {
        self.init(name: name, sections: [PipelineSection(steps: steps)])
    }

    /// Steps written for `kind` (nil: the "any file" section). Setting an empty list removes the section.
    public subscript(kind: MediaKind?) -> [PipelineStep] {
        get { sections.first { $0.kind == kind }?.steps ?? [] }
        set {
            if let i = sections.firstIndex(where: { $0.kind == kind }) {
                if newValue.isEmpty { sections.remove(at: i) } else { sections[i].steps = newValue }
            } else if !newValue.isEmpty {
                sections.append(PipelineSection(kind: kind, steps: newValue))
            }
        }
    }

    /// The steps that run for a file of this kind: its own section when there is one, otherwise
    /// the "any file" section.
    public func steps(for kind: MediaKind) -> [PipelineStep] {
        let own = self[kind]
        return own.isEmpty ? self[nil] : own
    }

    /// Kinds this pipeline does something for.
    public var kinds: Set<MediaKind> {
        Set(MediaKind.allCases.filter { kind in steps(for: kind).contains { $0.kinds.contains(kind) } })
    }

    public var isEmpty: Bool { sections.allSatisfy(\.steps.isEmpty) }

    /// The pipeline as `.pipeline` file text.
    public var text: String { PipelineSerializer.serialize(self) }

    /// True when the first non-filter step re-encodes the file, so an implicit optimise would be wasted.
    public func leadsWithReencode(for kind: MediaKind) -> Bool {
        guard let first = steps(for: kind).first(where: { !$0.isFilter }) else { return false }
        switch first {
        case .convert, .crop, .downscale: return true
        default: return false
        }
    }
}
