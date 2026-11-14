// SPDX-License-Identifier: GPL-3.0-or-later
//
// The options popover's state for one file: the tab, the folded group, the slider positions,
// the crop being drawn, the facts in the header and the size estimates as they arrive. The
// popover makes one when it opens and drops it when it closes, cancelling the estimates.

import AppKit
import EsclopCore
import Foundation
import ImageIO
import Observation
import PDFKit
import UniformTypeIdentifiers

public enum OptionsTab: String, CaseIterable, Identifiable, Sendable {
    case optimise, size, sound, share

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .optimise: return Strings.text("Optimise")
        case .size: return Strings.text("Size")
        case .sound: return Strings.text("Sound")
        case .share: return Strings.text("Share")
        }
    }

    /// Audio has no pixels to resize: Sound takes the place of Size.
    public static func tabs(for kind: MediaKind?) -> [OptionsTab] {
        kind == .audio ? [.optimise, .sound, .share] : [.optimise, .size, .share]
    }
}

/// What the header says about the file besides its sizes.
public struct FileFacts: Equatable, Sendable {
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var pages: Int?
    public var hdr = false

    public init(width: Int? = nil, height: Int? = nil, duration: Double? = nil, pages: Int? = nil, hdr: Bool = false) {
        self.width = width
        self.height = height
        self.duration = duration
        self.pages = pages
        self.hdr = hdr
    }

    static func read(_ url: URL) async -> FileFacts {
        switch MediaKind.of(url) {
        case .image?:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            else { return FileFacts() }
            var width = properties[kCGImagePropertyPixelWidth] as? Int
            var height = properties[kCGImagePropertyPixelHeight] as? Int
            if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }
            let auxiliary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap)
            let depth = properties[kCGImagePropertyDepth] as? Int ?? 8
            return FileFacts(width: width, height: height, hdr: auxiliary != nil || depth > 8)
        case .video?, .audio?:
            guard let media = await MediaFacts.read(url) else { return FileFacts() }
            return FileFacts(width: media.width > 0 ? media.width : nil, height: media.height > 0 ? media.height : nil, duration: media.duration)
        case .pdf?:
            return FileFacts(pages: PDFDocument(url: url)?.pageCount)
        case nil:
            return FileFacts()
        }
    }
}

@MainActor @Observable
public final class OptionsModel {
    public let card: ResultCard
    @ObservationIgnored let app: AppModel
    public var tab: OptionsTab
    public var showsFormatOptions = false
    /// The quality slider while it is dragged; applied when released.
    public var quality: Double
    /// The downscale slider, 0.1...1 in 10 % steps.
    public var scale: Double = 1
    public var customFit = ""
    public var cropping = false
    public var crop: CropGeometry?
    public var name: String
    public var drill: Drill?
    public internal(set) var facts = FileFacts()
    public internal(set) var estimates: [EstimateRequest: Int] = [:]
    /// Estimates the engine could not make (a format it cannot write for this file).
    public private(set) var unavailable: Set<EstimateRequest> = []
    public private(set) var shortcuts: [String] = []

    public enum Drill: Equatable { case encoder, openWith, shortcut, pipeline, keepVisible }

    public init(card: ResultCard, app: AppModel) {
        self.card = card
        self.app = app
        tab = OptionsTab.tabs(for: MediaKind.of(card.source)).contains(card.optionsTab) ? card.optionsTab : .optimise
        quality = Double(card.choice.effectiveQuality)
        name = Self.shownName(of: card)
        if card.optionsTab == .size { cropping = true }
    }

    // MARK: What the file is

    public var kind: MediaKind? { MediaKind.of(card.shownFile) }
    public var original: URL? { app.originalFile(of: card) }
    /// The format the file arrived in: its extension first (".m4a" is M4A, though its type
    /// prefers ".mp4"), else its type.
    public var inputFormat: OutputFormat? {
        original.flatMap(OutputFormat.of) ?? OutputFormat.of(card.source) ?? card.inputType.flatMap { OutputFormat.of(type: $0) }
    }
    public var origin: FileOrigin { card.fileOrigin ?? .unknown }
    public var tabs: [OptionsTab] { OptionsTab.tabs(for: kind) }

