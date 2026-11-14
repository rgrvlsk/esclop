// SPDX-License-Identifier: GPL-3.0-or-later
//
// What a floating result says, as plain values: the footer, the card's buttons, the detail card
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
        /// Stops a job that is still running and removes its card.
        case stop
        /// Uploads the result to the default upload target.
        case upload
        case cancelUpload
        case retryUpload
        case copyLink

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
            case .stop: return Strings.text("Stop")
            case .upload: return Strings.text("Upload")
            case .cancelUpload: return Strings.text("Stop Uploading")
            case .retryUpload: return Strings.text("Upload Again")
            case .copyLink: return Strings.text("Copy Link")
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

        public var symbol: String {
            switch self {
            case .undo: return "arrow.uturn.backward"
            case .convert: return "arrow.left.arrow.right"
            case .downscale: return "arrow.down.right.and.arrow.up.left"
            case .crop: return "crop"
            case .more: return "ellipsis"
            case .compare: return "rectangle.lefthalf.inset.filled"
            case .openDetail: return "rectangle.expand.vertical"
            case .closeDetail, .dismiss, .stop: return "xmark"
            case .retry: return "arrow.clockwise"
            case .reveal: return "folder"
            case .copy: return "doc.on.doc"
            case .upload, .retryUpload: return "icloud.and.arrow.up"
            case .cancelUpload: return "xmark.circle"
            case .copyLink: return "link"
            }
        }
    }

    /// What the capsule pinned to the thumbnail's bottom edge shows.
    public enum Capsule: Equatable, Sendable {
        case working(String)
        /// A saving: the ring, the figure, the original size and the new one.
        case result(before: Int, after: Int)
        /// No symbol: the empty ring, nothing saved ("Already optimised").
        case status(symbol: String?, text: String)
        case error(title: String, message: String)
        case notice(title: String, detail: String)
    }

    public var fileName: String
    public var capsule: Capsule
    /// The footer's first line where no saving is drawn: "Already optimised", "Optimising…".
    public var headline = ""
    /// Its second line: the file's name, the size left as it was, or why it failed.
    public var caption = ""
    public var tone: Tone
    /// Work done so far while optimising; nil when the engine cannot tell.
    public var progress: Double?
    public var isWorking: Bool
    /// The card's round buttons on hover, chosen by where the file came from (`tools(for:undo:)`).
    public var tools: [Action]
    /// Every action, for the keyboard and VoiceOver.
    public var actions: [Action]

    // The detail card (docs/design/targets: pr2-detail-card)
    /// "2.4 MB → 612 kB", or the one size when nothing changed.
    public var change: String
    /// "PNG → WebP"
    public var formats: String
    /// "2940 × 1912", or the duration for video and audio.
    public var dimensions: String?
    /// The charcoal button: what the person most likely does next. The same choice as the card's
    /// first round button.
    public var primary: Action?
    /// Under its title: the folder the file is in, or what Copy does.
    public var primaryDetail: String?
    /// Up to two round buttons beside it.
    public var secondary: [Action]
    /// What "…" lists: everything else.
    public var menu: [Action]

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
        change = Figures.bytes(card.bytesBefore, locale: locale)
        formats = Self.formatName(of: card.source)
        dimensions = nil
        secondary = []
        menu = []
        let editing = Self.editingActions(for: card.source, kind: kind)

        switch card.phase {
        case let .working(fraction):
            isWorking = true
            capsule = .working(card.aggressive ? t("Optimising harder…") : t("Optimising…"))
            headline = card.aggressive ? t("Optimising harder…") : t("Optimising…")
            caption = name
            progress = fraction >= 0 ? min(1, fraction) : nil
            // The buttons only show while the options popover is open; "…" must stay so the
            // popover keeps its anchor while a choice from it runs.
            tools = card.machine.menuOpen ? [.more] : []
            actions = [.stop]
            // A detail left open while the file runs again stops it with its charcoal button.
            primary = .stop
            accessibilityLabel = f("%@, optimising, %@", name, Figures.bytes(card.bytesBefore, locale: locale))
        case let .done(result):
            fileName = card.displayName ?? result.output.lastPathComponent
            if Figures.isNoSaving(before: result.bytesBefore, after: result.bytesAfter) {
                // Never "✓ 379 kB · −0 %": a result with no saving reads as already optimised.
                capsule = .status(symbol: nil, text: f("Already optimised · %@", Figures.bytes(result.bytesAfter, locale: locale)))
                headline = t("Already optimised")
                caption = f("%@, left as it was", Figures.bytes(result.bytesAfter, locale: locale))
                tone = .neutral
            } else {
                capsule = .result(before: result.bytesBefore, after: result.bytesAfter)
                caption = fileName
            }
            if result.bytesAfter > result.bytesBefore { tone = .neutral }
            let undo: [Action] = result.backup != nil ? [.undo] : []
            let resultEditing = Self.editingActions(for: result.output, kind: result.kind)
            tools = Self.tools(for: card.origin, undo: !undo.isEmpty)
            change = Figures.change(before: result.bytesBefore, after: result.bytesAfter, locale: locale)
            formats = Self.formatName(of: result.source) == Self.formatName(of: result.output)
                ? Self.formatName(of: result.output)
                : "\(Self.formatName(of: result.source)) → \(Self.formatName(of: result.output))"
            dimensions = Self.dimensions(result)
            // Compare only when there is an original to compare with.
            let comparable = result.backup != nil || result.output.standardizedFileURL != result.source.standardizedFileURL
            (primary, primaryDetail, secondary, menu) = Self.detail(card, undo: !undo.isEmpty, menu: resultEditing + (comparable ? [.compare] : []), t: t)

            actions = Self.distinct([.openDetail] + tools + [.reveal, .copy, .dismiss])
            accessibilityLabel = "\(fileName), \(Self.announcement(for: result, locale: locale))"
        case let .unchanged(bytes):
            capsule = .status(symbol: nil, text: f("Already optimised · %@", Figures.bytes(bytes, locale: locale)))
            headline = t("Already optimised")
            caption = f("%@, left as it was", Figures.bytes(bytes, locale: locale))
            tone = .neutral
            tools = Self.tools(for: card.origin, undo: false)
            change = f("Kept the original, %@", Figures.bytes(bytes, locale: locale))
            (primary, primaryDetail, secondary, menu) = Self.detail(card, undo: false, menu: editing, t: t)
            actions = Self.distinct([.openDetail] + tools + [.reveal, .copy, .dismiss])
            accessibilityLabel = f("%@, already optimised, kept the original", name)
        case let .restored(result):
            fileName = card.displayName ?? result.source.lastPathComponent
            capsule = .status(symbol: "arrow.uturn.backward", text: f("Original restored · %@", Figures.bytes(result.bytesBefore, locale: locale)))
            headline = t("Original restored")
            caption = Figures.bytes(result.bytesBefore, locale: locale)
            tone = .neutral
            let restoredEditing = Self.editingActions(for: result.source, kind: result.kind)
            tools = Self.tools(for: card.origin, undo: false)
            change = Figures.bytes(result.bytesBefore, locale: locale)
            formats = Self.formatName(of: result.source)
            dimensions = Self.dimensions(result)
            (primary, primaryDetail, secondary, menu) = Self.detail(card, undo: false, menu: restoredEditing, t: t)
            actions = Self.distinct([.openDetail] + tools + [.reveal, .copy, .dismiss])
            accessibilityLabel = f("%@, original restored", fileName)
        case let .failed(message):
            capsule = .error(title: t("Couldn’t optimise"), message: message)
            headline = t("Couldn’t optimise")
            caption = message
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
        applyUpload(card, name: fileName, t: t, f: f)
    }

    /// The upload's state over the result's: progress and Stop while it goes, the link once it is
    /// on the clipboard, the reason and Upload Again when it fails (the file stays put).
    @MainActor private mutating func applyUpload(_ card: ResultCard, name: String, t: (String) -> String, f: (String, any CVarArg...) -> String) {
        switch card.upload {
        case let .uploading(fraction):
            capsule = .working(f("Uploading… %d %%", Int((min(1, max(0, fraction)) * 100).rounded())))
            headline = f("Uploading… %d %%", Int((min(1, max(0, fraction)) * 100).rounded()))
            caption = name
            progress = min(1, max(0, fraction))
            promote(.cancelUpload)
            actions = [.cancelUpload] + actions.filter { $0 != .dismiss } + [.dismiss]
            accessibilityLabel = f("%@, uploading", name)
        case .uploaded:
            capsule = .status(symbol: "link", text: t("Uploaded · link copied"))
            headline = t("Link copied")
            caption = name
            tone = .saving
            tools = [.copyLink, .more]
            promote(.copyLink)
            actions = [.copyLink] + actions
            accessibilityLabel = f("%@, uploaded, the link is on the clipboard", name)
        case let .failed(message):
            capsule = .error(title: t("Couldn’t upload"), message: message)
            headline = t("Couldn’t upload")
            caption = message
            tone = .error
            promote(.retryUpload)
            actions = [.retryUpload] + actions
            accessibilityLabel = f("%@, not uploaded: %@ The file is kept.", name, message)
        case nil:
            if card.result?.link != nil {
                capsule = .status(symbol: "link", text: t("Uploaded · link copied"))
                headline = t("Link copied")
                caption = name
                tools = [.copyLink, .more]
                promote(.copyLink)
                actions = [.copyLink] + actions
                // VoiceOver hears what the capsule shows, not the result under it.
                accessibilityLabel = f("%@, uploaded, the link is on the clipboard", name)
            }
        }
    }

    /// The detail's actions, 1 + 2 + "…" (docs/design/targets/README.md › Detail card). A copied
    /// screenshot goes back to the clipboard; any other file is shown in Finder, with Copy beside
    /// it. Undo while a backup exists. Everything else is in "…", ending with the options.
    @MainActor private static func detail(
        _ card: ResultCard, undo: Bool, menu rest: [Action], t: (String) -> String
    ) -> (Action?, String?, [Action], [Action]) {
        let clipboard = card.origin == .clipboard
        let detail = clipboard
            ? t("Put it back on the clipboard")
            : FileManager.default.displayName(atPath: card.shownFile.deletingLastPathComponent().path)
        return (clipboard ? .copy : .reveal, detail, (clipboard ? [] : [.copy]) + (undo ? [.undo] : []), rest + [.more])
    }

    /// An upload's own action takes the detail's charcoal button; the one it replaces goes first
    /// in "…".
    private mutating func promote(_ action: Action) {
        if let primary { menu.insert(primary, at: 0) }
        primary = action
        primaryDetail = nil
    }

    /// Convert, downscale and crop, where they apply to the file.
    static func editingActions(for url: URL, kind: MediaKind?) -> [Action] {
        var actions: [Action] = []
        if let target = convertTarget(for: url, kind: kind) { actions.append(.convert(target)) }
        if kind == .image || kind == .video { actions += [.downscale, .crop] }
        return actions
    }

    /// Each action once, in its first place.
    static func distinct(_ actions: [Action]) -> [Action] {
        var seen = Set<Action>()
        return actions.filter { seen.insert($0).inserted }
    }

    /// The card's buttons, for what the person most likely wants next: a copied screenshot goes
    /// back to the clipboard, any other file is found in Finder. Undo while a backup exists. "…"
    /// opens the options, where convert, downscale and crop live.
    static func tools(for origin: RequestOrigin, undo: Bool) -> [Action] {
        [origin == .clipboard ? .copy : .reveal] + (undo ? [.undo] : []) + [.more]
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
