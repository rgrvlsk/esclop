// SPDX-License-Identifier: GPL-3.0-or-later
//
// What L'Esclop's Shortcuts actions do, apart from App Intents so tests drive it directly. The
// files go through the running app's usual jobs (floating results included) with the
// `shortcuts` origin, and the results come back as files so actions chain. When Shortcuts
// starts the app to run an action, the action waits for it to finish starting.

import EsclopCore
import EsclopIPC
import Foundation

@MainActor
public enum ShortcutActions {
    /// The running app's model; set when the app starts.
    public static var model: AppModel?

    public enum Operation: Equatable, Sendable {
        case optimise(harder: Bool)
        case convert(OutputFormat)
        case downscale(Double)
        case crop(CropSize)
        case pipeline(String)
    }

    /// A failure Shortcuts shows as the action's error.
    public struct Failure: Error, Equatable, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// The model, once the app has started (Shortcuts may start it for this action).
    static func ready(timeout: Duration = .seconds(20)) async throws -> AppModel {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if let model { return model }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure(message: Strings.text("L’Esclop did not finish starting. Try the action again."))
    }

    /// Runs `operation` on each file and returns the results' files, in order. Files L'Esclop
    /// does not handle are refused up front; a file that fails fails the action, with its reason.
    public static func run(_ operation: Operation, on files: [URL]) async throws -> [URL] {
        let model = try await ready()
        guard !files.isEmpty else { throw Failure(message: Strings.text("No files were given to the action.")) }
        let unsupported = files.filter { MediaKind.of($0) == nil }
        guard unsupported.isEmpty else {
            throw Failure(message: Strings.format("L’Esclop cannot optimise this kind of file (%@).", unsupported.map(\.lastPathComponent).joined(separator: ", ")))
        }
        if case let .downscale(factor) = operation, !(factor > 0 && factor <= 1) {
            throw Failure(message: Strings.text("The factor is above 0 and at most 1: 0.5 is half the width and height."))
        }
        var outputs: [URL] = []
        for file in files {
            var job = model.factory.job(for: file, origin: .shortcuts, aggressive: operation == .optimise(harder: true))
            switch operation {
            case .optimise: break
            case let .convert(format): job.request.format = format
            case let .downscale(factor): job.request.downscale = factor < 1 ? factor : nil
            case let .crop(size): job.request.crop = size
            case let .pipeline(name): job.operation = .pipeline(name)
            }
            let report = await model.run(job)
            if let result = report.results.first {
                outputs.append(result.output)
            } else if let failure = report.failures.first {
                if case .alreadySmaller = failure.error {
                    // Already optimised: the file goes on unchanged, as the floating result says.
                    outputs.append(file)
                } else {
                    throw Failure(message: CardPresentation.message(for: failure.error))
                }
            }
        }
        return outputs
    }

    // MARK: Settings

    /// A setting's value as `esclop settings get` prints it.
    public static func value(of key: String) async throws -> String {
        let model = try await ready()
        do {
            return SettingsViewModel.text(for: try model.service.context.settings.value(forKey: key))
        } catch {
            throw Failure(message: SettingsViewModel.plain(error, key: key))
        }
    }

    /// Sets a setting from text, with the registry's checks (the same as the Settings window and
    /// `esclop settings set`); returns the value stored.
    public static func set(_ key: String, to text: String) async throws -> String {
        let model = try await ready()
        do {
            let stored = try model.service.context.settings.setValue(text, forKey: key)
            if key == EsclopSettings.pauseAutomaticOptimisations.key { model.pauseChanged(stored.boolValue ?? false) }
            return SettingsViewModel.text(for: stored)
        } catch {
            throw Failure(message: SettingsViewModel.plain(error, key: key))
        }
    }

    /// Pauses or resumes automatic optimisation; returns whether it is paused now.
    public static func setPaused(_ paused: Bool) async throws -> Bool {
        let model = try await ready()
        model.setPaused(paused)
        return model.paused
    }

    // MARK: Files

    /// Where a file Shortcuts passes as data (not as a file on disk) is written first.
    nonisolated static func temporaryFile(named name: String, data: Data) throws -> URL {
        let folder = Paths.temporary.appendingPathComponent("shortcuts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name.isEmpty ? "file" : name)
        try data.write(to: url)
        return url
    }
}
