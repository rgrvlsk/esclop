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
