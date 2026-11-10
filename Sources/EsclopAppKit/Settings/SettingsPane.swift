// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Settings window's sidebar. Each pane shows one or more sections of the settings registry,
// so a new registry setting appears in its pane without touching the window.

import EsclopCore
import Foundation

public enum SettingsPane: String, CaseIterable, Identifiable, Hashable, Sendable {
    case general, images, video, pdf, audio, clipboard, floatingResults, agents, advanced

    public var id: String { rawValue }

    /// The pane's name in the app's language.
    public var title: String {
        switch self {
        case .general: return Strings.text("General")
        case .images: return Strings.text("Images")
        case .video: return Strings.text("Video")
        case .pdf: return Strings.text("PDF")
        case .audio: return Strings.text("Audio")
        case .clipboard: return Strings.text("Clipboard")
        case .floatingResults: return Strings.text("Floating results")
        case .agents: return Strings.text("Agents and MCP")
        case .advanced: return Strings.text("Advanced")
        }
    }

    /// The English name, which the search also matches.
    public var englishTitle: String { Self.english[self] ?? rawValue }

    static let english: [SettingsPane: String] = [
        .general: "General", .images: "Images", .video: "Video", .pdf: "PDF", .audio: "Audio", .clipboard: "Clipboard",
        .floatingResults: "Floating results", .agents: "Agents and MCP", .advanced: "Advanced",
    ]

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
        case .general: return [.general, .output, .backups, .updates]
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

    /// The note under a registry section, when it needs one.
    public func footer(for section: SettingsSection) -> String? {
        switch section {
        case .agents:
            return Strings.text("The MCP server checks every request from an agent against these switches, and the app checks it again. They start off, and agents cannot turn them on. The esclop command line acts for you and is not limited by them.")
        default:
            return nil
        }
    }

    /// The heading a registry section gets inside its pane; nil when the pane has only that one.
    public func heading(for section: SettingsSection) -> String? {
        switch section {
        case .general: return Strings.text("Every file")
        case .output: return Strings.text("Where results go")
        case .backups: return Strings.text("Backups")
        case .updates: return Strings.text("Updates")
        case .automation: return Strings.text("Automatic optimisation")
        case .agents: return Strings.text("What agents may do without asking")
        case .interface: return sections.count > 1 ? Strings.text("Interface") : nil
        case .images: return sections.count > 1 ? Strings.text("Images") : nil
        case .video: return sections.count > 1 ? Strings.text("Video") : nil
        case .pdf: return sections.count > 1 ? Strings.text("PDF") : nil
        case .audio: return sections.count > 1 ? Strings.text("Audio") : nil
        case .clipboard: return sections.count > 1 ? Strings.text("Clipboard") : nil

        }
    }
}
