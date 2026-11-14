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

    @Test func onlyLossyFormatsHaveAQuality() {
        #expect(FormatOptions.hasQuality(.jpeg, kind: .image))
        #expect(FormatOptions.hasQuality(.webp, kind: .image))
        #expect(!FormatOptions.hasQuality(.png, kind: .image), "PNG is quantised by compression, not by a quality")
        #expect(!FormatOptions.hasQuality(.gif, kind: .image))
        #expect(FormatOptions.hasQuality(.mp4, kind: .video))
        #expect(!FormatOptions.hasQuality(nil, kind: .pdf))
    }

    /// A video's tile arms; Convert runs it (owner's decision). Optimise harder is one action.
    @Test func aVideoTileArmsConvertAndHarderRunsAggressively() async throws {
        let harness = Harness()
        _ = await harness.model.run(harness.job(harness.temp.file("clip.mov", bytes: 100_000)))
        let card = try #require(harness.model.cards.first)
        let model = OptionsModel(card: card, app: harness.model)
        model.armed = .mp4
        #expect(harness.requests.requests.count == 1, "arming runs nothing")
        model.convertArmed()
        #expect(model.armed == nil)
        #expect(await eventually { harness.requests.requests.count == 2 && card.result != nil })
        #expect(harness.requests.requests.last?.format == .mp4)

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
