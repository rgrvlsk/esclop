// SPDX-License-Identifier: GPL-3.0-or-later
//
// What a card says, as plain values: the text, where the bar ends and which actions apply.
// Kept apart from the view so the wording and the arithmetic are tested without drawing.

import EsclopCore
import EsclopIPC
import Foundation

public struct CardPresentation: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case saving, neutral, warm, error }

    public enum Action: String, CaseIterable, Sendable {
        case restore, reveal, copy, dismiss

        public var title: String {
            switch self {
            case .restore: return "Restore"
            case .reveal: return "Show in Finder"
            case .copy: return "Copy"
            case .dismiss: return "Dismiss"
            }
        }

        /// What VoiceOver says for the action.
        public var accessibilityName: String {
            switch self {
            case .restore: return "Restore the original"
            case .reveal: return "Show in Finder"
            case .copy: return "Copy the file"
            case .dismiss: return "Dismiss"
            }
        }

        public var symbol: String {
            switch self {
            case .restore: return "arrow.uturn.backward"
            case .reveal: return "folder"
            case .copy: return "doc.on.doc"
            case .dismiss: return "xmark"
            }
        }
    }

    public var fileName: String
    /// The large figure: the saving ("−72%"), or a word when there is no saving to show.
    public var headline: String
    public var headlineIsFigure: Bool
    public var tone: Tone
    /// Sizes or the error message, under the headline.
    public var detail: String
    public var bytesBefore: Int
    public var bytesAfter: Int
    /// Where the bar ends, as a fraction of the original size. nil hides the bar.
    public var barEnd: Double?
    /// Work done so far while optimising.
    public var progress: Double?
    public var actions: [Action]
    public var accessibilityLabel: String

    @MainActor
    public init(card: ResultCard) {
        let name = card.displayName ?? card.source.lastPathComponent
        bytesBefore = card.bytesBefore
        bytesAfter = card.bytesBefore
        progress = nil
        switch card.phase {
        case let .working(fraction):
            fileName = name
            headline = card.aggressive ? "Optimising harder" : "Optimising"
            headlineIsFigure = false
            tone = card.aggressive ? .warm : .neutral
            detail = ByteSize.format(card.bytesBefore)
            barEnd = 1
            progress = fraction >= 0 ? min(1, fraction) : nil
            actions = [.dismiss]
            accessibilityLabel = "\(name), optimising, \(ByteSize.format(card.bytesBefore))"
        case let .done(result):
            fileName = card.displayName ?? result.output.lastPathComponent
            bytesBefore = result.bytesBefore
            bytesAfter = result.bytesAfter
            let percent = Self.percent(result)
            headline = percent
            headlineIsFigure = true
            tone = result.bytesAfter <= result.bytesBefore ? (card.aggressive ? .warm : .saving) : .neutral
            detail = "\(ByteSize.format(result.bytesBefore)) → \(ByteSize.format(result.bytesAfter))"
            barEnd = result.bytesBefore > 0 ? min(1, max(0, Double(result.bytesAfter) / Double(result.bytesBefore))) : 1
            actions = (result.backup != nil ? [.restore] : []) + [.reveal, .copy, .dismiss]
            let change = result.bytesAfter <= result.bytesBefore ? "\(percent.dropFirst()) smaller" : "\(percent.dropFirst()) larger"
            accessibilityLabel = "\(fileName), \(change), \(ByteSize.format(result.bytesBefore)) to \(ByteSize.format(result.bytesAfter))"
        case let .unchanged(bytes):
            fileName = name
            bytesAfter = bytes
            headline = "Already optimised"
            headlineIsFigure = false
            tone = .neutral
            detail = "Kept the original, \(ByteSize.format(bytes))"
            barEnd = 1
            actions = [.reveal, .copy, .dismiss]
            accessibilityLabel = "\(name), already optimised, kept the original"
        case let .restored(result):
            fileName = card.displayName ?? result.source.lastPathComponent
            bytesAfter = result.bytesBefore
            headline = "Original restored"
            headlineIsFigure = false
            tone = .neutral
            detail = ByteSize.format(result.bytesBefore)
            barEnd = 1
            actions = [.reveal, .copy, .dismiss]
            accessibilityLabel = "\(fileName), original restored"
        case let .failed(message):
            fileName = name
            headline = "Not optimised"
            headlineIsFigure = false
            tone = .error
            detail = message
            barEnd = nil
            actions = FileManager.default.fileExists(atPath: card.source.path) ? [.reveal, .dismiss] : [.dismiss]
            accessibilityLabel = "\(name), not optimised: \(message)"
        case let .notice(title, message):
            fileName = ""
            headline = title
            headlineIsFigure = false
            tone = .neutral
            detail = message
            barEnd = nil
            actions = [.dismiss]
            accessibilityLabel = "\(title). \(message)"
        }
    }

    /// "−72%", "−0.4%", "+12%": a true minus sign, one decimal below 10%.
    public static func percent(_ result: OptimisationResult) -> String {
        guard result.bytesBefore > 0 else { return "0%" }
        let value = abs(Double(result.bytesBefore - result.bytesAfter)) / Double(result.bytesBefore) * 100
        let text = value < 10 && value.rounded() != value
            ? String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
            : String(Int(value.rounded()))
        return (result.bytesAfter <= result.bytesBefore ? "−" : "+") + text + "%"
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
            let line = stderr.split(separator: "\n").last.map(String.init) ?? ""
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
