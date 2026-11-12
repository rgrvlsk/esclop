// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
@testable import EsclopAppKit
import Foundation
import SwiftUI
import Testing

@Suite struct DesignTokenTests {
    @Test func theFigureWritesPercentagesAsTheLocaleDoes() {
        let english = Figure.percentParts(75, locale: Locale(identifier: "en_GB"))
        #expect(english == Figure.Parts(number: "\u{2212}75", unit: "%", text: "\u{2212}75%"))
        let catalan = Figure.percentParts(75, locale: Locale(identifier: "ca_ES"))
        #expect(catalan == Figure.Parts(number: "\u{2212}75", unit: "%", text: "\u{2212}75\u{202F}%"))
        // Nothing saved has no sign.
        #expect(Figure.percentParts(0, locale: Locale(identifier: "en_GB")).text == "0%")
    }

    @Test func theFigureSplitsBytesIntoNumberAndUnit() {
        let parts = Figure.byteParts(38_000_000)
        #expect(parts.number.hasPrefix("\u{2212}38"))
        #expect(parts.unit == "MB")
        #expect(parts.text.hasPrefix(parts.number) && parts.text.hasSuffix("MB"))
    }

    @Test func theFigureHasFourSizes() {
        #expect(Figure.Size.allCases.map(\.rawValue) == [24, 32, 48, 72])
    }

    @Test func inkIsPinnedAndRisesUnderIncreaseContrast() {
        #expect(Ink.text.opacity(dark: false) == 0.88)
        #expect(Ink.text.opacity(dark: true) == 0.92)
        #expect(Ink.text.opacity(dark: true, increasedContrast: true) == 0.92)
        #expect(Ink.secondary.opacity(dark: false) == 0.62)
        #expect(Ink.secondary.opacity(dark: false, increasedContrast: true) == 0.80)
        #expect(Ink.secondary.opacity(dark: true, increasedContrast: true) == 0.80)
        #expect([NeutralFill.resting, NeutralFill.button, NeutralFill.pressed].map { $0.opacity(dark: false) } == [0.06, 0.14, 0.20])
    }

    @Test func radiiAreConcentric() {
        // Outer = inner + padding: the card around its picture, a panel around its children.
        #expect(Radius.card == Radius.inner + Spacing.xs)
        #expect(Radius.panel == Radius.inner + Spacing.m)
        #expect(Spacing.hit >= 28)
    }

    /// White text on a lit tile holds 4.5:1 in both appearances: the fill is one colour.
    @Test func litTilesHoldWhiteText() {
        for fill in [RGBA(0x0A60D8), RGBA(0x8F5510)] {
            #expect(RGBA.contrast(.white, fill) >= 4.5)
        }
    }

    @Test func colourlessPicturesKeepTheNeutralShadow() throws {
        func image(_ color: NSColor) throws -> CGImage {
            let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            return try #require(context.makeImage())
        }
        #expect(PictureTone.of(try image(NSColor(white: 0.9, alpha: 1)), dark: false) == nil)
        #expect(PictureTone.of(try image(NSColor(srgbRed: 0.85, green: 0.4, blue: 0.3, alpha: 1)), dark: false) != nil)
    }
}

@MainActor
@Suite struct SnapshotBurstTests {
    @Test func aBurstComesFromTheRequestAndIsBounded() {
        #expect(WindowSnapshots.Burst.from(nil) == nil)
        #expect(WindowSnapshots.Burst.from(["frames": 1]) == nil, "one frame is a snapshot")
        #expect(WindowSnapshots.Burst.from(["frames": NSNumber(value: 30), "interval": NSNumber(value: 16)]) == .init(frames: 30, interval: 16))
        #expect(WindowSnapshots.Burst.from(["frames": "12", "interval": " 50 "]) == .init(frames: 12, interval: 50))
        #expect(WindowSnapshots.Burst.from(["frames": 5])?.interval == 33)
        #expect(WindowSnapshots.Burst.from(["frames": 100_000, "interval": 1]) == .init(frames: 240, interval: 8))
        #expect(WindowSnapshots.Burst.from(["frames": 3, "interval": 999_999])?.interval == 2000)
        #expect(WindowSnapshots.Burst.from(["frames": "many"]) == nil)
    }
}
