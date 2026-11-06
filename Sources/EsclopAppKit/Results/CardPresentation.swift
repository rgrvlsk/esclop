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
        case openDetail
        case closeDetail
        case retry
        case reveal
        case copy
        case dismiss

        /// The label on a button in the detail card.
        public var title: String {
            switch self {
            case .undo: return "Undo"
            case let .convert(format): return "Convert to \(CardPresentation.formatName(format))"
            case .downscale: return "Downscale to half"
            case .crop: return "Crop"
            case .more: return "More options"
            case .openDetail: return "Show details"
            case .closeDetail: return "Close details"
            case .retry: return "Try again"
            case .reveal: return "Show in Finder"
            case .copy: return "Copy"
            case .dismiss: return "Dismiss"
            }
        }

        /// The tooltip of a round hover button, and what VoiceOver says for the action.
        public var accessibilityName: String {
            switch self {
            case .undo: return "Undo, restore the original"
            case .copy: return "Copy the file"
            default: return title
            }
        }

        public var symbol: String {
            switch self {
            case .undo: return "arrow.uturn.backward"
            case .convert: return "arrow.left.arrow.right"
            case .downscale: return "arrow.down.right.and.arrow.up.left"
            case .crop: return "crop"
            case .more: return "ellipsis"
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
    public init(card: ResultCard, locale: Locale = .current) {
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
            capsule = .working(card.aggressive ? "Optimising harder…" : "Optimising…")
            progress = fraction >= 0 ? min(1, fraction) : nil
            actions = [.dismiss]
            accessibilityLabel = "\(name), optimising, \(Figures.bytes(card.bytesBefore, locale: locale))"
        case let .done(result):
            fileName = card.displayName ?? result.output.lastPathComponent
            capsule = .result(before: result.bytesBefore, after: result.bytesAfter)
            if result.bytesAfter > result.bytesBefore { tone = .neutral }
            let undo: [Action] = result.backup != nil ? [.undo] : []
            let resultEditing = Self.editingActions(for: result.output, kind: result.kind)
            tools = undo + resultEditing + [.more]
            detailTitle = "Optimised"
            change = Figures.change(before: result.bytesBefore, after: result.bytesAfter, locale: locale)
            percent = Figures.percent(before: result.bytesBefore, after: result.bytesAfter, locale: locale)
            barEnd = result.bytesBefore > 0 ? min(1, max(0, Double(result.bytesAfter) / Double(result.bytesBefore))) : 1
            formats = "\(Self.formatName(of: result.source)) → \(Self.formatName(of: result.output))"
            dimensions = Self.dimensions(result)
            detailActions = undo + resultEditing
            actions = [.openDetail] + tools + [.reveal, .copy, .dismiss]
            accessibilityLabel = "\(fileName), \(Self.announcement(for: result, locale: locale))"
        case let .unchanged(bytes):
            capsule = .status(symbol: "checkmark", text: "Already optimised · \(Figures.bytes(bytes, locale: locale))")
            tone = .neutral
            tools = editing + [.more]
            detailTitle = "Already optimised"
            change = "Kept the original, \(Figures.bytes(bytes, locale: locale))"
            detailActions = editing
            actions = [.openDetail] + tools + [.reveal, .copy, .dismiss]
            accessibilityLabel = "\(name), already optimised, kept the original"
        case let .restored(result):
            fileName = card.displayName ?? result.source.lastPathComponent
            capsule = .status(symbol: "arrow.uturn.backward", text: "Original restored · \(Figures.bytes(result.bytesBefore, locale: locale))")
            tone = .neutral
            let restoredEditing = Self.editingActions(for: result.source, kind: result.kind)
            tools = restoredEditing + [.more]
            detailTitle = "Original restored"
            detailSymbol = "arrow.uturn.backward"
            change = Figures.bytes(result.bytesBefore, locale: locale)
            formats = Self.formatName(of: result.source)
            dimensions = Self.dimensions(result)
            detailActions = restoredEditing
            actions = [.openDetail] + tools + [.reveal, .copy, .dismiss]
            accessibilityLabel = "\(fileName), original restored"
        case let .failed(message):
            capsule = .error(title: "Couldn't optimise", message: message)
            tone = .error
            let exists = FileManager.default.fileExists(atPath: card.source.path)
            actions = exists ? [.retry, .reveal, .dismiss] : [.dismiss]
            accessibilityLabel = "\(name), not optimised: \(message) The original is kept."
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
    public static func announcement(for result: OptimisationResult, locale: Locale = .current) -> String {
        let size = Figures.bytes(result.bytesAfter, locale: locale)
        let percent = Figures.percent(before: result.bytesBefore, after: result.bytesAfter, locale: locale).dropFirst()
        let change = result.bytesAfter <= result.bytesBefore ? "\(percent) smaller" : "\(percent) larger"
        return "Optimised, \(size), \(change)"
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
            return "\(tool) is missing. Reinstall L'Esclop or run Scripts/build-tools.sh."
        case let .unsupportedFile(file):
            return "L'Esclop cannot optimise this kind of file (\(URL(fileURLWithPath: file).lastPathComponent))."
        case let .fileNotFound(path):
            return "\(URL(fileURLWithPath: path).lastPathComponent) is no longer there."
        case let .toolFailed(tool, code, stderr):
            let line = readable(stderr.split(separator: "\n").last.map(String.init) ?? "")
            return "\(tool) stopped with code \(code)\(line.isEmpty ? "" : ": \(line)")"
        case .cancelled:
            return "Stopped before it finished."
        case let .notPermitted(why):
            return why
        case let other:
            return other.description
        }
    }
}