    /// The default for this origin and format.
    public var suggestion: OptimiseChoice { Suggestion.choice(for: origin, input: inputFormat) }
    public var suggestionText: String { suggestion.summary(input: inputFormat, note: Suggestion.note(for: origin)) }
    /// Whether the result already follows the suggestion, reading the settings for what a
    /// choice leaves to them (the format it keeps, stripping metadata).
    public var isSuggestionApplied: Bool { effective(card.choice) == effective(suggestion) }

    func effective(_ choice: OptimiseChoice) -> OptimiseChoice {
        var resolved = choice
        if resolved.format == nil { resolved.format = inputFormat }
        if resolved.stripMetadata == nil { resolved.stripMetadata = EsclopSettings.stripMetadata.value(in: app.settings) }
        return resolved
    }

    /// Formats the tiles offer for this kind of file.
    public var formats: [OutputFormat] { Self.formats(for: kind) }

    /// The formats offered for a kind of file (the popover's tiles, the compare window's menu).
    public static func formats(for kind: MediaKind?) -> [OutputFormat] {
        switch kind {

        // Only what the engine writes: JPEG XL waits for an encoder in esclop-engine.
        case .image?: return [.png, .jpeg, .webp, .avif, .heic, .gif]
        case .video?: return [.mp4, .hevc, .av1, .webm, .mov, .gifVideo]
        case .audio?: return [.aac, .mp3, .opus, .flac]
        case .pdf?, nil: return []
        }
    }

    /// The format the file has now.
    /// The format the file has now: the result's own file, else the choice, else the input.
    public var currentFormat: OutputFormat? { card.result.flatMap { OutputFormat.of($0.output) } ?? card.choice.format ?? inputFormat }

    // MARK: Lifecycle

    public func appear() async {
        await app.classify(card)
        if facts == FileFacts(), let original { facts = await FileFacts.read(original) }
    }

    public func disappear() {
        if let original { Task { await app.estimator.cancel(original) } }
        if name != Self.shownName(of: card) { commitName() }
    }

    // MARK: Estimates

    public func estimate(_ request: EstimateRequest) -> Int? { estimates[request] }

    /// Starts an estimate the view shows; the view's task cancels with it.
    public func load(_ request: EstimateRequest) async {
        guard estimates[request] == nil, let original else { return }
        let reference = card.result.map { (EstimateRequest(choice: card.choice), $0.bytesAfter) }
        if let bytes = await app.estimator.estimate(original, origin: card.origin, request: request, reference: reference) {
            estimates[request] = bytes
        } else if !Task.isCancelled {
            unavailable.insert(request)
        }
    }

    public func request(format: OutputFormat) -> EstimateRequest {
        var choice = card.choice
        choice.format = format == inputFormat ? nil : format
        choice.quality = nil
        return EstimateRequest(choice: choice)
    }

    public var qualityRequest: EstimateRequest {
        var choice = card.choice
        choice.quality = Int(quality.rounded())
        return EstimateRequest(choice: choice)
    }

    public var scaleRequest: EstimateRequest { EstimateRequest(choice: card.choice, downscale: scale < 1 ? scale : nil) }

    public var cropRequest: EstimateRequest? {
        guard let size = crop?.cropSize else { return nil }
        return EstimateRequest(choice: card.choice, crop: size)
    }

