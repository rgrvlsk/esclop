// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Settings window's sidebar. Each pane shows one or more sections of the settings registry,
// so a new registry setting appears in its pane without touching the window.

import EsclopCore
import Foundation

public enum SettingsPane: String, CaseIterable, Identifiable, Hashable, Sendable {
    case general, images, video, pdf, audio, clipboard, floatingResults, agents, advanced

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: return "General"
        case .images: return "Images"
        case .video: return "Video"
        case .pdf: return "PDF"
        case .audio: return "Audio"
        case .clipboard: return "Clipboard"
        case .floatingResults: return "Floating results"
        case .agents: return "Agents and MCP"
        case .advanced: return "Advanced"
        }
    }

    public var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .images: return "photo"
        case .video: return "video"
        case .pdf: return "doc.richtext"
        case .audio: return "waveform"
        case .clipboard: return "doc.on.clipboard"
        case .floatingResults: return "rectangle.stack"
        case .agents: return "sparkles"
        case .advanced: return "slider.horizontal.3"
        }
    }

    /// The registry sections this pane lists, in order.
    public var sections: [SettingsSection] {
        switch self {
        case .general: return [.general, .output, .backups]
        case .images: return [.images]
        case .video: return [.video]
        case .pdf: return [.pdf]
        case .audio: return [.audio]
        case .clipboard: return [.clipboard]
        case .floatingResults: return [.interface]
        case .agents: return [.agents]
        case .advanced: return [.automation]
        }
    }

    /// The pane that lists a registry section. Every section has exactly one.
    public static func pane(for section: SettingsSection) -> SettingsPane {
        allCases.first { $0.sections.contains(section) } ?? .advanced
    }

    /// A pane by its id ("floatingResults"), its title ("Floating results") or the name of a
    /// registry section it shows ("interface", "output"), in any case, ignoring spaces and dashes.
    public static func named(_ raw: String) -> SettingsPane? {
        let wanted = normalized(raw)
        guard !wanted.isEmpty else { return nil }
        if let pane = allCases.first(where: { normalized($0.rawValue) == wanted || normalized($0.title) == wanted }) {
            return pane
        }
        let aliases: [String: SettingsPane] = ["mcp": .agents, "agent": .agents, "floating": .floatingResults, "results": .floatingResults, "image": .images, "videos": .video]
        if let pane = aliases[wanted] { return pane }
        return SettingsSection.allCases.first { normalized($0.rawValue) == wanted }.map(pane(for:))
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The heading a registry section gets inside its pane; nil when the pane has only that one.
    public func heading(for section: SettingsSection) -> String? {
        switch section {
        case .general: return "Every file"
        case .output: return "Where results go"
        case .backups: return "Backups"
        case .automation: return "Automatic optimisation"
        case .agents: return "What agents may do without asking"
        default: return sections.count > 1 ? section.title : nil
        }
    }
}
