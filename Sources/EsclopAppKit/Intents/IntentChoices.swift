// SPDX-License-Identifier: GPL-3.0-or-later
//
// The typed choices the Shortcuts actions offer: the formats L'Esclop writes (the options
// popover's list), the saved pipelines, and the settings of the registry.

import AppIntents
import EsclopCore
import EsclopPipelines
import Foundation

/// A format to convert to.
public enum ConvertFormat: String, AppEnum, CaseIterable, Sendable {
    case webp, avif, heic, jpeg, png, gif, mp4, hevc, av1, webm, mov, aac, mp3, opus, flac

    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Format"
    public static let caseDisplayRepresentations: [ConvertFormat: DisplayRepresentation] = [
        .webp: "WebP", .avif: "AVIF", .heic: "HEIC", .jpeg: "JPEG", .png: "PNG", .gif: "GIF",
        .mp4: "MP4", .hevc: "HEVC", .av1: "AV1", .webm: "WebM", .mov: "MOV",
        .aac: "AAC", .mp3: "MP3", .opus: "Opus", .flac: "FLAC",
    ]

    var output: OutputFormat {
        switch self {
        case .webp: .webp
        case .avif: .avif
        case .heic: .heic
        case .jpeg: .jpeg
        case .png: .png
        case .gif: .gif
        case .mp4: .mp4
        case .hevc: .hevc
        case .av1: .av1
        case .webm: .webm
        case .mov: .mov
        case .aac: .aac
        case .mp3: .mp3
        case .opus: .opus
        case .flac: .flac
        }
    }
}

/// A saved pipeline.
public struct PipelineChoice: AppEntity, Sendable {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Pipeline"
    public static let defaultQuery = PipelineQuery()

    public var id: String
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }

    public init(id: String) {
        self.id = id
    }
}

public struct PipelineQuery: EntityQuery, Sendable {
    public init() {}

    @MainActor
    static var names: [String] {
        ((try? ShortcutActions.model?.service.context.pipelines.list()) ?? []).map(\.name)
    }

    public func entities(for identifiers: [String]) async throws -> [PipelineChoice] {
        let names = await Self.names
        return identifiers.filter(names.contains).map(PipelineChoice.init)
    }

    public func suggestedEntities() async throws -> [PipelineChoice] {
        await Self.names.map(PipelineChoice.init)
    }
}

/// A setting of the registry, shown by its title in the app's language.
public struct SettingChoice: AppEntity, Sendable {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Setting"
    public static let defaultQuery = SettingQuery()

    public var id: String
    public var title: String
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)", subtitle: "\(id)") }

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct SettingQuery: EntityQuery, Sendable {
    public init() {}

    static var all: [SettingChoice] {
        SettingsRegistry.shared.all.map { SettingChoice(id: $0.key, title: SettingWords.lookup(SettingWords.titleKey($0.key), english: $0.title)) }
    }

    public func entities(for identifiers: [String]) async throws -> [SettingChoice] {
        Self.all.filter { identifiers.contains($0.id) }
    }

    public func suggestedEntities() async throws -> [SettingChoice] {
        Self.all
    }
}
