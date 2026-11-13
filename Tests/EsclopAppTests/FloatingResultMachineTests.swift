// SPDX-License-Identifier: GPL-3.0-or-later
//
// The floating result's state machine on a clock the tests move by hand: levels, the hover
// buttons and what pauses the auto-hide.

@testable import EsclopAppKit
import Foundation
import Testing

@Suite struct FloatingResultMachineTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func finished(hideAfter: TimeInterval? = 10) -> FloatingResultMachine {
        var machine = FloatingResultMachine()
        machine.finished(at: at(0), hideAfter: hideAfter)
        return machine
    }

    @Test func aRestingPointerOnlyShowsTheButtons() {
        var machine = finished()
        machine.pointerEntered(at: at(1))
        #expect(machine.showsHoverButtons)
        #expect(machine.nextDeadline == nil, "nothing is timed while it is hovered")
        _ = machine.advance(to: at(5))
        #expect(machine.level == .thumbnail, "only a click, Return or Space opens the detail")
        machine.pointerExited(at: at(5.1))
        #expect(machine.showsHoverButtons, "crossing the gap to the buttons keeps them")
        _ = machine.advance(to: at(5.3))
        #expect(!machine.showsHoverButtons)
    }

    @Test func noDetailOrButtonsWhileWorkingOrFailed() {
        var machine = FloatingResultMachine()
        machine.pointerEntered(at: at(0))
        #expect(!machine.showsHoverButtons)
        #expect(machine.nextDeadline == nil)
        machine.openDetail(at: at(0.1))
        #expect(machine.level == .thumbnail, "no detail while working")
        machine.failed(at: at(1), hideAfter: 10)
        machine.openDetail(at: at(1.1))
        _ = machine.advance(to: at(3))
        #expect(machine.level == .thumbnail)
    }

    @Test func aClickOpensAndTheCloseButtonClosesTheDetail() {
        var machine = finished()
        machine.openDetail(at: at(1))
        #expect(machine.level == .detail)
        machine.closeDetail(at: at(2))
        #expect(machine.level == .thumbnail)
    }

    @Test func theEstimateDecidesWhichJobsAreLong() {
        #expect(JobEstimate.expectedSeconds(kind: .image, bytes: 5_000_000, aggressive: false) < 2)
        #expect(JobEstimate.expectedSeconds(kind: .video, bytes: 148_000_000, aggressive: false) > 2)
        #expect(JobEstimate.expectedSeconds(kind: .video, bytes: 1_000_000, aggressive: false) < 2)
        // From the frames, as measured: a short 1080p clip is quick, a long retina recording is not.
        #expect(JobEstimate.videoSeconds(width: 1920, height: 1080, fps: 30, duration: 12, aggressive: false) < 2)
        #expect(JobEstimate.videoSeconds(width: 2880, height: 1800, fps: 60, duration: 40, aggressive: false) > 15)
        #expect(JobEstimate.expectedSeconds(kind: .pdf, bytes: 20_000_000, aggressive: false) > 2)
        #expect(JobEstimate.expectedSeconds(kind: .image, bytes: 30_000_000, aggressive: true) > 2)
        #expect(JobEstimate.secondsLeft(elapsed: 4, fraction: 0.25, expected: 50) == 12, "progress wins once there is some")
        #expect(JobEstimate.secondsLeft(elapsed: 1, fraction: -1, expected: 13) == 12)
        #expect(JobEstimate.secondsLeft(elapsed: 20, fraction: -1, expected: 13) == 1, "never zero or negative")
    }

    @Test func itHidesOnItsOwn() {
        var machine = finished(hideAfter: 10)
        #expect(machine.nextDeadline == at(10))
        #expect(machine.advance(to: at(9.9)) == nil)
        #expect(machine.advance(to: at(10)) == .dismiss)

        var never = finished(hideAfter: nil)
        #expect(never.nextDeadline == nil)
        #expect(never.advance(to: at(3600)) == nil)
    }

    @Test(arguments: ["hover", "focus", "drag", "menu", "detail"])
    func dismissalPausesWhileHoveredFocusedDraggedOrOpen(reason: String) {
        var machine = finished(hideAfter: 10)
        switch reason {
        case "hover": machine.pointerEntered(at: at(1))
        case "focus": machine.setFocused(true, at: at(1))
        case "drag": machine.setDragging(true, at: at(1))
        case "menu": machine.setMenuOpen(true, at: at(1))
        default: machine.openDetail(at: at(1))
        }
        #expect(machine.isDismissalPaused)
        #expect(machine.advance(to: at(60)) == nil, "\(reason) keeps it")

        switch reason {
        case "hover":
            machine.pointerExited(at: at(60))
            _ = machine.advance(to: at(60.2))
        case "focus": machine.setFocused(false, at: at(60.2))
        case "drag": machine.setDragging(false, at: at(60.2))
        case "menu": machine.setMenuOpen(false, at: at(60.2))
        default: machine.closeDetail(at: at(60.2))
        }
        // A detail closed by hand gets the whole delay again (UI check, F8); the rest go two
        // seconds later, since the time ran out meanwhile.
        let left: TimeInterval = reason == "detail" ? 10 : 2
        #expect(machine.hideDeadline == at(60.2 + left))
        #expect(machine.advance(to: at(60.1 + left)) == nil)
        #expect(machine.advance(to: at(60.2 + left)) == .dismiss)
    }

    @Test func aPauseThatEndsInTimeKeepsTheOriginalDeadline() {
        var machine = finished(hideAfter: 10)
        machine.pointerEntered(at: at(1))
        machine.pointerExited(at: at(2))
        _ = machine.advance(to: at(2.2))
        #expect(machine.hideDeadline == at(10))
    }

    @Test func theButtonsStayWhileThePopoverIsOpen() {
        var machine = finished()
        machine.pointerEntered(at: at(1))
        machine.setMenuOpen(true, at: at(3))
        machine.pointerExited(at: at(3.1))
        _ = machine.advance(to: at(4))
        #expect(machine.showsHoverButtons, "the popover keeps its anchor")
    }

    @Test func noticesHaveNoDetailAndHideAfterTheirTime() {
        var machine = FloatingResultMachine()
        machine.notice(at: at(0), hideAfter: 3)
        machine.pointerEntered(at: at(0.5))
        #expect(!machine.showsHoverButtons)
        machine.openDetail(at: at(0.6))
        #expect(machine.level == .thumbnail)
        machine.pointerExited(at: at(1))
        _ = machine.advance(to: at(1.5))
        #expect(machine.advance(to: at(3)) == .dismiss)
    }
}
