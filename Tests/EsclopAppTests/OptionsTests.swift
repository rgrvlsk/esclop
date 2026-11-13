// SPDX-License-Identifier: GPL-3.0-or-later
//
// The options popover's logic: where a file came from, what it suggests, how a choice becomes a
// request, clipboard rules from the checkbox to the next copy, the size model and the crop editor.

import AppKit
import EsclopCore
@testable import EsclopAppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite struct OriginClassifierTests {
    func signals(_ type: UTType, _ change: (inout OriginSignals) -> Void = { _ in }) -> OriginSignals {
        var signals = OriginSignals(inputType: type.identifier)
        signals.folder = "/tmp/someone/Downloads"
        signals.screenshotFolder = "/tmp/someone/Desktop"
        change(&signals)
        return signals
    }

    @Test func screenshots() {
        #expect(OriginClassifier.classify(signals(.png) { $0.screenshotMetadata = true }) == .screenshot)
        #expect(OriginClassifier.classify(signals(.png) { $0.sourceApp = "com.apple.screencaptureui" }) == .screenshot)
        #expect(OriginClassifier.classify(signals(.png) {
            $0.folder = "/tmp/someone/Desktop"
            $0.fileName = "Screenshot 2026-11-05 at 10.42"
        }) == .screenshot)
        // A PNG on the Desktop is not a screenshot by itself.
        #expect(OriginClassifier.classify(signals(.png) { $0.folder = "/tmp/someone/Desktop"; $0.fileName = "diagram" }) == .unknown)
    }

    @Test func photosNeverFromHEICAlone() {
        #expect(OriginClassifier.classify(signals(.heic)) == .unknown)
        #expect(OriginClassifier.classify(signals(.heic) { $0.sourceApp = "com.apple.Photos" }) == .photos)
        #expect(OriginClassifier.classify(signals(.heic) { $0.pasteboardTypes = ["com.apple.photos.object-reference.asset"] }) == .photos)
        #expect(OriginClassifier.classify(signals(.jpeg) { $0.folder = "/tmp/someone/Pictures/Photos Library.photoslibrary/originals/A" }) == .photos)
    }

    @Test func browsers() {
        #expect(OriginClassifier.classify(signals(.webP) { $0.sourceApp = "com.apple.Safari" }) == .browser)
        #expect(OriginClassifier.classify(signals(.png) { $0.pasteboardTypes = ["public.png", "org.chromium.source-url"] }) == .browser)
        #expect(OriginClassifier.classify(signals(.jpeg) { $0.downloadedFromWeb = true }) == .browser)
    }

    @Test func graphicsAndAnimations() {
        #expect(OriginClassifier.classify(signals(.png) { $0.hasAlpha = true; $0.flatColour = true }) == .graphic)
        #expect(OriginClassifier.classify(signals(.png) { $0.hasAlpha = true }) == .unknown, "a photo with alpha is not a graphic")
        #expect(OriginClassifier.classify(signals(.gif) { $0.frameCount = 12 }) == .animatedGIF)
        #expect(OriginClassifier.classify(signals(.gif)) == .unknown)
    }

    @Test func recordingsDocumentsAndMemos() {
        #expect(OriginClassifier.classify(signals(.quickTimeMovie) { $0.fileName = "Screen Recording 2026-11-05 at 10.42" }) == .screenRecording)
        #expect(OriginClassifier.classify(signals(.quickTimeMovie) { $0.fileName = "Gravació de pantalla 2026-11-05" }) == .screenRecording)
        #expect(OriginClassifier.classify(signals(.quickTimeMovie) { $0.folder = "/tmp/someone/Desktop" }) == .screenRecording)
        #expect(OriginClassifier.classify(signals(.mpeg4Movie)) == .unknown)
        #expect(OriginClassifier.classify(signals(.pdf) { $0.pdfCreator = "Pages macOS Version 15.0 (Build 24A335) Quartz PDFContext" }) == .pdfExport)
        #expect(OriginClassifier.classify(signals(.pdf) { $0.pdfCreator = "ScanSnap Manager" }) == .unknown, "a scan is not an export")
        #expect(OriginClassifier.classify(signals(.mpeg4Audio) { $0.sourceApp = "com.apple.VoiceMemos" }) == .voiceMemo)
        #expect(OriginClassifier.classify(signals(.mpeg4Audio) { $0.audioEncoder = "com.apple.VoiceMemos (iPhone Version 18.0)" }) == .voiceMemo)
        #expect(OriginClassifier.classify(signals(.mpeg4Audio)) == .unknown)
    }

    @Test func readsTheScreenshotMarkFromAFile() async throws {
        let temp = TempDir()
        let file = temp.url.appendingPathComponent("copied.png")
        try screenshotPNG().write(to: file)
        let read = await OriginSignals.read(file, sourceApp: "com.example.editor", pasteboardTypes: ["public.png"])
        #expect(read.screenshotMetadata)
        #expect(read.inputType == UTType.png.identifier)
        #expect(OriginClassifier.classify(read) == .screenshot)
    }
}

