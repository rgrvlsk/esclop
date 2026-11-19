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
    case optimise, size, crop, sound, share

    public var id: String { rawValue }

    /// The tab's name, shown in small caps beside the tabs (docs/design/targets:
    /// pr4-options-popover-tabs): Format, Size, Sound, Actions.
    public var title: String {
        switch self {
        case .optimise: return Strings.text("Format")
        case .size: return Strings.text("Size")
        case .crop: return Strings.text("Crop")
        case .sound: return Strings.text("Sound")
        case .share: return Strings.text("Actions")
        }
    }

    /// The round tab's symbol.
    public var symbol: String {
        switch self {
        case .optimise: return "doc"
        case .size: return "arrow.up.left.and.arrow.down.right"
        case .crop: return "crop"
        case .sound: return "waveform"
        case .share: return "bolt"
        }
    }

    /// The tabs that have something for the kind: audio has no pixels, so Sound takes the place
    /// of Size and Crop.
    public static func tabs(for kind: MediaKind?) -> [OptionsTab] {
        kind == .audio ? [.optimise, .sound, .share] : [.optimise, .size, .crop, .share]
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
    /// The quality slider while it is dragged; applied when released.
    public var quality: Double
    /// The downscale slider, 0.1...1 in 10 % steps.
    public var scale: Double = 1
    public var customFit = ""
    public var cropping = false
    public var crop: CropGeometry?
    public var drill: Drill?
    /// A video's format tile, chosen and waiting for Convert.
    public var armed: OutputFormat?
    public internal(set) var facts = FileFacts()
    public internal(set) var estimates: [EstimateRequest: Int] = [:]
    /// Estimates the engine could not make (a format it cannot write for this file).
    public private(set) var unavailable: Set<EstimateRequest> = []
    public private(set) var shortcuts: [String] = []

    public enum Drill: Equatable { case openWith, shortcut }

    public init(card: ResultCard, app: AppModel) {
        self.card = card
        self.app = app
        tab = OptionsTab.tabs(for: MediaKind.of(card.source)).contains(card.optionsTab) ? card.optionsTab : .optimise
        quality = Double(card.choice.effectiveQuality)
        if card.optionsTab == .crop { cropping = true }
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
    /// HEVC and AV1 are written as .mp4 and a video's GIF as .gif, so the choice that made the
    /// file wins over its extension when the two agree.
    public var currentFormat: OutputFormat? {
        if let chosen = card.choice.format, let result = card.result, chosen.fileExtension == result.output.pathExtension.lowercased() {
            return chosen
        }
        return card.result.flatMap { OutputFormat.of($0.output) } ?? card.choice.format ?? inputFormat
    }

    // MARK: Lifecycle

    public func appear() async {
        await app.classify(card)
        if facts == FileFacts(), let original { facts = await FileFacts.read(original) }
    }

    public func disappear() {
        if let original { Task { await app.estimator.cancel(original) } }
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

    /// One of the Size tab's tiles: the original, a long side in pixels, or half.
    public struct SizePreset: Hashable, Identifiable {
        public var title: String
        /// The scale of the original, 1 for the original itself.
        public var factor: Double
        /// "Half, 1200 px": what VoiceOver says.
        public var spoken: String
        public var id: Double { factor }
    }

    /// Original, 2000 px and 1280 px when the picture is larger and not nearly half, and Half
    /// (docs/design/targets: pr4-options-popover-size-actions). Nothing that would enlarge it.
    public var sizePresets: [SizePreset] {
        guard let width = facts.width, let height = facts.height, width > 0, height > 0 else { return [] }
        let long = Double(max(width, height))
        var presets = [SizePreset(title: Strings.text("Original"), factor: 1, spoken: Strings.text("Original"))]
        // Half is the owner's tile: a pixel tile that is nearly half gives way to it.
        for side in [2000.0, 1280.0] where side < long * 0.95 && abs(side / long - 0.5) >= 0.05 {
            presets.append(SizePreset(title: "\(Int(side))\u{00A0}px", factor: side / long, spoken: "\(Int(side)) px"))
        }
        let half = Int((long / 2).rounded())
        presets.append(SizePreset(title: Strings.text("Half"), factor: 0.5, spoken: Strings.format("Half, %@ px", String(half))))
        return presets
    }

    /// The scale the result was made at, 1 when it was not scaled (a crop is not a scale).
    public var currentScale: Double { card.downscale }

    /// Whether the file is at this tile's size: Original only while no Fit or Crop changed it.
    public func isCurrent(_ factor: Double) -> Bool {
        abs(factor - currentScale) < 0.001 && !(factor == 1 && card.adjusted)
    }

    public func scaleRequest(_ factor: Double) -> EstimateRequest {
        EstimateRequest(choice: card.choice, downscale: factor < 1 ? factor : nil)
    }

    /// A Size tile or Custom: scale to `factor` of the original (never above it). The size it
    /// already has runs nothing; Original after Fit or Crop runs the original again.
    public func scale(to factor: Double) {
        let factor = min(1, max(0.01, factor))
        guard !isCurrent(factor) else { return }
        scale = factor
        factor < 1 ? commitScale() : restoreFullSize()
    }

    // MARK: Actions

    /// Runs `choice`; the quality slider follows it (a format or the suggestion clears the
    /// quality, so the slider goes back to what the choice will use).
    public func apply(_ choice: OptimiseChoice) {
        armed = nil
        quality = Double(choice.effectiveQuality)
        app.apply(choice, to: card)
    }

    /// A tile: an image converts at once; a video arms, since a video takes a while (owner's
    /// decision). ⌥ keeps both, and a video's GIF always keeps the video.
    public func pick(_ format: OutputFormat, keepBoth: Bool) {
        if format == .gifVideo || keepBoth { return choose(format: format, keepBoth: true) }
        if kind == .video, format != currentFormat {
            armed = armed == format ? nil : format
        } else {
            choose(format: format, keepBoth: false)
        }
    }

    public func choose(format: OutputFormat, keepBoth: Bool) {
        if keepBoth { return app.convertKeepingBoth(card, to: format) }
        var choice = card.choice
        choice.format = format == inputFormat ? nil : format
        choice.quality = nil
        apply(choice)
    }

    /// Runs the armed video format, with the quality set while it was armed.
    public func convertArmed() {
        guard let format = armed else { return }
        var choice = card.choice
        choice.format = format == inputFormat ? nil : format
        choice.quality = qualityTouched ? Int(quality.rounded()) : nil
        qualityTouched = false
        apply(choice)
    }

    /// The quality slider moved while a format was armed: it goes with the conversion.
    var qualityTouched = false

    /// The same file again, compressed harder: Clop's "Optimise aggressively" as an action.
    public func optimiseHarder() {
        choose(compression: .aggressive)
    }

    public func choose(compression: OptimiseChoice.Compression) {
        var choice = card.choice
        choice.compression = compression
        choice.quality = nil
        apply(choice)
    }

    public func commitQuality() {
        // Armed, the quality waits for Convert instead of running the current format again.
        if armed != nil { qualityTouched = true; return }
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

    /// The whole picture again, free: the Crop tab's preview with no frame drawn in. A file the
    /// card keeps cropped runs again uncropped.
    public func resetCrop() {
        if card.crop != nil { app.removeCrop(card) }
        guard let width = facts.width, let height = facts.height else { return }
        crop = CropGeometry(imageWidth: width, imageHeight: height)
        cropping = true
    }

    public func applyCrop() {
        guard let size = crop?.cropSize else { return }
        app.crop(card, to: size)
    }

    /// The rule the checkbox stands for: the stored one, else the one that made this result.
    /// Another choice in the popover does not change it; ticking the box again does.
    public var rule: ClipboardRule? { app.storedRule(for: card) ?? card.appliedRule }

    public var ruleOn: Bool {
        get { rule != nil }
        set { app.setRule(newValue, for: card) }
    }

    /// The stored rule makes something else than this result: "Use this from now on" offers
    /// to store the card's choice in its place.
    public var ruleDiffers: Bool {
        guard let stored = app.storedRule(for: card) else { return false }
        return stored.choice != card.choice
    }

    public func useChoiceAsRule() {
        app.setRule(true, for: card)
    }

    public var canMakeRule: Bool { card.origin == .clipboard && card.fileOrigin != nil && card.inputType != nil }

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

