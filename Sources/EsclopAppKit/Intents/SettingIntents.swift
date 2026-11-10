// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shortcuts actions for L'Esclop's settings and its pause: read a setting, change one (checked
// by the registry exactly as the Settings window and `esclop settings set` check it), and pause
// or resume automatic optimisation.

import AppIntents
import Foundation

public struct GetSettingIntent: AppIntent {
    public static let title: LocalizedStringResource = "Get a Setting"
    public static let description = IntentDescription("Read one of L’Esclop’s settings.")
    public static let openAppWhenRun = false

    @Parameter(title: "Setting")
    public var setting: SettingChoice

    public static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$setting)")
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await ShortcutActions.value(of: setting.id))
    }
}

public struct SetSettingIntent: AppIntent {
    public static let title: LocalizedStringResource = "Change a Setting"
    public static let description = IntentDescription("Change one of L’Esclop’s settings. The value is checked as the Settings window checks it.")
    public static let openAppWhenRun = false

    @Parameter(title: "Setting")
    public var setting: SettingChoice

    @Parameter(title: "Value")
    public var value: String

    public static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$setting) to \(\.$value)")
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await ShortcutActions.set(setting.id, to: value))
    }
}

public struct PauseIntent: AppIntent {
    public static let title: LocalizedStringResource = "Pause or Resume"
    public static let description = IntentDescription("Pause automatic optimisation of copied files and watched folders, or resume it.")
    public static let openAppWhenRun = false

    @Parameter(title: "Paused", default: true)
    public var paused: Bool

    public static var parameterSummary: some ParameterSummary {
        When(\.$paused, .equalTo, true) {
            Summary("Pause automatic optimisation") { \.$paused }
        } otherwise: {
            Summary("Resume automatic optimisation") { \.$paused }
        }
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        .result(value: try await ShortcutActions.setPaused(paused))
    }
}
