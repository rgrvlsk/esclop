// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Settings window's sidebar: seven panes, and in each the panels it lists. A panel is a
// feature: its switch turns it on or off and its chevron opens its settings
// (docs/design/targets/README.md, `pr7-settings`). Every registry setting sits in exactly one
// panel, by key; the registry's own sections stay as they are for the CLI and agents.

import EsclopCore
import Foundation

public enum SettingsPane: String, CaseIterable, Identifiable, Hashable, Sendable {
    case general, automatic, compression, results, uploads, agents, advanced

    public var id: String { rawValue }

    /// The pane's name in the app's language.
    public var title: String {
        switch self {
        case .general: return Strings.text("General")
        case .automatic: return Strings.text("Automatic")
        case .compression: return Strings.text("Compression")
        case .results: return Strings.text("Results")
        case .uploads: return Strings.text("Uploads")
        case .agents: return Strings.text("Agents")
        case .advanced: return Strings.text("Advanced")
        }
    }

    /// One line under the pane's heading.
    public var subtitle: String {
        switch self {
        case .general: return Strings.text("What every file gets, and where it goes")
        case .automatic: return Strings.text("What L’Esclop does on its own")
        case .compression: return Strings.text("How hard each kind of file is squeezed")
        case .results: return Strings.text("What you see after a file is done")
        case .uploads: return Strings.text("Where files go when you share them")
        case .agents: return Strings.text("What AI agents may do with L’Esclop")
        case .advanced: return Strings.text("Updates, backups and maintenance")
        }
    }

    /// The English name, which the search also matches.
    public var englishTitle: String { Self.english[self] ?? rawValue }

    static let english: [SettingsPane: String] = [
        .general: "General", .automatic: "Automatic", .compression: "Compression", .results: "Results",
        .uploads: "Uploads", .agents: "Agents", .advanced: "Advanced",
    ]

