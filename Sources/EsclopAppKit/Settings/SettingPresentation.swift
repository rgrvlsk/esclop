// SPDX-License-Identifier: GPL-3.0-or-later
//
// How a registry setting looks in the Settings window: which control, the words for each allowed
// value, the unit after a number, and which switch it depends on. Plain values, so tests check
// them and the views only draw them. Anything not listed here gets a control from its type.

import EsclopCore
import EsclopIPC
import Foundation

public enum SettingControl: Equatable, Sendable {
    case toggle
    /// A menu of allowed values, each with its words.
    case picker([Choice])
    /// 0 to 100 and similar: a slider with the figure beside it.
    case slider(range: ClosedRange<Double>, step: Double, format: SliderFormat)
    /// A number typed in a field, with a stepper and a unit.
    case number(unit: String?, step: Double)
    case text
    /// A list of file extensions, typed comma separated.
    case extensions
    /// Folders, added with an open panel.
    case folders
    /// Apps, added with an open panel and stored as bundle identifiers.
    case apps
    /// The rules made with "Always apply" in the options popover, each with a delete button.
    case clipboardRules
    /// The preset zones: a switch for each pipeline that can be one, and its place in the order.
    case presetZones
    /// The upload targets, with Add, Edit and Remove; their keys go to the Keychain.
    case uploadTargets
    /// The default upload target, from the targets.
    case uploadTarget
    /// A switch for each source that can upload on its own.
    case uploadSources

    public struct Choice: Equatable, Hashable, Sendable {
        public var value: JSONValue
        public var label: String
    }

    public enum SliderFormat: Equatable, Sendable {
        case plain
        /// 0.5 reads 50 %.
        case percent
    }
}

public enum SettingPresentation {
    public static func control(for descriptor: SettingDescriptor) -> SettingControl {
        let key = descriptor.key
        if let choices = numberChoices[key] {
            return .picker(choices.map { SettingControl.Choice(value: .int($0.0), label: Strings.text($0.1)) })
        }
        if key == EsclopSettings.targetVideoFPS.key {
            var choices: [(Double, String)] = [(-4, Strings.text("A quarter of the source")), (-2, Strings.text("Half the source")), (24, "24 fps"), (30, "30 fps"), (60, "60 fps"), (120, "120 fps")]
            if let current = descriptor.value?.doubleValue, !choices.contains(where: { $0.0 == current }) {
                choices.append((current, "\(Self.number(current)) fps"))
            }
            return .picker(choices.map { SettingControl.Choice(value: .double($0.0), label: $0.1) })
        }
        if key == EsclopSettings.downscaleFactor.key {
            return .slider(range: 0.1 ... 1, step: 0.05, format: .percent)
        }
        if key.hasSuffix("Compression"), descriptor.minimum == 0, descriptor.maximum == 100 {
            return .slider(range: 0 ... 100, step: 1, format: .plain)
        }
        if key.hasSuffix("Dirs") { return .folders }
        if key == EsclopSettings.clipboardIgnoredAppBundleIds.key { return .apps }
        if key == EsclopSettings.clipboardRules.key { return .clipboardRules }
        if key == EsclopSettings.presetZones.key { return .presetZones }
        if key == EsclopSettings.uploadTargets.key { return .uploadTargets }
        if key == EsclopSettings.uploadTarget.key { return .uploadTarget }
        if key == EsclopSettings.uploadAutomatically.key { return .uploadSources }
        if key.hasPrefix("formatsToConvert") { return .extensions }
        switch descriptor.type {
        case .bool: return .toggle
        case .choice:
            return .picker((descriptor.choices ?? []).map { SettingControl.Choice(value: .string($0), label: label(for: $0, key: key)) })
        case .int, .double: return .number(unit: units[key].map { Strings.text($0) }, step: descriptor.type == .int ? 1 : 0.5)
        case .string: return .text
        }
    }

    // MARK: Words

    static let numberChoices: [String: [(Int, String)]] = [
        EsclopSettings.pdfDPI.key: [(0, "Automatic"), (300, "300 DPI, full resolution"), (250, "250 DPI"), (200, "200 DPI"), (150, "150 DPI"), (100, "100 DPI"), (72, "72 DPI"), (48, "48 DPI")],
    ]

    static let units: [String: String] = [
        "autoHideFloatingResultsAfter": "s", "autoHideClipboardResultAfter": "s",
        "maxImageSizeMB": "MB", "minImageSizeKB": "kB", "maxVideoSizeMB": "MB", "minVideoSizeKB": "kB",
        "maxPDFSizeMB": "MB", "maxAudioSizeMB": "MB", "minVideoFPS": "fps", "gifMaxWidth": "px", "gifFPS": "fps",
        "loudnessTarget": "LUFS", "backupRetentionDays": "days",
    ]