@Suite struct SuggestionTests {
    let en = Locale(identifier: "en")
    let ca = Locale(identifier: "ca")

    @Test func followsTheOriginTable() {
        #expect(Suggestion.choice(for: .screenshot, input: .png) == OptimiseChoice(format: .png, stripMetadata: true))
        #expect(Suggestion.choice(for: .photos, input: .heic).format == .jpeg)
        #expect(Suggestion.choice(for: .photos, input: .jpeg).format == nil)
        #expect(Suggestion.choice(for: .browser, input: .webp).format == .webp)
        #expect(Suggestion.choice(for: .graphic, input: .png).format == .png)
        #expect(Suggestion.choice(for: .animatedGIF, input: .gif).format == .webp)
        let recording = Suggestion.choice(for: .screenRecording, input: .mov)
        #expect(recording.format == .hevc && recording.fps == 30 && recording.stripMetadata == true)
        #expect(Suggestion.choice(for: .pdfExport, input: .pdf).pdfDPI == 150)
        let memo = Suggestion.choice(for: .voiceMemo, input: .m4a)
        #expect(memo.format == .aac && memo.audioBitrate == 96 && memo.loudness == -16)
        #expect(Suggestion.choice(for: .unknown, input: .png) == .standard, "unknown origin keeps the defaults")
    }

    @Test func summariesInEnglishAndCatalan() {
        let shot = Suggestion.choice(for: .screenshot, input: .png)
        #expect(shot.summary(input: .png, locale: en) == "PNG · Adaptive · strip metadata")
        #expect(shot.summary(input: .png, locale: ca) == "PNG · Adaptativa · sense metadades")
        #expect(Suggestion.choice(for: .screenRecording, input: .mov).summary(input: .mov, locale: en) == "HEVC · 30 fps · strip metadata")
        #expect(Suggestion.choice(for: .pdfExport, input: .pdf).summary(input: .pdf, locale: ca) == "PDF · 150 DPI · conserva el text")
        #expect(Suggestion.choice(for: .voiceMemo, input: .m4a).summary(input: .m4a, locale: en) == "AAC · 96 kbps · −16\u{00A0}LUFS")
        #expect(Suggestion.choice(for: .photos, input: .heic).summary(input: .heic, note: "strip location", locale: en) == "JPEG · Adaptive · strip location")
    }

    @Test func choicesBecomeRequests() {
        var request = OptimisationRequest(sources: [], origin: .clipboard)
        OptimiseChoice(compression: .lossless).apply(to: &request)
        #expect(request.quality == CompressionQuality(tier: .custom, factor: 0))
        OptimiseChoice(compression: .aggressive).apply(to: &request)
        #expect(request.quality == .aggressive)
        OptimiseChoice(format: .webp, quality: 82).apply(to: &request)
        #expect(request.format == .webp)
        #expect(request.quality == CompressionQuality(tier: .custom, factor: 18), "the slider runs the other way from the factor")
        #expect(OptimiseChoice.quality(for: .adaptive) == 70)
        OptimiseChoice(format: .hevc, stripMetadata: true, fps: 30).apply(to: &request)
        #expect(request.fpsCap == 30 && request.stripMetadata == true && request.format == .hevc)
    }
}

@MainActor
@Suite struct ClipboardRuleTests {
    let en = Locale(identifier: "en")
    let ca = Locale(identifier: "ca")

