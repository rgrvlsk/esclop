// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EsclopCore
@testable import EsclopAppKit
import Foundation
import Testing

@MainActor
@Suite struct LoupeTests {
    /// A 4032 × 3024 photo in the detail's 296 × 222 picture, on a Retina screen.
    let photo = LoupeGeometry(frame: CGSize(width: 296, height: 222), pixels: CGSize(width: 4032, height: 3024), scale: 2)

    @Test func theLensShowsTheFileAtTrueSize() {
        #expect(photo.zoom == 0.5, "one pixel of the file to one pixel of the screen")
        let small = LoupeGeometry(frame: photo.frame, pixels: CGSize(width: 400, height: 300), scale: 2)
        #expect(abs(small.zoom - 2 * 296 / 400) < 0.001, "a small file still magnifies twice")
        #expect(photo.diameter == 124, "about 40 % of the picture, as in the target")
    }

    @Test func thePointerIsAtTheLensRimAndWhatItPointsAtIsInTheCentre() {
        let pointer = CGPoint(x: 200, y: 150)
        let centre = photo.centre(pointer)
        #expect(centre.x < pointer.x && centre.y < pointer.y, "up and to the left")
        let distance = hypot(pointer.x - centre.x, pointer.y - centre.y)
        #expect(abs(distance - photo.diameter / 2) < 4, "on the rim: \(distance)")
        let content = photo.content(pointer)
        let under = CGPoint(x: (photo.diameter / 2 - content.minX) / content.width, y: (photo.diameter / 2 - content.minY) / content.height)
        #expect(abs(under.x - photo.unit(pointer).x) < 0.0001 && abs(under.y - photo.unit(pointer).y) < 0.0001)
    }

    @Test func theLensStaysInsideThePicture() {
        let radius = photo.diameter / 2
        for pointer in [CGPoint(x: 0, y: 0), CGPoint(x: 296, y: 222), CGPoint(x: 5, y: 220), CGPoint(x: 290, y: 3)] {
            let centre = photo.centre(pointer)
            #expect(centre.x - radius >= LoupeGeometry.margin && centre.x + radius <= 296 - LoupeGeometry.margin, "\(pointer)")
            #expect(centre.y - radius >= LoupeGeometry.margin + LoupeGeometry.label && centre.y + radius <= 222 - LoupeGeometry.margin, "\(pointer)")
        }
        let short = LoupeGeometry(frame: CGSize(width: 296, height: 120), pixels: CGSize(width: 4000, height: 1600), scale: 2)
        #expect(short.diameter + 2 * LoupeGeometry.margin + LoupeGeometry.label <= 120, "a short picture gets a smaller lens")
        #expect(short.unit(CGPoint(x: 148, y: 0)).y == 0, "off the picture, the lens shows its edge")
    }

    @Test func aClickSwapsAndAHoldSwapsBack() {
        var state = LoupeState()
        #expect(!state.showsOriginal && state.hint == "Click or hold to see original")
        state.pressed = true
        #expect(state.showsOriginal && state.hint == "Release to see optimised", "a press swaps at once")
        state.pressed = false
        #expect(!state.showsOriginal, "held: back on release")
        state.original = true
        #expect(state.showsOriginal && state.hint == "Click or hold to see optimised", "clicked: it stays")
        state.pressed = true
        #expect(!state.showsOriginal && state.hint == "Release to see original")
    }

    @Test func onlyAPictureThatLostDetailGetsTheLoupe() {
        #expect(CardPresentation.lossy(URL(fileURLWithPath: "/tmp/a.JPG")))
        #expect(CardPresentation.lossy(URL(fileURLWithPath: "/tmp/a.webp")))
        #expect(!CardPresentation.lossy(URL(fileURLWithPath: "/tmp/a.gif")))
        #expect(!CardPresentation.lossy(URL(fileURLWithPath: "/tmp/a.tiff")))

        func card(_ output: String, kind: MediaKind = .image) -> CardPresentation {
            let card = ResultCard(jobID: UUID(), source: URL(fileURLWithPath: "/tmp/in.\(output)"), origin: .dropZone, bytesBefore: 1000)
            card.phase = .done(OptimisationResult(
                source: card.source, output: URL(fileURLWithPath: "/tmp/in-optimised.\(output)"), kind: kind,
                bytesBefore: 1000, bytesAfter: 500, startedAt: Date(), finishedAt: Date()
            ))
            return card.presentation
        }
        #expect(card("jpg").loupe && card("jpg").menu.contains(.compare))
        #expect(!card("gif").loupe && !card("gif").menu.contains(.compare), "nothing to see in a lossless picture")
        #expect(!card("mp4", kind: .video).loupe && card("mp4", kind: .video).menu.contains(.compare), "a video compares in the window")
    }

    @Test func compareInTheDetailTurnsOnTheLoupeAndClosingEndsIt() async throws {
        let harness = Harness()
        var opened: [OptimisationResult] = []
        harness.model.onCompare = { opened.append($0) }
        _ = await harness.model.run(harness.job(harness.temp.file("photo.jpg", bytes: 100_000)))
        let card = try #require(harness.model.cards.first)
        try #require(card.loupeSides != nil, "the backup and the result are both there")

        harness.model.perform(.compare, on: card)
        #expect(card.loupe == nil && opened.count == 1, "from the thumbnail, the window")

        harness.model.perform(.openDetail, on: card)
        harness.model.perform(.compare, on: card)
        #expect(card.loupe == LoupeState() && opened.count == 1, "in the detail, the loupe")
        harness.model.perform(.closeDetail, on: card)
        #expect(card.loupe == nil)
        harness.model.perform(.openDetail, on: card)
        #expect(card.loupe == nil, "the detail opens without it")
    }
}
