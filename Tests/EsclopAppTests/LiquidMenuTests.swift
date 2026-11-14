// SPDX-License-Identifier: GPL-3.0-or-later

@testable import EsclopAppKit
import AppKit
import SwiftUI
import Testing

/// The detail's "…" menu: its outline, where it opens, and how it closes.
@MainActor
@Suite struct LiquidMenuTests {
    let button = CGRect(x: 300, y: 500, width: 30, height: 30)
    let card = CGRect(x: 290, y: 100, width: 320, height: 450)

    @Test func theDropLeavesTheButtonAndSpreadsIntoThePanel() {
        let panel = LiquidMenu.panel(button: button, card: card, count: 3, leftward: true)
        let closed = LiquidMenuShape.outline(button: button, panel: panel, progress: 0, radius: LiquidMenu.radius)
        #expect(closed.boundingBoxOfPath.insetBy(dx: -0.5, dy: -0.5).contains(button), "closed, it is the button")
        #expect(button.insetBy(dx: -0.5, dy: -0.5).contains(closed.boundingBoxOfPath))
        let open = LiquidMenuShape.outline(button: button, panel: panel, progress: 1, radius: LiquidMenu.radius)
        #expect(open.boundingBoxOfPath.insetBy(dx: -0.5, dy: -0.5).contains(panel.union(button)))
        // The neck: filled on the line from the button to the panel, thinner than the button.
        let gapMiddle = CGPoint(x: (panel.maxX + button.minX) / 2, y: button.midY)
        #expect(open.contains(gapMiddle))
        #expect(!open.contains(CGPoint(x: gapMiddle.x, y: button.midY - button.height / 2 + 1)), "the neck pinches")
    }

    @Test func theDropStaysJoinedToTheButtonAllTheWay() {
        let button = CGRect(x: 570, y: 500, width: 30, height: 30)
        let panel = LiquidMenu.panel(button: button, card: card, count: 8, leftward: false)
        for step in 1 ... 55 {
            let progress = CGFloat(step) / 50
            let outline = LiquidMenuShape.outline(button: button, panel: panel, progress: progress, radius: LiquidMenu.radius)
            let drop = LiquidMenuShape.panel(button: button, panel: panel, progress: progress)
            guard drop.minX > button.maxX else { continue }
            let between = CGPoint(x: (button.maxX + drop.minX) / 2, y: button.midY)
            #expect(outline.contains(between), "joined at progress \(progress)")
        }
    }

    @Test func itOpensTowardTheScreenBesideTheCard() {
        let left = LiquidMenu.panel(button: button, card: card, count: 3, leftward: true)
        #expect(left.maxX == card.minX - LiquidMenu.outside)
        let right = LiquidMenu.panel(button: CGRect(x: 570, y: 500, width: 30, height: 30), card: card, count: 3, leftward: false)
        #expect(right.minX == card.maxX + LiquidMenu.outside)
        // Centred on "…" where it fits; never below the card, never above it.
        let long = LiquidMenu.panel(button: button, card: card, count: 8, leftward: true)
        #expect(long.maxY == card.maxY)
        let huge = LiquidMenu.panel(button: button, card: card, count: 20, leftward: true)
        #expect(huge.minY == card.minY)
    }

    @Test func theStackMakesRoomForTheOpenMenu() async throws {
        let harness = Harness()
        _ = await harness.model.run(harness.job(harness.temp.file("a.png", bytes: 100_000)))
        let card = try #require(harness.model.cards.first)
        harness.model.interact(card, .openDetail)
        let closed = NSHostingView(rootView: FloatingStackView(model: harness.model)).fittingSize
        harness.model.interact(card, .menu(true))
        let open = NSHostingView(rootView: FloatingStackView(model: harness.model)).fittingSize
        #expect(open.width == closed.width + LiquidMenu.room)
        #expect(open.height == closed.height)
    }

    @Test func convertOpensTheOptions() async throws {
        let harness = Harness()
        _ = await harness.model.run(harness.job(harness.temp.file("a.png", bytes: 100_000)))
        let card = try #require(harness.model.cards.first)
        harness.model.interact(card, .openDetail)
        card.optionsTab = .share
        harness.model.perform(.convertOptions, on: card)
        #expect(card.optionsTab == .optimise)
        #expect(card.machine.menuOpen && card.machine.level == .thumbnail, "the popover opens on the card")
    }

    @Test func closingTheDetailClosesItsMenu() async throws {
        let harness = Harness()
        _ = await harness.model.run(harness.job(harness.temp.file("a.png", bytes: 100_000)))
        let card = try #require(harness.model.cards.first)
        harness.model.interact(card, .openDetail)
        harness.model.interact(card, .menu(true))
        card.menuHighlight = 2
        harness.model.interact(card, .closeDetail)
        #expect(!card.machine.menuOpen)
        harness.model.interact(card, .openDetail)
        harness.model.interact(card, .menu(true))
        #expect(card.menuHighlight == nil, "it opens with nothing highlighted")
    }
}