    @Test func storedByOriginAndInputFormat() throws {
        let settings = TestSettings()
        let rules = ClipboardRules(settings: settings.store)
        let webp = ClipboardRule(origin: .screenshot, inputType: UTType.png.identifier, choice: OptimiseChoice(format: .webp))
        try rules.save(webp)
        try rules.save(ClipboardRule(origin: .photos, inputType: UTType.heic.identifier, choice: OptimiseChoice(format: .jpeg)))
        #expect(rules.rule(origin: .screenshot, inputType: UTType.png.identifier) == webp)
        #expect(rules.rule(origin: .browser, inputType: UTType.png.identifier) == nil, "another origin is another rule")
        // The same key replaces the rule.
        try rules.save(ClipboardRule(origin: .screenshot, inputType: UTType.png.identifier, choice: OptimiseChoice(format: .avif)))
        #expect(rules.all.count == 2)
        #expect(rules.rule(origin: .screenshot, inputType: UTType.png.identifier)?.choice.format == .avif)
        try rules.delete(origin: .screenshot, inputType: UTType.png.identifier)
        #expect(rules.all.map(\.origin) == [.photos])
        // They live in the registry, readable by the CLI.
        #expect(EsclopSettings.clipboardRules.value(in: settings.store).first?.contains("\"origin\":\"photos\"") == true)
    }

    @Test func copyInBothLanguages() {
        let png = UTType.png.identifier
        #expect(ClipboardRule.checkboxTitle(origin: .screenshot, inputType: png, locale: en) == "Always apply to PNG screenshots")
        #expect(ClipboardRule.checkboxTitle(origin: .screenshot, inputType: png, locale: ca) == "Aplica-ho sempre a les captures de pantalla PNG")
        #expect(ClipboardRule.checkboxTitle(origin: .photos, inputType: UTType.heic.identifier, locale: ca) == "Aplica-ho sempre a les fotos HEIC")
        let rule = ClipboardRule(origin: .screenshot, inputType: png, choice: OptimiseChoice(format: .webp))
        #expect(rule.tooltip(locale: en) == "Rule: PNG screenshots → WebP · Adaptive")
        #expect(rule.promise(locale: ca) == "Les properes captures PNG es convertiran a WebP · Adaptativa")
    }

    @Test func aRuleAppliesToTheNextScreenshotUntilUnticked() async throws {
        let harness = Harness()
        harness.model.frontmostApp = { "com.example.editor" }
        try EsclopSettings.autoCopyToClipboard.set(false, in: harness.settings.store)

        harness.model.handleClipboard(.optimiseImage(screenshotPNG(), .png))
        #expect(await eventually { harness.model.cards.first?.result != nil })
        let first = try #require(harness.model.cards.first)
        #expect(first.fileOrigin == .screenshot)
        #expect(first.inputType == UTType.png.identifier)
        #expect(first.appliedRule == nil)
        #expect(harness.requests.requests.last?.format == nil, "no rule yet: the default")

        // Convert from the popover, then tick "Always apply to PNG screenshots".
        harness.model.apply(OptimiseChoice(format: .webp), to: first)
        #expect(await eventually { harness.requests.requests.count == 2 && first.result != nil })
        harness.model.setRule(true, for: first)
        #expect(first.appliedRule?.choice.format == .webp)

        harness.model.handleClipboard(.optimiseImage(screenshotPNG(), .png))
        #expect(await eventually { harness.model.cards.count == 2 && harness.model.cards.last?.result != nil })
        let second = try #require(harness.model.cards.last)
        #expect(harness.requests.requests.last?.format == .webp, "the rule chose WebP")
        #expect(second.appliedRule?.choice.format == .webp, "the capsule shows the rule glyph")

        // Unticking deletes the rule; the next copy gets the default again.
        harness.model.setRule(false, for: second)
        #expect(harness.model.rules.all.isEmpty)
        harness.model.handleClipboard(.optimiseImage(screenshotPNG(), .png))
        #expect(await eventually { harness.model.cards.count == 3 && harness.model.cards.last?.result != nil })
        #expect(harness.requests.requests.last?.format == nil)
        #expect(harness.model.cards.last?.appliedRule == nil)
    }

