// SPDX-License-Identifier: GPL-3.0-or-later
//
// The findings of the live UI check of main (F1–F10), as logic. The visual ones also have
// pictures in RenderTests, OptionsRenderTests and SettingsRenderTests.

import AppKit
import EsclopCore
@testable import EsclopAppKit
import EsclopIPC
import Foundation
import Testing
import UniformTypeIdentifiers

@MainActor
@Suite struct UICheckFindingsTests {
    let renders = RenderTests()
    let en = Locale(identifier: "en")

    // F1: after a crop or a downscale the header shows the result's size, not the original's.
    @Test func headerShowsTheCurrentSize() {
        let harness = Harness()
        var result = renders.saved(URL(fileURLWithPath: "/tmp/photo.jpg"), before: 575_000, after: 512_000)
        result.width = 1920
        result.height = 1080
        let card = renders.card(.done(result), source: URL(fileURLWithPath: "/tmp/photo.jpg"))
        harness.model.add(card)
        let model = OptionsModel(card: card, app: harness.model)
        model.facts = FileFacts(width: 1920, height: 1200)
        #expect(model.headerMeta == "JPEG · 1920 × 1080", "the cropped size")
        #expect(model.scaledDimensions == "1920 × 1200", "the slider still works from the original")
        result.width = 960
        result.height = 600
        card.phase = .done(result)
        #expect(model.headerMeta == "JPEG · 960 × 600")
    }

    // F3: an unreadable file says so plainly, per kind, with no tool output and no path.
    @Test func unreadableFilesSayWhatHappened() {
        for kind in MediaKind.allCases {
            let message = CardPresentation.message(for: EsclopError.unreadable(kind: kind))
            #expect(message.hasPrefix("This file isn’t"))
            #expect(message.hasSuffix("It may be damaged."))
            #expect(!message.contains("/") && !message.contains("…") && !message.contains("ffprobe"))
            #expect(message.count < 80, "fits the capsule without an ellipsis")
            #expect(EsclopError.unreadable(kind: kind).description == message, "the CLI and MCP say the same")
            #expect(EsclopError.unreadable(kind: kind).code == "unreadable")
        }
        #expect(CardPresentation.message(for: EsclopError.unreadable(kind: .video)) == "This file isn’t a video L’Esclop can read. It may be damaged.")
        #expect(Strings.text(EsclopError.unreadableMessage(.video), locale: Locale(identifier: "ca")) == "Aquest fitxer no és un vídeo que L’Esclop pugui llegir. Pot ser que estigui malmès.")
        let row = BatchRow(source: URL(fileURLWithPath: "/tmp/broken.mov"), bytesBefore: 11)
        row.state = .failed(CardPresentation.message(for: EsclopError.unreadable(kind: .video)))
        #expect(BatchPresentation.status(of: row, locale: en) == "This file isn’t a video L’Esclop can read. It may be damaged.")
    }

    // F4: a result with no saving never shows "✓ … · −0 %".
    @Test func noSavingReadsAsAlreadyOptimised() {
        let flat = renders.card(.done(renders.saved(before: 379_000, after: 378_990)))
        let info = CardPresentation(card: flat, locale: en)
        #expect(info.capsule == .status(symbol: "checkmark", text: "Already optimised · 379\u{00A0}kB"))
        #expect(info.tone == .neutral)
        #expect(info.percent == nil)
        #expect(CardPresentation.announcement(for: renders.saved(before: 379_000, after: 378_990), locale: en) == "Already optimised · 379\u{00A0}kB")
        // A real saving, however small, still shows.
        let small = CardPresentation(card: renders.card(.done(renders.saved(before: 100_000, after: 99_000))), locale: en)
        #expect(small.capsule == .result(before: 100_000, after: 99_000))
        #expect(Figures.isNoSaving(before: 379_000, after: 378_990))
        #expect(!Figures.isNoSaving(before: 100_000, after: 99_000))
    }

