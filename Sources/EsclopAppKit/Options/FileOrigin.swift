// SPDX-License-Identifier: GPL-3.0-or-later
//
// Where a file came from, guessed from plain signals (DESIGN.md › Origin rules). NSPasteboard
// does not reliably name the source app, so this is a heuristic: screenshot metadata, the
// screenshot folder, UTTypes, pasteboard types and the app that was in front when the copy
// happened. Anything unclear is `unknown`, which gets conservative defaults. Photos is never
// inferred from HEIC alone.

import Foundation
import UniformTypeIdentifiers

public enum FileOrigin: String, Codable, CaseIterable, Sendable {
    case screenshot, photos, browser, graphic, animatedGIF, screenRecording, pdfExport, voiceMemo, unknown
}

/// What is known about a file and the moment it arrived. Every field is optional evidence.
public struct OriginSignals: Equatable, Sendable {
    /// The file's type, as a UTType identifier.
    public var inputType: String
    /// The app in front when the copy happened, or the app that made the file.
    public var sourceApp: String?
    public var pasteboardTypes: Set<String> = []
    public var fileName: String?
    /// The folder holding the file, and the folder screenshots are saved to.
    public var folder: String?
    public var screenshotFolder: String?
    /// EXIF `UserComment` "Screenshot", or Spotlight's `kMDItemIsScreenCapture`.
    public var screenshotMetadata = false
    public var hasAlpha = false
    /// Whether the picture is mostly flat colour (an illustration, icon or diagram, not a photo).
    public var flatColour = false
    public var frameCount = 1
    /// PDF `Creator` and `Producer`.
    public var pdfCreator: String?
    /// The encoder tag of an audio file (`©too`), or its `kMDItemCreator`.
    public var audioEncoder: String?
    /// `kMDItemWhereFroms`: the file was downloaded from the web.
    public var downloadedFromWeb = false

    public init(inputType: String) {
        self.inputType = inputType
    }

    var type: UTType? { UTType(inputType) }
}

public enum OriginClassifier {
    public static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "org.chromium.Chromium", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "company.thebrowser.Browser",
        "company.thebrowser.dia", "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "app.zen-browser.zen", "com.kagi.kagimacOS",
    ]

    /// Pasteboard types only browsers write next to a copied image.
    static let browserPasteboardTypes: Set<String> = [
        "org.chromium.source-url", "org.chromium.web-custom-data", "org.mozilla.custom-clipdata",
        "com.apple.webarchive", "Apple Web Archive pasteboard type",
    ]

    static let screenshotApps: Set<String> = ["com.apple.screencaptureui", "com.apple.screenshot.launcher", "com.apple.Screenshot"]
    static let photosApps: Set<String> = ["com.apple.Photos", "com.apple.photolibraryd"]
    static let voiceMemoApps: Set<String> = ["com.apple.VoiceMemos"]

    /// Names macOS gives screenshots and screen recordings, in the languages it ships.
    static let screenshotNames = ["Screenshot", "Screen Shot", "Captura de pantalla", "Captura", "Bildschirmfoto", "Capture d’écran", "Schermata", "スクリーンショット"]
    static let recordingNames = ["Screen Recording", "Gravació de pantalla", "Grabación de pantalla", "Bildschirmaufnahme", "Enregistrement de l’écran", "Registrazione schermo"]

    /// Apps that export documents to PDF, matched in the PDF's Creator or Producer.
    static let pdfExporters = [
        "Quartz PDFContext", "Pages", "Keynote", "Numbers", "Microsoft", "Word", "PowerPoint", "Excel", "LibreOffice", "OpenOffice",
        "Google", "Skia/PDF", "Chromium", "Safari", "WebKit", "InDesign", "Illustrator", "Affinity", "LaTeX", "pdfTeX", "XeTeX",
        "LuaTeX", "Typst", "Figma", "Sketch", "Canva", "Notion",
    ]

    public static func classify(_ signals: OriginSignals) -> FileOrigin {
        let type = signals.type
        let isImage = type?.conforms(to: .image) ?? false
        let isVideo = type?.conforms(to: .movie) ?? false
        let isAudio = type?.conforms(to: .audio) ?? false
        let isPDF = type?.conforms(to: .pdf) ?? false
        let app = signals.sourceApp
        let name = signals.fileName ?? ""
        let inScreenshotFolder = signals.folder != nil && signals.folder == signals.screenshotFolder

        if isImage {
            if signals.screenshotMetadata || app.map(screenshotApps.contains) == true { return .screenshot }
            if inScreenshotFolder, screenshotNames.contains(where: name.hasPrefix) { return .screenshot }
        }
        if isVideo {
            if app.map(screenshotApps.contains) == true { return .screenRecording }
            if recordingNames.contains(where: name.hasPrefix) { return .screenRecording }
            if inScreenshotFolder, type?.conforms(to: .quickTimeMovie) == true { return .screenRecording }
        }
        if isAudio {
            if app.map(voiceMemoApps.contains) == true { return .voiceMemo }
            if let encoder = signals.audioEncoder, encoder.localizedCaseInsensitiveContains("VoiceMemos") { return .voiceMemo }
            if let folder = signals.folder, folder.localizedCaseInsensitiveContains("com.apple.voicememos") { return .voiceMemo }
        }
        if isImage || isVideo {
            // Photos from the app itself, its pasteboard or its library, never from HEIC alone.
            if app.map(photosApps.contains) == true { return .photos }
            if signals.pasteboardTypes.contains(where: { $0.hasPrefix("com.apple.photos") }) { return .photos }
            if let folder = signals.folder, folder.contains(".photoslibrary") { return .photos }
        }
        if isImage, type?.conforms(to: .gif) == true, signals.frameCount > 1 { return .animatedGIF }
        if isPDF, let creator = signals.pdfCreator, pdfExporters.contains(where: { creator.localizedCaseInsensitiveContains($0) }) {
            return .pdfExport
        }
        if isImage {
            if app.map(browsers.contains) == true { return .browser }
            if !signals.pasteboardTypes.isDisjoint(with: browserPasteboardTypes) { return .browser }
            if signals.downloadedFromWeb { return .browser }
            if signals.hasAlpha, signals.flatColour { return .graphic }
        }
        return .unknown
    }
}
