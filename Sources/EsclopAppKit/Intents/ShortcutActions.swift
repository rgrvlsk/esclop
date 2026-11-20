// SPDX-License-Identifier: GPL-3.0-or-later
//
// What L'Esclop's Shortcuts actions do, apart from App Intents so tests drive it directly. The
// files go through the running app's usual jobs with the `shortcuts` origin: floating results,
// or the batch window from `batchWindowFrom` files, as a drop does. The results come back as
// files, in order, so actions chain. When Shortcuts starts the app to run an action, the action
// waits for it to finish starting.

import EsclopCore
import EsclopIPC
import Foundation

@MainActor
public enum ShortcutActions {
    /// The running app's model; set when the app starts.
    public static var model: AppModel?

    /// Fetches a web address for "Optimise from URL"; tests replace it.
    static var download: @Sendable (URL) async throws -> URL = { try await WebDownload.fetch($0) }

    public enum Operation: Equatable, Sendable {
        case optimise(harder: Bool)
        case convert(OutputFormat)
        case downscale(Double)
        case crop(CropSize)
        case pipeline(String)
        case cropPDF(PDFCropSpec)
        case playbackSpeed(Double)
    }

    /// Where results go: `settings` follows "Optimised … go" and "Converted … go".
    public enum Place: Equatable, Sendable {
        case settings, inPlace, besideOriginal
        case folder(URL)
    }

    /// The choices every file action shares.
    public struct Options: Equatable, Sendable {
        public var hideResult = false
        public var place: Place = .settings
        /// nil: the operation's own (Optimise harder is aggressive, the rest adaptive).
        public var compression: OptimiseChoice.Compression?
        /// Videos only; other files ignore it.
        public var removeAudio = false
        /// Put the results on the clipboard when the action is done.
        public var copy = false

        public init(
            hideResult: Bool = false, place: Place = .settings, compression: OptimiseChoice.Compression? = nil,
            removeAudio: Bool = false, copy: Bool = false
        ) {
            self.hideResult = hideResult
            self.place = place
            self.compression = compression
            self.removeAudio = removeAudio
            self.copy = copy
        }
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

    /// Runs `operation` on the files and returns the results' files, in order. Files L'Esclop
    /// does not handle are refused up front; a file that fails fails the action, with its reason.
    /// The files run together, as a drop of them does: from `batchWindowFrom` files one batch
    /// window shows them, else one floating result each.
    public static func run(_ operation: Operation, on files: [URL], options: Options = Options()) async throws -> [URL] {
        let model = try await ready()
        try check(operation, files, options: options)
        let jobs = files.map { job(operation, for: $0, options: options, factory: model.factory) }
        let batch = !options.hideResult && jobs.count >= model.batchThreshold ? model.openBatch(origin: .shortcuts) : nil
        // Every file shows in the window at once, waiting, before its job starts.
        for file in files { batch?.add(file, bytes: AppModel.size(of: file)) }
        let reports = await withTaskGroup(of: (Int, JobReport).self) { group in
            for (index, job) in jobs.enumerated() {
                group.addTask { (index, await model.run(job, batch: batch)) }
            }
            var reports = [JobReport?](repeating: nil, count: jobs.count)
            for await (index, report) in group { reports[index] = report }
            return reports.compactMap { $0 }
        }
        var outputs: [URL] = []
        var failures: [String] = []
        for (file, report) in zip(files, reports) {
            if let failure = report.failures.first {
                if case .alreadySmaller = failure.error {
                    // Already optimised: the file goes on unchanged, as the floating result says.
                    outputs.append(file)
                    continue
                }
                // A pipeline that failed late names its step and what its earlier steps changed.
                var message = CardPresentation.message(for: failure.error)
                if let step = failure.step { message = Strings.format("The step %@ failed: %@", step, message) }
                if let partial = report.results.first, partial.backup != nil {
                    message += " " + Strings.format("The steps before it already changed the file (%@); Recent Results can put the original back.", partial.output.path)
                }
                failures.append(files.count == 1 ? message : Strings.format("%@: %@", file.lastPathComponent, message))
            } else if let result = report.results.first {
                outputs.append(result.output)
            }
        }
        // A file that fails fails the action, which then returns nothing: the error names every
        // file that failed and says the others are done, so the person knows what changed.
        if !failures.isEmpty {
            var message = failures.joined(separator: "\n")
            if !outputs.isEmpty {
                message += "\n" + (outputs.count == 1
                    ? Strings.text("The other file was optimised; Recent Results has it.")
                    : Strings.format("The other %d files were optimised; Recent Results has them.", outputs.count))
            }
            throw Failure(message: message)
        }
        if options.copy, !outputs.isEmpty { model.writeClipboard(files: outputs) }
        return outputs
    }