    @Test func choosingInThePopoverKeepsTheCard() async throws {
        let harness = Harness()
        _ = await harness.model.run(harness.job(harness.temp.file("a.png", bytes: 100_000)))
        let card = try #require(harness.model.cards.first)
        card.machine.setMenuOpen(true, at: Date())
        harness.model.apply(OptimiseChoice(compression: .aggressive), to: card)
        #expect(await eventually { harness.requests.requests.count == 2 && card.result != nil })
        #expect(harness.model.cards.map(\.id) == [card.id], "the popover keeps its anchor")
        #expect(harness.requests.requests.last?.quality == .aggressive)
        #expect(card.machine.showsHoverButtons, "the row stays while the popover is open")
        harness.model.fit(card, under: 20_000)
        #expect(await eventually { harness.requests.requests.count == 3 && card.result != nil })
        harness.model.crop(card, to: CropSize(rect: CropRect(x: 0, y: 0, width: 10, height: 10)))
        #expect(await eventually { harness.requests.requests.count == 4 && card.result != nil })
        #expect(harness.requests.requests.last?.crop?.rect == CropRect(x: 0, y: 0, width: 10, height: 10))
        #expect(harness.requests.requests.last?.quality == .aggressive, "size changes keep the choice")
    }

    /// The card's buttons follow where the file came from: a copied screenshot goes back to the
    /// clipboard, any other file is found in Finder. Undo only while a backup exists; "…" always.
    @Test func theCardsButtonsFollowWhereTheFileCameFrom() async throws {
        let harness = Harness()
        _ = await harness.model.run(harness.job(harness.temp.file("a.png", bytes: 100_000), origin: .clipboard))
        _ = await harness.model.run(harness.job(harness.temp.file("b.png", bytes: 100_000), origin: .dropZone))
        let copied = try #require(harness.model.cards.first { $0.origin == .clipboard })
        let dropped = try #require(harness.model.cards.first { $0.origin == .dropZone })
        let undo: [CardPresentation.Action] = copied.result?.backup != nil ? [.undo] : []
        #expect(copied.presentation.tools == [.copy] + undo + [.more])
        #expect(dropped.presentation.tools == [.reveal] + undo + [.more])
        #expect(CardPresentation.tools(for: .finder, undo: false) == [.reveal, .more], "no Undo without a backup")
        #expect(Set(dropped.presentation.actions).count == dropped.presentation.actions.count, "each action once")
    }
}

@Suite struct SizeModelTests {
    let recording = MediaFacts(width: 2880, height: 1800, fps: 60, duration: 40, hasAudio: false)

    @Test func videoFollowsCodecScaleAndFrameRate() {
        let h264 = SizeModel.video(recording, EstimateRequest(choice: .standard), input: .mov)
        let hevc = SizeModel.video(recording, EstimateRequest(choice: OptimiseChoice(format: .hevc)), input: .mov)
        let half = SizeModel.video(recording, EstimateRequest(choice: .standard, downscale: 0.5), input: .mov)
        let thirty = SizeModel.video(recording, EstimateRequest(choice: OptimiseChoice(fps: 30)), input: .mov)
        #expect(hevc < h264)
        #expect(abs(half / h264 - 0.25) < 0.001, "half the side, a quarter of the pixels")
        #expect(abs(thirty / h264 - 0.5) < 0.001)
        let aggressive = SizeModel.video(recording, EstimateRequest(choice: OptimiseChoice(compression: .aggressive)), input: .mov)
        #expect(aggressive < h264)
    }

    @Test func calibratesByTheResultAlreadyMade() {
        // The model said 100 for the current choice and the real file is 80: other choices scale by 0.8.
        #expect(SizeModel.calibrated(50, model: 100, actual: 80) == 40)
        #expect(SizeModel.calibrated(50, model: nil, actual: nil) == 50)
        #expect(SizeModel.calibrated(50, model: 100, actual: 10_000) == 200, "the correction is bounded")
    }

    @Test func audioIsBitrateTimesDuration() {
        let memo = MediaFacts(width: 0, height: 0, fps: 0, duration: 522, hasAudio: true)
        let bytes = SizeModel.audio(memo, EstimateRequest(choice: OptimiseChoice(format: .aac, audioBitrate: 96)), input: .m4a)
        #expect(Int(bytes) == 96 * 1000 / 8 * 522)
    }
}