    static let choiceLabels: [String: String] = [
        // FileBehaviour
        "inPlace": "Replace the original", "sameFolder": "Next to the original",
        "specificFolder": "In a specific folder", "temporary": "In a temporary folder",
        // ScreenCorner
        "bottomRight": "Bottom right", "bottomLeft": "Bottom left", "topRight": "Top right", "topLeft": "Top left",
        // PlaybackSpeedFrames
        "keepFrames": "Keep every frame", "dropFrames": "Keep the frame rate",
        // AudioCoverArt
        "optimise": "Optimise it", "remove": "Remove it", "keep": "Keep it as it is",
        // VideoEncoder
        "libx264": "H.264, software", "h264_videotoolbox": "H.264, VideoToolbox", "hevc_videotoolbox": "HEVC, VideoToolbox",
        "libx265": "HEVC, software", "libsvtav1": "AV1, SVT", "libvpx-vp9": "VP9",
    ]

    /// The words for an allowed value: "bottomRight" reads "Bottom right".
    public static func label(for raw: String, key: String = "") -> String {
        if let known = choiceLabels[raw] { return Strings.text(known) }
        var out = ""
        for character in raw {
            if character.isUppercase { out += " " + character.lowercased() } else { out.append(character) }
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }

    /// A value as a person reads it in a field or a tooltip.
    public static func text(for value: JSONValue?) -> String {
        switch value {
        case let .string(text): return text
        case let .array(items): return items.compactMap(\.stringValue).joined(separator: ", ")
        case let .double(number): return Self.number(number)
        case let .int(number): return String(number)
        case let .bool(flag): return flag ? Strings.text("on") : Strings.text("off")
        case let .some(other): return "\(other)"
        case nil: return ""
        }
    }

    /// A value in the words the control shows: "Bottom right", "50 %", "on".
    public static func display(_ value: JSONValue?, for descriptor: SettingDescriptor) -> String {
        switch control(for: descriptor) {
        case let .picker(choices):
            return choices.first { $0.value.doubleValue == value?.doubleValue && $0.value.stringValue == value?.stringValue }?.label ?? text(for: value)
        case .slider(_, _, .percent):
            return "\(Int(((value?.doubleValue ?? 0) * 100).rounded())) %"
        case let .number(unit, _):
            return [text(for: value), unit].compactMap { $0 }.joined(separator: " ")
        case .folders, .apps, .extensions:
            let items = value?.arrayValue ?? []
            return items.isEmpty ? Strings.text("none") : text(for: value)
        case .clipboardRules:
            let rules = ClipboardRuleList.decode(value)
            return rules.isEmpty ? Strings.text("none") : rules.map { $0.subject() }.joined(separator: ", ")
        case .presetZones:
            let names = (value?.arrayValue ?? []).compactMap(\.stringValue)
            return names.isEmpty ? Strings.text("none") : names.joined(separator: ", ")
        case .uploadTargets:
            let targets = UploadTarget.decode((value?.arrayValue ?? []).compactMap(\.stringValue))
            return targets.isEmpty ? Strings.text("none") : targets.map(\.name).joined(separator: ", ")
        case .uploadTarget:
            let name = value?.stringValue ?? ""
            return name.isEmpty ? Strings.text("The first in the list") : name
        case .uploadSources:
            let names = (value?.arrayValue ?? []).compactMap(\.stringValue)
            return names.isEmpty ? Strings.text("none") : names.compactMap { RequestOrigin(rawValue: $0) }.map(UploadSourceSwitches.title).joined(separator: ", ")

        default:
            return text(for: value)
        }
    }

    static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    // MARK: Dependencies

    /// The switch that has to be on for a setting to matter: the row is dimmed while it is off.
    public static let dependsOn: [String: String] = [
        "autoHideFloatingResultsAfter": "autoHideFloatingResults",
        "autoHideClipboardResultAfter": "autoHideFloatingResults",
        "targetVideoFPS": "capVideoFPS",
        "minVideoFPS": "capVideoFPS",
        "loudnessTarget": "normalizeLoudness",
        "imageDirs": "enableAutomaticImageOptimisations",
        "videoDirs": "enableAutomaticVideoOptimisations",
        "pdfDirs": "enableAutomaticPDFOptimisations",
        "audioDirs": "enableAutomaticAudioOptimisations",
        "installUpdatesAutomatically": "checkForUpdatesAutomatically",
    ]

    /// False when the setting has no effect with the current values.
    public static func isEnabled(_ key: String, values: [String: JSONValue]) -> Bool {
        if let parent = dependsOn[key] {
            return values[parent]?.boolValue ?? true
        }
        if key == EsclopSettings.specificFolderTemplate.key {
            return values.contains { $0.key.hasSuffix("Behaviour") && $0.value.stringValue == FileBehaviour.specificFolder.rawValue }
        }
        if key == EsclopSettings.sameFolderNameTemplate.key {
            return values.contains { $0.key.hasSuffix("Behaviour") && $0.value.stringValue == FileBehaviour.sameFolder.rawValue }
        }
        return true
    }
}