    /// "PNG · 960 × 600", "HEVC · 3840 × 2160 · 2:14", "PDF · 28 pages": what the file is now.
    /// The size comes from the current result (after a crop or a downscale); the original's
    /// facts are only the fallback. The crop editor and the downscale slider keep working in the
    /// original's pixels, since every change runs again from the original.
    public var headerMeta: String {
        var parts = [currentFormat?.displayName].compactMap { $0 }
        var width = facts.width, height = facts.height, duration = facts.duration
        if let result = card.result {
            if let w = result.width, let h = result.height { (width, height) = (w, h) }
            if let d = result.duration { duration = d }
        }
        if let width, let height { parts.append("\(width) × \(height)") }
        if let duration { parts.append(Figures.duration(duration)) }
        if let pages = facts.pages { parts.append(Strings.format(pages == 1 ? "%d page" : "%d pages", pages)) }
        return parts.joined(separator: " · ")
    }

    /// "1470 × 956" at the slider's scale.
    public var scaledDimensions: String? {
        guard let width = facts.width, let height = facts.height else { return nil }
        return "\(Int((Double(width) * scale).rounded())) × \(Int((Double(height) * scale).rounded()))"
    }

    // MARK: Actions

    public func apply(_ choice: OptimiseChoice) {
        app.apply(choice, to: card)
    }

    public func choose(format: OutputFormat, keepBoth: Bool) {
        if keepBoth { return app.convertKeepingBoth(card, to: format) }
        var choice = card.choice
        choice.format = format == inputFormat ? nil : format
        choice.quality = nil
        apply(choice)
    }

    public func choose(compression: OptimiseChoice.Compression) {
        var choice = card.choice
        choice.compression = compression
        choice.quality = nil
        quality = Double(OptimiseChoice.quality(for: compression))
        apply(choice)
    }

    public func commitQuality() {
        var choice = card.choice
        choice.quality = Int(quality.rounded())
        guard choice != card.choice else { return }
        apply(choice)
    }

    public func update(_ change: (inout OptimiseChoice) -> Void) {
        var choice = card.choice
        change(&choice)
        guard choice != card.choice else { return }
        apply(choice)
    }

    public func commitScale() {
        app.downscale(card, to: scale)
    }

    public func restoreFullSize() {
        scale = 1
        app.downscale(card, to: 1)
    }

    public func fit(under bytes: Int) {
        app.fit(card, under: bytes)
    }

    public func startCrop(aspect: CropAspect) {
        guard let width = facts.width, let height = facts.height else { return }
        if var crop {
            crop.setAspect(aspect)
            self.crop = crop
        } else {
            var geometry = CropGeometry(imageWidth: width, imageHeight: height)
            geometry.setAspect(aspect)
            crop = geometry
        }
        cropping = true
    }

    public func applyCrop() {
        guard let size = crop?.cropSize else { return }
        app.crop(card, to: size)
    }

    public var ruleOn: Bool {
        get { card.appliedRule != nil || app.ruleExists(for: card) }
        set { app.setRule(newValue, for: card) }
    }

    public var canMakeRule: Bool { card.origin == .clipboard && card.fileOrigin != nil && card.inputType != nil }

    /// Only a name the person typed renames the file.
    public func commitName() {
        guard name != Self.shownName(of: card) else { return }
        if !app.rename(card, to: name) { name = Self.shownName(of: card) }
    }

    /// The name the header shows: the card's ("Copied image" for copied pixels, not the
    /// temporary file's "Clipboard 2026-11-10T02.52.31Z"), else the file's.
    static func shownName(of card: ResultCard) -> String {
        card.displayName ?? card.shownFile.deletingPathExtension().lastPathComponent
    }

    /// "Screenshot (PNG)", "Copied image (PNG)", "PNG file": where the file came from, in words.
    public var originLabel: String {
        let format = inputFormat?.displayName
        guard origin == .unknown else { return origin.title + (format.map { " (\($0))" } ?? "") }
        if card.origin == .clipboard {
            let noun = kind == .image ? Strings.text("Copied image") : Strings.text("Copied file")
            return noun + (format.map { " (\($0))" } ?? "")
        }
        return format.map { Strings.format("%@ file", $0) } ?? Strings.text("File")
    }

    public func loadShortcuts() async {
        shortcuts = await AppModel.shortcutNames()
    }
}