@Suite struct CropGeometryTests {
    @Test func aspectPresetsCentreTheLargestRectangle() {
        var crop = CropGeometry(imageWidth: 400, imageHeight: 300)
        #expect(crop.cropSize == nil, "the whole picture changes nothing")
        crop.setAspect(.ratio(1, 1))
        #expect(crop.rect == CGRect(x: 50, y: 0, width: 300, height: 300))
        crop.setAspect(.ratio(16, 9))
        #expect(crop.rect.width == 400 && crop.rect.height == 225)
        #expect(crop.cropSize?.rect == CropRect(x: 0, y: 38, width: 400, height: 225))
    }

    @Test func freeCropDragsEachSideAndStaysInside() {
        var crop = CropGeometry(imageWidth: 400, imageHeight: 300)
        crop.drag(.topLeft, by: CGSize(width: 40, height: 30))
        #expect(crop.rect == CGRect(x: 40, y: 30, width: 360, height: 270))
        crop.drag(.right, by: CGSize(width: -60, height: 0))
        #expect(crop.rect.maxX == 340)
        crop.move(by: CGSize(width: 500, height: 500))
        #expect(crop.rect.maxX == 400 && crop.rect.maxY == 300, "moving never leaves the picture")
        crop.drag(.left, by: CGSize(width: 1000, height: 0))
        #expect(crop.rect.width == CropGeometry.minimum)
    }

    @Test func aLockedAspectSurvivesDragging() {
        var crop = CropGeometry(imageWidth: 400, imageHeight: 300)
        crop.setAspect(.ratio(1, 1))
        crop.drag(.bottomRight, by: CGSize(width: -100, height: -20))
        #expect(crop.rect.width == crop.rect.height)
        #expect(crop.rect.minX == 50 && crop.rect.minY == 0, "the opposite corner stays put")
    }

    @Test func typedSizeLocksTheShapeAndScales() {
        var crop = CropGeometry(imageWidth: 400, imageHeight: 300)
        crop.setOutput(width: 200, height: 100)
        #expect(crop.aspect == .ratio(2, 1))
        #expect(crop.rect.width / crop.rect.height == 2)
        #expect(crop.outputWidth == 200 && crop.outputHeight == 100)
        #expect(crop.cropSize?.width == 200)
    }
}

@Suite struct LocalisationTests {
    let ca = Locale(identifier: "ca_ES")

    @Test func catalanComesFromTheCatalog() {
        #expect(Strings.text("Undo", locale: ca) == "Desfés")
        #expect(Strings.text("Format and options", locale: ca) == "Format i opcions")
        #expect(Strings.text("Undo", locale: Locale(identifier: "en")) == "Undo")
        #expect(Strings.text("Undo", locale: Locale(identifier: "de")) == "Undo", "no translation: the English base")
    }

    /// Every literal the app looks up has a Catalan translation in the catalog.
    @Test func everyKeyIsTranslated() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/EsclopAppKit")
        let catalogData = try Data(contentsOf: sources.appendingPathComponent("Resources/Localizable.xcstrings"))
        let catalog = try #require(try JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let pattern = try NSRegularExpression(pattern: #"Strings\.(?:text|format)\("((?:[^"\\]|\\.)*)""#)
        var missing: [String] = []
        var checked = 0
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for file in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let key = String(text[range])
                if key.contains("\\(") { continue }
                checked += 1
                let entry = strings[key] as? [String: Any]
                let ca = (entry?["localizations"] as? [String: Any])?["ca"]
                if ca == nil { missing.append(key) }
            }
        }
        #expect(checked > 80, "the scan found the app's strings")
        #expect(missing.isEmpty, "untranslated: \(missing)")
    }

    @Test func announcementInCatalan() {
        let result = OptimisationResult(
            source: URL(fileURLWithPath: "/tmp/a.png"), output: URL(fileURLWithPath: "/tmp/a.png"), kind: .image,
            bytesBefore: 2_448_000, bytesAfter: 612_000, startedAt: Date(), finishedAt: Date()
        )
        #expect(CardPresentation.announcement(for: result, locale: ca) == "Optimitzat, 612\u{00A0}kB, 75\u{00A0}% més petit")
    }
}

/// A PNG carrying the EXIF comment macOS puts on screenshots.
func screenshotPNG() -> Data {
    let data = NSMutableData()
    let source = CGImageSourceCreateWithData(pngData() as CFData, nil)!
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    let exif: [CFString: Any] = [kCGImagePropertyExifUserComment: "Screenshot"]
    CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
    CGImageDestinationFinalize(destination)
    return data as Data
}
