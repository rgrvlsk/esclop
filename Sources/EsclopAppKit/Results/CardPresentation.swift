// SPDX-License-Identifier: GPL-3.0-or-later
//
// What a floating result says, as plain values: the capsule, the hover buttons, the detail card
// and what VoiceOver reads. Kept apart from the views so the wording and the arithmetic are
// tested without drawing. All of the result's copy lives here.

import EsclopCore
import EsclopIPC
import Foundation

public struct CardPresentation: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case saving, neutral, warm, error }

    public enum Action: Hashable, Sendable {
        case undo
        case convert(OutputFormat)
        case downscale
        case crop
        case more
        /// Opens the compare window on the result.
        case compare
        case openDetail
        case closeDetail
        case retry
        case reveal
        case copy
        case dismiss

        /// The label on a button in the detail card.
        public var title: String {
            switch self {
            case .undo: return Strings.text("Undo")
            case let .convert(format): return Strings.format("Convert to %@", CardPresentation.formatName(format))
            case .downscale: return Strings.text("Downscale to half")
            case .crop: return Strings.text("Crop")
            case .more: return Strings.text("More options")
            case .compare: return Strings.text("Compare")
            case .openDetail: return Strings.text("Show details")
            case .closeDetail: return Strings.text("Hide details")
            case .retry: return Strings.text("Try again")
            case .reveal: return Strings.text("Show in Finder")
            case .copy: return Strings.text("Copy")
            case .dismiss: return Strings.text("Dismiss")
            }
        }

        /// The tooltip of a round hover button, and what VoiceOver says for the action.
        public var accessibilityName: String {
            switch self {
            case .undo: return Strings.text("Undo, restore the original")
            case .copy: return Strings.text("Copy the file")
            case .compare: return Strings.text("Compare the original and the optimised file")
            default: return title

            }
        }

        /// Its name in the `hoverButtons` setting.
        var settingName: String? {
            switch self {
            case .undo: return "undo"
            case .convert: return "convert"
            case .downscale: return "downscale"
            case .crop: return "crop"
            default: return nil
            }
        }

        public var symbol: String {
            switch self {
            case .undo: return "arrow.uturn.backward"
            case .convert: return "arrow.left.arrow.right"
            case .downscale: return "arrow.down.right.and.arrow.up.left"
            case .crop: return "crop"
            case .more: return "ellipsis"
            case .compare: return "rectangle.lefthalf.inset.filled"
            case .openDetail: return "rectangle.expand.vertical"
            case .closeDetail, .dismiss: return "xmark"
            case .retry: return "arrow.clockwise"
            case .reveal: return "folder"
            case .copy: return "doc.on.doc"
            }
        }
    }

    /// What the capsule pinned to the thumbnail's bottom edge shows.
    public enum Capsule: Equatable, Sendable {
        case working(String)
        /// Counts down from `before` to `after` when the result arrives.
        case result(before: Int, after: Int)
        case status(symbol: String, text: String)
        case error(title: String, message: String)
        case notice(title: String, detail: String)
    }

    public var fileName: String
    public var capsule: Capsule
    public var tone: Tone
    /// Work done so far while optimising; nil when the engine cannot tell.
    public var progress: Double?
    public var isWorking: Bool
    /// The round buttons above the thumbnail.
    public var tools: [Action]
    /// Every action, for the keyboard and VoiceOver.
    public var actions: [Action]

    // The detail card
    public var detailTitle: String
    public var detailSymbol: String
    public var change: String
    public var percent: String?
    /// Where the deflate bar ends, as a fraction of the original size.
    public var barEnd: Double
    /// "PNG → WebP"
    public var formats: String
    /// "2940 × 1912", or the duration for video and audio.
    public var dimensions: String?
    public var detailActions: [Action]

    public var accessibilityLabel: String

    @MainActor
    public init(card: ResultCard, locale: Locale = Strings.locale) {
        func t(_ key: String) -> String { Strings.text(key, locale: locale) }
        func f(_ key: String, _ arguments: any CVarArg...) -> String { String(format: t(key), locale: locale, arguments: arguments) }
        let name = card.displayName ?? card.source.lastPathComponent
        let kind = MediaKind.of(card.source)
        fileName = name
        tone = card.aggressive ? .warm : .saving
        progress = nil
        isWorking = false
        tools = []
        detailTitle = ""
        detailSymbol = "checkmark"
        change = Figures.bytes(card.bytesBefore, locale: locale)
        percent = nil
        barEnd = 1
        formats = Self.formatName(of: card.source)
        dimensions = nil
        detailActions = []
        let editing = Self.editingActions(for: card.source, kind: kind)

        switch card.phase {
        case let .working(fraction):
            isWorking = true
            capsule = .working(card.aggressive ? t("Optimising harder…") : t("Optimising…"))
            progress = fraction >= 0 ? min(1, fraction) : nil
            // The row only shows while the options popover is open; "…" must stay in it so the
            // popover keeps its anchor while a choice from it runs.
            tools = card.machine.menuOpen ? [.more] : []
            actions = [.dismiss]
            accessibilityLabel = f("%@, optimising, %@", name, Figures.bytes(card.bytesBefore, locale: locale))
        case let .done(result):
            fileName = card.displayName ?? result.output.lastPathComponent
            if Figures.isNoSaving(before: result.bytesBefore, after: result.bytesAfter) {
                // Never "✓ 379 kB · −0 %": a result with no saving reads as already optimised.
                capsule = .status(symbol: "checkmark", text: f("Already optimised · %@", Figures.bytes(result.bytesAfter, locale: locale)))
                tone = .neutral
            } else {
                capsule = .result(before: result.bytesBefore, after: result.bytesAfter)
            }
            if result.bytesAfter > result.bytesBefore { tone = .neutral }
            let undo: [Action] = result.backup != nil ? [.undo] : []
            let resultEditing = Self.editingActions(for: result.output, kind: result.kind)
            tools = Self.hoverTools(resultEditing, undo: !undo.isEmpty, shown: card.hoverButtons)
            let noSaving = Figures.isNoSaving(before: result.bytesBefore, after: result.bytesAfter)
            detailTitle = noSaving ? t("Already optimised") : t("Optimised")
            change = Figures.change(before: result.bytesBefore, after: result.bytesAfter, locale: locale)
            percent = noSaving ? nil : Figures.percent(before: result.bytesBefore, after: result.bytesAfter, locale: locale)
            barEnd = result.bytesBefore > 0 ? min(1, max(0, Double(result.bytesAfter) / Double(result.bytesBefore))) : 1
            formats = "\(Self.formatName(of: result.source)) → \(Self.formatName(of: result.output))"
            dimensions = Self.dimensions(result)
            // Compare only when there is an original to compare with.
            let comparable = result.backup != nil || result.output.standardizedFileURL != result.source.standardizedFileURL
            detailActions = undo + (comparable ? [.compare] : []) + resultEditing

            actions = [.openDetail] + tools + [.reveal, .copy, .dismiss]
            accessibilityLabel = "\(fileName), \(Self.announcement(for: result, locale: locale))"
        case let .unchanged(bytes):
            capsule = .status(symbol: "checkmark", text: f("Already optimised · %@", Figures.bytes(bytes, locale: locale)))
            tone = .neutral
            tools = Self.hoverTools(editing, undo: false, shown: card.hoverButtons)
            detailTitle = t("Already optimised")
            change = f("Kept the original, %@", Figures.bytes(bytes, locale: locale))
            detailActions = editing
            actions = [.openDetail] + tools + [.reveal, .copy, .dismiss]
            accessibilityLabel = f("%@, already optimised, kept the original", name)
        case let .restored(result):
            fileName = card.displayName ?? result.source.lastPathComponent
            capsule = .status(symbol: "arrow.uturn.backward", text: f("Original restored · %@", Figures.bytes(result.bytesBefore, locale: locale)))
            tone = .neutral
            let restoredEditing = Self.editingActions(for: result.source, kind: result.kind)
            tools = Self.hoverTools(restoredEditing, undo: false, shown: card.hoverButtons)
            detailTitle = t("Original restored")
            detailSymbol = "arrow.uturn.backward"
            change = Figures.bytes(result.bytesBefore, locale: locale)
            formats = Self.formatName(of: result.source)
            dimensions = Self.dimensions(result)
            detailActions = restoredEditing
            actions = [.openDetail] + tools + [.reveal, .copy, .dismiss]
            accessibilityLabel = f("%@, original restored", fileName)
        case let .failed(message):
            capsule = .error(title: t("Couldn’t optimise"), message: message)
            tone = .error
            let exists = FileManager.default.fileExists(atPath: card.source.path)
            actions = exists ? [.retry, .reveal, .dismiss] : [.dismiss]
            accessibilityLabel = f("%@, not optimised: %@ The original is kept.", name, message)
        case let .notice(title, message):
            fileName = ""
            capsule = .notice(title: title, detail: message)
            tone = .neutral
            actions = [.dismiss]
            accessibilityLabel = "\(title). \(message)"
        }
    }

    /// Convert, downscale and crop, where they apply to the file.
    static func editingActions(for url: URL, kind: MediaKind?) -> [Action] {
        var actions: [Action] = []
        if let target = convertTarget(for: url, kind: kind) { actions.append(.convert(target)) }
        if kind == .image || kind == .video { actions += [.downscale, .crop] }
        return actions
    }

    /// The hover row: the editing actions the person kept in "Customise buttons", then "…".
    static func hoverTools(_ editing: [Action], undo: Bool, shown: [String]) -> [Action] {
        let names = Set(shown)
        let kept = editing.filter { names.contains($0.settingName ?? "") }
        return (undo && names.contains("undo") ? [.undo] : []) + kept + [.more]
    }

    /// The name of a hover button in the `hoverButtons` setting.
    public static func hoverButtonTitle(_ name: String) -> String {
        switch name {
        case "undo": return Strings.text("Undo")
        case "convert": return Strings.text("Convert")
        case "downscale": return Strings.text("Downscale")
        default: return Strings.text("Crop")
        }
    }

    /// The one-click conversion: WebP for images (PNG for WebP itself), MP4 for other videos,
    /// AAC for audio. PDFs have none.
    public static func convertTarget(for url: URL, kind: MediaKind?) -> OutputFormat? {
        let ext = url.pathExtension.lowercased()
        switch kind {
        case .image: return ext == "webp" ? .png : .webp
        case .video: return ext == "mp4" ? nil : .mp4
        case .audio: return ext == "m4a" ? .mp3 : .aac
        case .pdf, nil: return nil
        }
    }

    /// "Optimised, 612 kB, 75 % smaller": said once when a result arrives.
    public static func announcement(for result: OptimisationResult, locale: Locale = Strings.locale) -> String {
        let size = Figures.bytes(result.bytesAfter, locale: locale)
        if Figures.isNoSaving(before: result.bytesBefore, after: result.bytesAfter) {
            return String(format: Strings.text("Already optimised · %@", locale: locale), locale: locale, size)
        }
        let percent = Figures.percent(before: result.bytesBefore, after: result.bytesAfter, locale: locale).dropFirst()
        let key = result.bytesAfter <= result.bytesBefore ? "Optimised, %@, %@ smaller" : "Optimised, %@, %@ larger"
        return String(format: Strings.text(key, locale: locale), locale: locale, size, String(percent))
    }

    static func dimensions(_ result: OptimisationResult) -> String? {
        if let duration = result.duration, result.kind == .video || result.kind == .audio { return Figures.duration(duration) }
        if let width = result.width, let height = result.height { return "\(width) × \(height)" }
        return nil
    }

    static func formatName(of url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return OutputFormat(rawValue: ext == "jpg" ? "jpeg" : ext).map(formatName) ?? ext.uppercased()
    }

    static func formatName(_ format: OutputFormat) -> String {
        switch format {
        case .jpeg: return "JPEG"
        case .webp: return "WebP"
        case .hevc: return "HEVC"
        case .aac: return "AAC"
        case .gifVideo: return "GIF"
        default: return format.fileExtension.uppercased()
        }
    }

    /// A tool's last line without the file path it starts with: "/tmp/a.mov: Invalid data" says
    /// "Invalid data". The card already names the file, and paths are long and personal.
    static func readable(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~"), let range = trimmed.range(of: ": ", options: .backwards) else { return trimmed }
        return String(trimmed[range.upperBound...])
    }

    /// A readable message for an engine error: what went wrong and what to do.
    public static func message(for error: Error) -> String {
        switch EsclopError.wrap(error) {
        case let .toolMissing(tool):
            return Strings.format("%@ is missing. Reinstall L’Esclop or run Scripts/build-tools.sh.", tool)
        case let .unsupportedFile(file):
            return Strings.format("L’Esclop cannot optimise this kind of file (%@).", URL(fileURLWithPath: file).lastPathComponent)
        case let .fileNotFound(path):
            return Strings.format("%@ is no longer there.", URL(fileURLWithPath: path).lastPathComponent)
        case let .toolFailed(tool, code, stderr):
            let line = readable(stderr.split(separator: "\n").last.map(String.init) ?? "")
            return line.isEmpty ? Strings.format("%@ stopped with code %d", tool, Int(code)) : Strings.format("%@ stopped with code %d: %@", tool, Int(code), line)

        case .cancelled:
            return Strings.text("Stopped before it finished.")
        case let .unreadable(kind):
            return Strings.text(EsclopError.unreadableMessage(kind))
        case let .leftAsIs(reason):
            return Strings.text(reason)
        case let .notPermitted(why):
            return why
        case let other:
            return other.description
        }
    }
}