    // F5: copied pixels are "Copied image", and an unknown origin has a human label.
    @Test func copiedImagesHaveTheirCardName() {
        let harness = Harness()
        let card = renders.card(.done(renders.saved(URL(fileURLWithPath: "/tmp/Clipboard 2026-11-10T02.52.31Z.png"))), source: URL(fileURLWithPath: "/tmp/Clipboard 2026-11-10T02.52.31Z.png"))
        card.displayName = "Copied image"
        card.fileOrigin = .unknown
        card.inputType = UTType.png.identifier
        harness.model.add(card)
        let model = OptionsModel(card: card, app: harness.model)
        #expect(model.name == "Copied image")
        #expect(model.originLabel == "Copied image (PNG)")
        // Closing without typing a name renames nothing.
        model.commitName()
        #expect(card.displayName == "Copied image")
        let dropped = renders.card(.done(renders.saved()))
        dropped.fileOrigin = .unknown
        dropped.inputType = UTType.png.identifier
        let fromDrop = ResultCard(jobID: UUID(), source: URL(fileURLWithPath: "/tmp/a.png"), origin: .dropZone, bytesBefore: 1, phase: .done(renders.saved()))
        fromDrop.fileOrigin = .unknown
        fromDrop.inputType = UTType.png.identifier
        harness.model.add(fromDrop)
        #expect(OptionsModel(card: fromDrop, app: harness.model).originLabel == "PNG file")
        dropped.fileOrigin = .screenshot
        #expect(OptionsModel(card: dropped, app: harness.model).originLabel == "Screenshot (PNG)")
    }

    // F8: closing the detail by hand gives the result its whole hide delay again.
    @Test func closingTheDetailRestartsTheHideDelay() {
        let start = Date(timeIntervalSince1970: 0)
        var machine = FloatingResultMachine(expectedDuration: 0)
        machine.finished(at: start, hideAfter: 10)
        machine.openDetail(at: start + 1)
        #expect(machine.advance(to: start + 30) == nil, "an open detail never hides")
        machine.closeDetail(at: start + 30)
        #expect(machine.level == .thumbnail)
        #expect(machine.hideDeadline == start + 40, "the full ten seconds, not the late two")
        #expect(machine.advance(to: start + 32) == nil)
        #expect(machine.advance(to: start + 40) == .dismiss)
    }

    // F2: a result's row of buttons gets room, so it never covers the result above.
    @Test func theButtonRowGetsRoom() {
        let card = renders.card(.done(renders.saved()))
        let row = Metrics.toolSize + Metrics.toolLift
        #expect(FloatingStackView.rowRoom(for: card, isFirst: false, corner: .bottomRight) == 0)
        card.machine.pointerEnteredButtons(at: Date())
        #expect(FloatingStackView.rowRoom(for: card, isFirst: false, corner: .bottomRight) == row, "the results above move up")
        #expect(FloatingStackView.rowRoom(for: card, isFirst: true, corner: .bottomRight) == 0, "the top one uses the stack's padding")
        let still = renders.card(.done(renders.saved()))
        #expect(FloatingStackView.rowRoom(for: still, isFirst: false, corner: .topRight) == row, "at the top the room is always there")
        #expect(Metrics.stackGap >= 12, "capsules do not touch the next thumbnail")
    }

    // F9: what the Settings window shows is written for a person.
    @Test func settingsDescriptionsAreForPeople() {
        for setting in SettingsRegistry.shared.all {
            let text = setting.description
            for raw in ["keepFrames", "dropFrames", "-2 ", "-4 ", "JSON", "docs/", "from 0.1 to 1", " copies it untouched"] {
                #expect(!text.contains(raw), "\(setting.key): \(text)")
            }
        }
        // The technical wording stays in the schema for the CLI and MCP.
        let fps = SettingsRegistry.shared.setting(EsclopSettings.targetVideoFPS.key)
        #expect(fps?.schema["x-details"]?.stringValue == "-2 halves the source frame rate and -4 quarters it.")
    }
}
