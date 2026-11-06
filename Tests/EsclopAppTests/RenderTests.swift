// SPDX-License-Identifier: GPL-3.0-or-later
//
// Renders the result card states and the drop zone, light and dark, with ImageRenderer. Set
// ESCLOP_RENDER_DIR to keep the PNGs (they go with UI pull requests); otherwise they land in a
// temporary folder and the test only checks that every state draws at the designed width.

import AppKit
import EsclopCore
@testable import EsclopAppKit
import SwiftUI
import Testing

@MainActor
@Suite struct RenderTests {
    static let folder: URL = {
        if let path = ProcessInfo.processInfo.environment["ESCLOP_RENDER_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("esclop-renders-\(UUID().uuidString)", isDirectory: true)
    }()

    /// A stand-in screenshot thumbnail: a window on a desktop, drawn, not captured.
    static let thumbnail: NSImage = {
        let size = NSSize(width: 88, height: 88)
        return NSImage(size: size, flipped: false) { rect in
            NSGradient(starting: Palette.color(0x5B7FA6), ending: Palette.color(0x9DB8C9))?.draw(in: rect, angle: 70)
            let window = NSBezierPath(roundedRect: NSRect(x: 14, y: 16, width: 60, height: 50), xRadius: 5, yRadius: 5)
            NSColor.white.withAlphaComponent(0.92).setFill()
            window.fill()
            NSColor(white: 0.85, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 14, y: 58, width: 60, height: 8)).fill()
            for (index, width) in [40, 30, 44].enumerated() {
                NSColor(white: 0.75, alpha: 1).setFill()
                NSBezierPath(rect: NSRect(x: 20, y: 46 - index * 9, width: width, height: 4)).fill()
            }
            return true
        }
    }()

    func card(_ phase: ResultCard.Phase, name: String = "Screenshot 2026-11-05 at 10.42.png", aggressive: Bool = false, hovered: Bool = false) -> ResultCard {
        let card = ResultCard(jobID: UUID(), source: URL(fileURLWithPath: "/tmp/\(name)"), origin: .clipboard, aggressive: aggressive, bytesBefore: 1_240_000, phase: phase)
        card.thumbnail = Self.thumbnail
        card.hasPlayedArrival = true
        card.isHovered = hovered
        return card
    }

    func saved(after: Int = 312_000) -> OptimisationResult {
        OptimisationResult(
            source: URL(fileURLWithPath: "/tmp/Screenshot 2026-11-05 at 10.42.png"),
            output: URL(fileURLWithPath: "/tmp/Screenshot 2026-11-05 at 10.42.png"),
            backup: URL(fileURLWithPath: "/tmp/backup.png"), kind: .image,
            bytesBefore: 1_240_000, bytesAfter: after, startedAt: Date(), finishedAt: Date()
        )
    }

    @discardableResult
    func render(_ view: some View, name: String, scheme: ColorScheme) throws -> CGSize {
        let backdrop = scheme == .dark ? Palette.color(0x2B2E33) : Palette.color(0xDCE1E6)
        let framed = view
            .padding(24)
            .background(Color(nsColor: backdrop))
            .environment(\.panelBackdrop, .flat)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        let image = try #require(renderer.cgImage, "\(name) did not render")
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: Self.folder.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
        return CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func resultCardStates(scheme: ColorScheme) throws {
        let states: [(String, ResultCard)] = [
            ("card-in-progress", card(.working(fraction: 0.45))),
            ("card-saved", card(.done(saved()))),
            ("card-saved-hover", card(.done(saved()), hovered: true)),
            ("card-saved-harder", card(.done(saved(after: 188_000)), aggressive: true)),
            ("card-already-smaller", card(.unchanged(bytes: 41_200), name: "icon.png")),
            ("card-error", card(.failed("ffmpeg is missing. Reinstall L'Esclop or run Scripts/build-tools.sh."), name: "Recording 2026-11-05.mov")),
        ]
        for (name, card) in states {
            let size = try render(ResultCardView(card: card) { _ in }, name: name, scheme: scheme)
            #expect(size.width == Metrics.cardWidth + 48, "\(name) keeps the 300 pt card width")
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func dropZone(scheme: ColorScheme) throws {
        try render(DropZoneView(state: DropZoneState(fileCount: 3)), name: "drop-zone", scheme: scheme)
        try render(DropZoneView(state: DropZoneState(fileCount: 3, hovering: true)), name: "drop-zone-hover", scheme: scheme)
        try render(DropZoneView(state: DropZoneState(fileCount: 1, hovering: true, harder: true)), name: "drop-zone-harder", scheme: scheme)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func menuBarGlyph(scheme: ColorScheme) throws {
        let glyph = try #require(MenuBarLabel.customGlyph, "MenuBarIcon.pdf ships in the module's resources")
        #expect(glyph.isTemplate, "macOS tints it for the menu bar")
        #expect(glyph.size.height == 18)
        let bar = scheme == .dark ? Color(white: 0.17) : Color(white: 0.93)
        let running = MenuBarLabel(model: Harness().model)
        let pausedModel = Harness().model
        pausedModel.pauseChanged(true)
        let paused = MenuBarLabel(model: pausedModel)
        try renderBar(HStack(spacing: 22) { running; paused }, background: bar, name: "menu-bar-glyph", scheme: scheme)
    }

    /// A strip like the menu bar: 24 pt high, the glyph at its real size, rendered at 2x.
    func renderBar(_ view: some View, background: Color, name: String, scheme: ColorScheme) throws {
        let renderer = ImageRenderer(content: view.padding(.horizontal, 12).frame(height: 24).background(background).environment(\.colorScheme, scheme))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: Self.folder.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func stackOfCards(scheme: ColorScheme) throws {
        let harness = Harness()
        harness.model.add(card(.done(saved())))
        harness.model.add(card(.working(fraction: 0.7), name: "Recording 2026-11-05.mov"))
        try render(FloatingStackView(model: harness.model), name: "stack", scheme: scheme)
    }
}