    /// Downloads each web address (the Shortcut's run is the person's request), then optimises
    /// the downloads like files. A file URL is used as it is.
    public static func optimise(addresses: [URL], harder: Bool, options: Options = Options()) async throws -> [URL] {
        guard !addresses.isEmpty else { throw Failure(message: Strings.text("No address was given to the action.")) }
        var files: [URL] = []
        for address in addresses {
            if address.isFileURL { files.append(address); continue }
            do {
                guard let web = try WebDownload.address(address.absoluteString) else { throw EsclopError.invalidArgument(address.absoluteString) }
                files.append(try await download(web))
            } catch {
                throw Failure(message: Strings.format("Could not download %@: %@", address.absoluteString, CardPresentation.message(for: error)))
            }
        }
        return try await run(.optimise(harder: harder), on: files, options: options)
    }

    /// Refuses what no file of the action could do, before anything runs.
    static func check(_ operation: Operation, _ files: [URL], options: Options = Options()) throws {
        guard !files.isEmpty else { throw Failure(message: Strings.text("No files were given to the action.")) }
        let unsupported = files.filter { MediaKind.of($0) == nil }
        guard unsupported.isEmpty else {
            throw Failure(message: Strings.format("L’Esclop cannot optimise this kind of file (%@).", names(unsupported)))
        }
        if case .folder = options.place {
            // One folder holds one file of each name: two sources named alike (or converted to
            // the same name) would write over each other. The files run at the same time.
            // ponytail: only Convert's new extension is foreseen; "Adaptive image format" can turn
            // a PNG into a JPEG beside a JPEG of the same name (the first is kept as a backup).
            // Plan the real destinations if a person hits it.
            var seen = Set<String>()
            for file in files {
                var name = file.lastPathComponent
                if case let .convert(format) = operation { name = file.deletingPathExtension().lastPathComponent + "." + format.fileExtension }
                guard seen.insert(name.lowercased()).inserted else {
                    throw Failure(message: Strings.format("Two results would be named %@ in the folder. Rename one, or save beside the originals.", name))
                }
            }
        }
        switch operation {
        case let .downscale(factor) where !(factor > 0 && factor <= 1):
            throw Failure(message: Strings.text("The factor is above 0 and at most 1: 0.5 is half the width and height."))
        case let .playbackSpeed(factor) where !(factor > 0 && factor <= 100):
            throw Failure(message: Strings.text("The speed is above 0 and at most 100: 2 plays twice as fast, 0.5 at half speed."))
        case .playbackSpeed:
            let others = files.filter { MediaKind.of($0) != .video && MediaKind.of($0) != .audio }
            if !others.isEmpty { throw Failure(message: Strings.format("Only videos and audio files change speed (%@).", names(others))) }
        case .cropPDF:
            let others = files.filter { MediaKind.of($0) != .pdf }
            if !others.isEmpty { throw Failure(message: Strings.format("Only PDFs crop to a page shape (%@).", names(others))) }
        default:
            break
        }
    }

    /// One file's job: the operation, then the options on its request.
    static func job(_ operation: Operation, for file: URL, options: Options, factory: RequestFactory) -> OptimisationJob {
        let location: OutputLocation? = switch options.place {
        case .settings: nil
        case .inPlace: .inPlace
        case .besideOriginal: .sameFolder
        // A template ending in / is a folder: the result keeps its name there.
        case let .folder(folder): .path(folder.standardizedFileURL.path + "/")
        }
        var job = factory.job(for: file, origin: .shortcuts, aggressive: operation == .optimise(harder: true), location: location)
        if let compression = options.compression { job.request.quality = compression.quality }
        job.request.showResultUI = !options.hideResult
        job.request.removeAudio = options.removeAudio && MediaKind.of(file) == .video
        switch operation {
        case .optimise: break
        case let .convert(format): job.request.format = format
        case let .downscale(factor): job.request.downscale = factor < 1 ? factor : nil
        case let .crop(size): job.request.crop = size
        case let .pipeline(name): job.operation = .pipeline(name)
        case let .cropPDF(spec): job.operation = .cropPDF(spec)
        case let .playbackSpeed(factor): job.request.playbackSpeed = factor
        }
        return job
    }

    private static func names(_ files: [URL]) -> String {
        files.map(\.lastPathComponent).joined(separator: ", ")
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
