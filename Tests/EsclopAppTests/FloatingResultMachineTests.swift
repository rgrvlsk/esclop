// SPDX-License-Identifier: GPL-3.0-or-later
//
// The floating result's state machine on a clock the tests move by hand: levels, the 600 ms dwell
// against a plain pass, the two-second activity rule and what pauses the auto-hide.

@testable import EsclopAppKit
import Foundation
import Testing

@Suite struct FloatingResultMachineTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func finished(hideAfter: TimeInterval? = 10) -> FloatingResultMachine {
        var machine = FloatingResultMachine(expectedDuration: 0.5)
        machine.finished(at: at(0), hideAfter: hideAfter)
        return machine
    }

    @Test func aStillPointerOpensTheDetailAfter600ms() {
        var machine = finished()
        machine.pointerEntered(at: at(1))
        #expect(machine.showsHoverButtons)
        #expect(machine.nextDeadline == at(1.6))
        _ = machine.advance(to: at(1.59))
        #expect(machine.level == .thumbnail)
        _ = machine.advance(to: at(1.6))
        #expect(machine.level == .detail)
        #expect(!machine.showsHoverButtons, "the detail replaces the buttons")
    }

    @Test func aPlainPassOnlyShowsTheButtons() {
        var machine = finished()
        machine.pointerEntered(at: at(1))
        machine.pointerMoved(at: at(1.3))
        machine.pointerMoved(at: at(1.55))
        _ = machine.advance(to: at(1.8))
        #expect(machine.level == .thumbnail, "the pointer kept moving")
        machine.pointerExited(at: at(1.9))
        #expect(machine.showsHoverButtons, "crossing the gap to the buttons keeps them")
        _ = machine.advance(to: at(2.1))
        #expect(!machine.showsHoverButtons)
        #expect(machine.level == .thumbnail)
    }

    @Test func restingOnAButtonNeverOpensTheDetail() {
        var machine = finished()
        machine.pointerEntered(at: at(1))
        machine.pointerExited(at: at(1.2))
        machine.pointerEnteredButtons(at: at(1.25))
        _ = machine.advance(to: at(5))
        #expect(machine.level == .thumbnail)
        #expect(machine.showsHoverButtons)
    }

    @Test func noDetailOrButtonsWhileWorkingOrFailed() {
        var machine = FloatingResultMachine(expectedDuration: 0.5)
        machine.pointerEntered(at: at(0))
        #expect(!machine.showsHoverButtons)
        #expect(machine.nextDeadline == nil)
        #expect(machine.capsuleClicked(at: at(0.1)) == nil)
        #expect(machine.level == .thumbnail)
        machine.failed(at: at(1), hideAfter: 10)
        #expect(machine.capsuleClicked(at: at(1.1)) == .retry, "clicking an error's capsule retries")
        _ = machine.advance(to: at(3))
        #expect(machine.level == .thumbnail)
    }

    @Test func theCapsuleOpensAndTheCloseButtonClosesTheDetail() {
        var machine = finished()
        #expect(machine.capsuleClicked(at: at(1)) == nil)
        #expect(machine.level == .detail)
        machine.closeDetail(at: at(2))
        #expect(machine.level == .thumbnail)
    }

    @Test func onlyJobsExpectedToTakeOverTwoSecondsGetTheActivityCapsule() {
        #expect(FloatingResultMachine(expectedDuration: 2).activity == .hidden)
        var long = FloatingResultMachine(expectedDuration: 2.1)
        #expect(long.activity == .running)
        long.finished(at: at(12), hideAfter: 30)
        #expect(long.activity == .finished(until: at(14)), "it shows the result for two seconds")
        _ = long.advance(to: at(13.9))
        #expect(long.activity == .finished(until: at(14)))
        _ = long.advance(to: at(14))
        #expect(long.activity == .hidden, "then retracts")

        var refined = FloatingResultMachine(expectedDuration: 6)
        refined.estimateChanged(1.2)
        #expect(refined.activity == .hidden, "the frames said it is quick after all")
        refined.estimateChanged(20)
        #expect(refined.activity == .running)

        var failing = FloatingResultMachine(expectedDuration: 30)
        failing.failed(at: at(3), hideAfter: 10)
        #expect(failing.activity == .hidden)
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
        case "hover": machine.pointerEnteredButtons(at: at(1))
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
        #expect(machine.hideDeadline == at(62.2), "the time ran out meanwhile: it goes two seconds later")
        #expect(machine.advance(to: at(62.1)) == nil)
        #expect(machine.advance(to: at(62.2)) == .dismiss)
    }

    @Test func aPauseThatEndsInTimeKeepsTheOriginalDeadline() {
        var machine = finished(hideAfter: 10)
        machine.pointerEntered(at: at(1))
        machine.pointerExited(at: at(2))
        _ = machine.advance(to: at(2.2))
        #expect(machine.hideDeadline == at(10))
    }

    @Test func dragsAndTheMenuStopTheDwell() {
        var machine = finished()
        machine.pointerEntered(at: at(1))
        machine.setDragging(true, at: at(1.2))
        _ = machine.advance(to: at(2))
        #expect(machine.level == .thumbnail, "dragging the file out is not a still hover")
        machine.setDragging(false, at: at(3))
        machine.setMenuOpen(true, at: at(3))
        machine.pointerMoved(at: at(3.1))
        _ = machine.advance(to: at(4))
        #expect(machine.level == .thumbnail)
        #expect(machine.showsHoverButtons, "the buttons stay while the popover is open")
    }

    @Test func noticesHaveNoDetailAndHideAfterTheirTime() {
        var machine = FloatingResultMachine(expectedDuration: 0)
        machine.notice(at: at(0), hideAfter: 3)
        machine.pointerEntered(at: at(0.5))
        #expect(!machine.showsHoverButtons)
        #expect(machine.capsuleClicked(at: at(0.6)) == nil)
        #expect(machine.level == .thumbnail)
        machine.pointerExited(at: at(1))
        _ = machine.advance(to: at(1.5))
        #expect(machine.advance(to: at(3)) == .dismiss)
    }
}
