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
        #expect(Ink.secondary.hex(dark: false) == 0x625C56)
        #expect(Ink.secondary.hex(dark: true) == 0xB9AFA5)
        // Under Increase Contrast secondary moves away from the surface.
        let cream = (light: RGBA(0xF6F0E8), dark: RGBA(0x2B2521))
        #expect(RGBA.contrast(RGBA(Ink.secondary.hex(dark: false, increasedContrast: true)), cream.light) > RGBA.contrast(RGBA(Ink.secondary.hex(dark: false)), cream.light))
        #expect(RGBA.contrast(RGBA(Ink.secondary.hex(dark: true, increasedContrast: true)), cream.dark) > RGBA.contrast(RGBA(Ink.secondary.hex(dark: true)), cream.dark))
        #expect([NeutralFill.resting, NeutralFill.button, NeutralFill.pressed].map { $0.opacity(dark: false) } == [0.06, 0.14, 0.20])
    }

    /// The app's accent colour, compiled into the bundle for `NSAccentColorName`, is the charcoal
    /// token: switches, checkboxes and default buttons are never the system blue.
    @Test func theAccentColourIsCharcoal() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("assets/Accent.xcassets/AccentColor.colorset/Contents.json"))
        struct Catalog: Decodable {
            struct Entry: Decodable {
                struct Appearance: Decodable { var value: String }
                struct Value: Decodable { var components: [String: String] }
                var appearances: [Appearance]?
                var color: Value
            }
            var colors: [Entry]
        }
        func hex(_ entry: Catalog.Entry) -> UInt32 {
            ["red", "green", "blue"].reduce(0) { $0 << 8 | UInt32(entry.color.components[$1]!.dropFirst(2), radix: 16)! }
        }
        let colors = try JSONDecoder().decode(Catalog.self, from: data).colors
        let light = try #require(colors.first { $0.appearances == nil })
        let dark = try #require(colors.first { $0.appearances?.first?.value == "dark" })
        let token = NSColor(Ink.charcoal)
        for (entry, appearance) in [(light, NSAppearance.Name.aqua), (dark, .darkAqua)] {
            var resolved = RGBA(0)
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                let c = token.usingColorSpace(.sRGB)!
                resolved = RGBA(UInt32((c.redComponent * 255).rounded()) << 16 | UInt32((c.greenComponent * 255).rounded()) << 8 | UInt32((c.blueComponent * 255).rounded()))
            }
            #expect(resolved == RGBA(hex(entry)), "\(appearance.rawValue)")
        }
        let plist = try String(contentsOf: root.appendingPathComponent("Scripts/templates/Info.plist.in"), encoding: .utf8)
        #expect(plist.contains("<key>NSAccentColorName</key>\n\t<string>AccentColor</string>"))
    }

    @Test func theGaugeRunsFromTheOriginalToTheNewSize() {
        #expect(SavingGauge.dotAngle(saved: 0, shape: .ring) == -90)
        #expect(SavingGauge.dotAngle(saved: 0.75, shape: .ring) == 180)
        #expect(SavingGauge.dotAngle(saved: 2, shape: .ring) == 270, "clamped")
        #expect(SavingGauge.dotAngle(saved: 0, shape: .arc) == 200)
        #expect(SavingGauge.dotAngle(saved: 1, shape: .arc) == 340)
    }

    @Test func radiiAreConcentric() {
        // Outer = inner + padding: the card around its picture, a panel around its children.
        #expect(Radius.card == Radius.inner + Spacing.xs)
        #expect(Radius.panel == Radius.inner + Spacing.m)
        #expect(Spacing.hit >= 28)
    }

    /// White on charcoal, in both appearances.
    @Test func charcoalHoldsWhiteText() {
        for fill in [RGBA(0x36322E), RGBA(0x7A7068)] {
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