    public var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .automatic: return "arrow.triangle.2.circlepath"
        case .compression: return "square.stack.3d.down.right"
        case .results: return "rectangle.stack"
        case .uploads: return "icloud.and.arrow.up"
        case .agents: return "sparkles"
        case .advanced: return "slider.horizontal.3"
        }
    }

    /// The panels this pane lists, in order.
    public var panels: [SettingsPanel] {
        typealias S = EsclopSettings
        switch self {
        case .general:
            return [
                SettingsPanel("general.menuBar", Strings.text("Menu bar"), keys: [S.showMenubarIcon.key, S.showInScreenshots.key]),
                SettingsPanel("general.everyFile", Strings.text("Every file"), keys: [S.stripMetadata.key, S.preserveDates.key, S.keepHDR.key]),
                SettingsPanel("general.keys", Strings.text("Keyboard shortcuts"), keys: [S.cardKeysUnderPointer.key]),
                SettingsPanel(
                    "general.output", Strings.text("Where results go"), symbol: "folder", collapsible: true,
                    keys: [
                        S.optimisedImageBehaviour.key, S.optimisedVideoBehaviour.key, S.optimisedPDFBehaviour.key, S.optimisedAudioBehaviour.key,
                        S.convertedImageBehaviour.key, S.convertedVideoBehaviour.key, S.convertedAudioBehaviour.key,
                    ]
                ),
            ]
        case .automatic:
            return [
                SettingsPanel("automatic.pause", nil, keys: [S.pauseAutomaticOptimisations.key]),
                SettingsPanel(
                    "automatic.clipboard", Strings.text("Clipboard"), symbol: "clipboard", collapsible: true,
                    keys: [
                        S.enableClipboardOptimiser.key, S.optimiseVideoClipboard.key, S.optimisePDFClipboard.key, S.optimiseAudioClipboard.key,
                        S.optimiseImagePathClipboard.key, S.optimiseURLClipboard.key, S.autoCopyToClipboard.key, S.appendClipboardResults.key,
                        S.clipboardIgnoredAppBundleIds.key, S.clipboardRules.key,
                    ]
                ),
                SettingsPanel(
                    "automatic.images", Strings.text("Images in folders"), symbol: "photo", switchKey: S.enableAutomaticImageOptimisations.key,
                    keys: [S.imageDirs.key, S.watchedFolderRules.key, S.maxImageSizeMB.key, S.minImageSizeKB.key, S.maxImageFileCount.key]
                ),
                SettingsPanel(
                    "automatic.video", Strings.text("Videos in folders"), symbol: "video", switchKey: S.enableAutomaticVideoOptimisations.key,
                    keys: [S.videoDirs.key, S.maxVideoSizeMB.key, S.minVideoSizeKB.key, S.maxVideoFileCount.key]
                ),
                SettingsPanel(
                    "automatic.pdf", Strings.text("PDFs in folders"), symbol: "doc.richtext", switchKey: S.enableAutomaticPDFOptimisations.key,
                    keys: [S.pdfDirs.key, S.maxPDFSizeMB.key, S.maxPDFFileCount.key]
                ),
                SettingsPanel(
                    "automatic.audio", Strings.text("Audio in folders"), symbol: "waveform", switchKey: S.enableAutomaticAudioOptimisations.key,
                    keys: [S.audioDirs.key, S.maxAudioSizeMB.key, S.maxAudioFileCount.key]
                ),
            ]
        case .compression:
            return [
                SettingsPanel("compression.normally", Strings.text("Normally"), keys: [S.imageCompression.key, S.videoCompression.key, S.audioCompression.key]),
                SettingsPanel(
                    "compression.aggressive", Strings.text("When aggressive"),
                    keys: [
                        S.imageAggressiveCompression.key, S.videoAggressiveCompression.key, S.audioAggressiveCompression.key,
                        S.useAggressiveOptimisationJPEG.key, S.useAggressiveOptimisationPNG.key, S.useAggressiveOptimisationGIF.key,
                        S.useAggressiveOptimisationMP4.key, S.useAggressiveOptimisationPDF.key,
                    ]
                ),
                SettingsPanel(
                    "compression.images", Strings.text("Images"), symbol: "photo", collapsible: true,
                    keys: [S.formatsToConvertToJPEG.key, S.formatsToConvertToPNG.key, S.adaptiveImageSize.key, S.downscaleRetinaImages.key, S.downscaleFactor.key, S.cropSizes.key]
                ),
                SettingsPanel(
                    "compression.video", Strings.text("Video"), symbol: "video", collapsible: true,
                    keys: [
                        S.formatsToConvertToMP4.key, S.videoEncoder.key, S.capVideoFPS.key, S.targetVideoFPS.key, S.minVideoFPS.key,
                        S.playbackSpeedFrames.key, S.removeAudioFromVideos.key, S.convertAudioToAAC.key, S.gifMaxWidth.key, S.gifFPS.key,
                    ]
                ),
                SettingsPanel("compression.pdf", Strings.text("PDF"), symbol: "doc.richtext", collapsible: true, keys: [S.pdfDPI.key]),
                SettingsPanel(
                    "compression.audio", Strings.text("Audio"), symbol: "waveform", collapsible: true,
                    keys: [S.formatsToConvertToAAC.key, S.formatsToConvertToMP3.key, S.normalizeLoudness.key, S.loudnessTarget.key, S.audioCoverArt.key]
                ),
            ]
        case .results:
            return [
                SettingsPanel(
                    "results.floating", Strings.text("Floating results"), symbol: "rectangle.stack", switchKey: S.showFloatingResults.key,
                    keys: [
                        S.floatingResultsCorner.key, S.followCursorScreen.key, S.autoHideFloatingResults.key, S.autoHideFloatingResultsAfter.key,
                        S.autoHideClipboardResultAfter.key, S.batchWindowFrom.key,
                    ]
                ),
                SettingsPanel(
                    "results.dropZone", Strings.text("Drop zone"), symbol: "tray.and.arrow.down", switchKey: S.enableDragAndDrop.key,
                    keys: [S.dropZoneOnlyWithOption.key, S.presetZones.key, S.copyDroppedResults.key]
                ),
            ]
        case .uploads:
            return [SettingsPanel("uploads.targets", nil, keys: [S.uploadTargets.key, S.uploadTarget.key, S.uploadAutomatically.key])]
        case .agents:
            return [SettingsPanel(
                "agents.permissions", Strings.text("What agents may do without asking"),
                keys: [S.allowOverwriteOriginals.key, S.allowDeleteBackups.key, S.allowRunScripts.key, S.allowSettingsChanges.key, S.allowUploads.key]
            )]
        case .advanced:
            return [
                SettingsPanel("advanced.updates", Strings.text("Updates"), keys: [S.checkForUpdatesAutomatically.key, S.installUpdatesAutomatically.key]),
                SettingsPanel("advanced.backups", Strings.text("Backups"), keys: [S.backupRetentionDays.key]),
                SettingsPanel("advanced.paths", Strings.text("File names and folders"), keys: [S.sameFolderNameTemplate.key, S.specificFolderTemplate.key]),
            ]
        }
    }

    /// The pane and panel that show a registry setting. Every key has exactly one.
    public static func place(of key: String) -> (pane: SettingsPane, panel: SettingsPanel)? {
        for pane in allCases {
            if let panel = pane.panels.first(where: { $0.switchKey == key || $0.keys.contains(key) }) { return (pane, panel) }
        }
        return nil
    }

    /// A pane by its id ("compression"), its title, an id it had before 0.2 ("images",
    /// "floatingResults") or the name of a registry section ("interface", "output"), in any
    /// case, ignoring spaces and dashes. Old links keep working.
    public static func named(_ raw: String) -> SettingsPane? {
        let wanted = normalized(raw)
        guard !wanted.isEmpty else { return nil }
        if let pane = allCases.first(where: { normalized($0.rawValue) == wanted || normalized($0.title) == wanted || normalized($0.englishTitle) == wanted }) {
            return pane
        }
        return aliases[wanted]
    }

    /// The panes before 0.2, registry sections and other words people type.
    static let aliases: [String: SettingsPane] = [
        "mcp": .agents, "agent": .agents, "agentsandmcp": .agents,
        "floating": .results, "floatingresults": .results, "interface": .results, "dropzone": .results,
        "images": .compression, "image": .compression, "video": .compression, "videos": .compression,
        "pdf": .compression, "audio": .compression, "quality": .compression,
        "clipboard": .automatic, "automation": .automatic, "folders": .automatic,
        "output": .general, "menubar": .general,
        "updates": .advanced, "backups": .advanced,
    ]

    static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The note under a panel, when it needs one.
    public func footer(for panel: SettingsPanel) -> String? {
        switch panel.id {
        case "agents.permissions":
            return Strings.text("The MCP server checks every request from an agent against these switches, and the app checks it again. They start off. They bind agents that use MCP only: anything running as you, an agent with a shell too, can use the esclop command line, which acts for you without these limits.")
        default:
            return nil
        }
    }
}

/// One feature in a pane: a heading, an optional switch that turns it on or off, and its
/// settings, shown under the heading or, when it is collapsible, when it is opened.
public struct SettingsPanel: Identifiable, Hashable, Sendable {
    public let id: String
    /// Nil for a group with no heading (the pause line, the upload targets).
    public let title: String?
    public let symbol: String?
    /// The switch in the panel's heading: on turns the feature on. Not among `keys`.
    public let switchKey: String?
    public let keys: [String]
    /// A panel with a switch always opens and closes; one without does when this is set.
    let opensAndCloses: Bool

    init(_ id: String, _ title: String?, symbol: String? = nil, switchKey: String? = nil, collapsible: Bool = false, keys: [String]) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.switchKey = switchKey
        self.keys = keys
        opensAndCloses = collapsible
    }

    /// True when the panel shows its settings only once it is opened.
    public var collapsible: Bool { opensAndCloses || switchKey != nil }

    /// Every registry key the panel shows, its switch first.
    public var allKeys: [String] { (switchKey.map { [$0] } ?? []) + keys }
}
