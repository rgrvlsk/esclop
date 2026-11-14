// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EsclopCore
@testable import EsclopAppKit
import Foundation
import Testing

@MainActor
@Suite struct FormatTabTests {
    @Test func theFilesOwnFormatIsAlwaysATile() {
        let video = OptionsModel.formats(for: .video)
        #expect(FormatOptions.shownFormats(video, current: .mp4) == Array(video.prefix(4)))
        let mov = FormatOptions.shownFormats(video, current: .mov)
        #expect(mov.count == 4 && mov.last == .mov, "MOV is not among the first four, so it takes the last place")
        #expect(FormatOptions.shownFormats(video, current: nil) == Array(video.prefix(4)))
    }

    @Test func everyPictureAndVideoHasAQuality() {
        #expect(FormatOptions.hasQuality(.jpeg, kind: .image))
        #expect(FormatOptions.hasQuality(.png, kind: .image), "it sets how far PNG's colours are reduced")
        #expect(FormatOptions.hasQuality(.gif, kind: .image))
        #expect(FormatOptions.hasQuality(.mp4, kind: .video))
        #expect(!FormatOptions.hasQuality(nil, kind: .pdf))
        #expect(!FormatOptions.hasQuality(.aac, kind: .audio), "audio has its bitrate")
    }

    /// A video's tile arms; Convert runs it (owner's decision). Optimise harder is one action.
    @Test func aVideoTileArmsConvertAndHarderRunsAggressively() async throws {
        let harness = Harness()
        _ = await harness.model.run(harness.job(harness.temp.file("clip.mov", bytes: 100_000)))
        let card = try #require(harness.model.cards.first)
        let model = OptionsModel(card: card, app: harness.model)
        model.pick(.mp4, keepBoth: false)
        #expect(model.armed == .mp4)
        model.quality = 60
        model.commitQuality()
        #expect(harness.requests.requests.count == 1, "arming, and the quality while armed, run nothing")
        model.convertArmed()
        #expect(model.armed == nil)
        #expect(await eventually { harness.requests.requests.count == 2 && card.result != nil })
        #expect(harness.requests.requests.last?.format == .mp4)
        #expect(harness.requests.requests.last?.quality.factor == 40, "with the quality set while armed (factor = 100 − quality)")

        model.optimiseHarder()
        #expect(await eventually { harness.requests.requests.count == 3 && card.result != nil })
        #expect(harness.requests.requests.last?.quality.tier == .aggressive)
    }

    /// Rename moved from the popover's header to the detail's name.
    @Test func theDetailRenamesTheFile() async throws {
        let harness = Harness()
        _ = await harness.model.run(harness.job(harness.temp.file("IMG_0001.png", bytes: 100_000)))
        let card = try #require(harness.model.cards.first)
        harness.model.interact(card, .rename("Beach"))
        #expect(card.result?.output.lastPathComponent == "Beach.png")
        #expect(FileManager.default.fileExists(atPath: harness.temp.url.appendingPathComponent("Beach.png").path))
    }
}

@MainActor
@Suite struct FormatTabCurrentFormatTests {
    /// HEVC is written as .mp4: the HEVC tile, not MP4's, is the file's own.
    @Test func theChoiceNamesTheFormatItsExtensionShares() async throws {
        let harness = Harness()
        _ = await harness.model.run(harness.job(harness.temp.file("clip.mp4", bytes: 100_000)))
        let card = try #require(harness.model.cards.first)
        var choice = OptimiseChoice()
        choice.format = .hevc
        card.choice = choice
        #expect(OptionsModel(card: card, app: harness.model).currentFormat == .hevc)
        card.choice = OptimiseChoice()
        #expect(OptionsModel(card: card, app: harness.model).currentFormat == .mp4)
    }

    /// A video's GIF keeps the video, from the tile or from More formats.
    @Test func aVideosGIFKeepsTheVideo() async throws {
        let harness = Harness()
        _ = await harness.model.run(harness.job(harness.temp.file("clip.mov", bytes: 100_000)))
        let card = try #require(harness.model.cards.first)
        let model = OptionsModel(card: card, app: harness.model)
        model.pick(.gifVideo, keepBoth: false)
        #expect(model.armed == nil, "not armed: it runs, beside the video")
        #expect(await eventually { harness.requests.requests.count == 2 })
        #expect(harness.requests.requests.last?.location == .sameFolder, "a new file next to the video")
    }
}

@MainActor
@Suite struct SizeTabTests {
    func model(width: Int, height: Int) async throws -> (OptionsModel, Harness) {
        let harness = Harness()
        _ = await harness.model.run(harness.job(harness.temp.file("photo.png", bytes: 100_000)))
        let card = try #require(harness.model.cards.first)
        let model = OptionsModel(card: card, app: harness.model)
        model.facts = FileFacts(width: width, height: height)
        return (model, harness)
    }

    /// Original, 2000 px, 1280 px and half, with half's real pixels; nothing that enlarges.
    @Test func thePresetsComeFromTheRealSize() async throws {
        let (big, _) = try await model(width: 6000, height: 4000)
        #expect(big.sizePresets.map(\.title) == ["Original", "2000\u{00A0}px", "1280\u{00A0}px", "Half"])
        #expect(big.sizePresets.last?.spoken == "Half, 3000 px", "the owner: compute it from the real size: \(big.sizePresets.map(\.spoken))")
        #expect(abs((big.sizePresets[1].factor) - 2000.0 / 6000) < 0.0001)
        let photo = try await model(width: 4032, height: 3024).0
        #expect(photo.sizePresets.map(\.title) == ["Original", "2000\u{00A0}px", "1280\u{00A0}px"], "2000 px is already half: one tile")
        let small = try await model(width: 1600, height: 900).0
        #expect(small.sizePresets.map(\.title) == ["Original", "1280\u{00A0}px", "Half"], "never a tile larger than the picture")
        let tiny = try await model(width: 800, height: 600).0
        #expect(tiny.sizePresets.map(\.title) == ["Original", "Half"])
    }

    @Test func aTileScalesFromTheOriginal() async throws {
        let (model, harness) = try await model(width: 4032, height: 3024)
        model.scale(to: 0.5)
        #expect(await eventually { harness.requests.requests.count == 2 && model.card.result != nil })
        #expect(harness.requests.requests.last?.downscale == 0.5)
        #expect(model.currentScale == 0.5, "the Half tile is the chosen one")
        model.scale(to: 0.5)
        try await Task.sleep(for: .milliseconds(150))
        #expect(harness.requests.requests.count == 2, "the size it already has runs nothing")
        model.scale(to: 1.4)
        #expect(await eventually { harness.requests.requests.count == 3 && model.card.result != nil })
        #expect(harness.requests.requests.last?.downscale == nil, "never enlarges: back to the original's size")
        #expect(model.currentScale == 1)
    }

    /// A crop makes the file smaller, but it is not a scale: no size tile is chosen for it.
    @Test func aCropIsNotAScale() async throws {
        let (model, harness) = try await model(width: 4000, height: 2000)
        model.app.crop(model.card, to: CropSize(width: 2000, height: 2000))
        #expect(await eventually { harness.requests.requests.count == 2 && model.card.result != nil })
        #expect(model.currentScale == 1, "Original stays the chosen tile")
    }

    @Test func everyKindHasTheTabsItCanUse() {
        #expect(OptionsTab.tabs(for: .image) == [.optimise, .size, .crop, .share])
        #expect(OptionsTab.tabs(for: .audio) == [.optimise, .sound, .share])
        #expect(OptionsTab.share.title == "Actions" && OptionsTab.optimise.title == "Format")
    }
}
