// SPDX-License-Identifier: GPL-3.0-or-later
//
// Renders the floating result's states and the drop zone, light and dark, with ImageRenderer. Set
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

    /// A stand-in screenshot: a window with a picture of hills, drawn, not captured.
    static let screenshot: NSImage = {
        let size = NSSize(width: 400, height: 260)
        return NSImage(size: size, flipped: true) { rect in
            NSColor(white: 0.97, alpha: 1).setFill()
            rect.fill()
            NSColor(white: 0.9, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: 22).fill()
            for (index, color) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
                Palette.color(UInt32(color)).setFill()
                NSBezierPath(ovalIn: NSRect(x: 10 + index * 16, y: 6, width: 10, height: 10)).fill()
            }
            NSColor(white: 0.93, alpha: 1).setFill()
            NSRect(x: 0, y: 22, width: 84, height: rect.height - 22).fill()
            for row in 0 ..< 5 {
                NSColor(white: 0.78, alpha: 1).setFill()
                NSRect(x: 14, y: 40 + row * 18, width: 50, height: 5).fill()
            }
            NSColor(white: 0.2, alpha: 1).setFill()
            NSRect(x: 104, y: 38, width: 140, height: 9).fill()
            let frame = NSRect(x: 104, y: 62, width: 276, height: 150)
            Palette.color(0xB7D3CB).setFill()
            frame.fill()
            let back = NSBezierPath()
            back.move(to: NSPoint(x: frame.minX, y: frame.maxY))
            back.line(to: NSPoint(x: frame.minX + 90, y: frame.minY + 40))
            back.line(to: NSPoint(x: frame.minX + 170, y: frame.minY + 95))
            back.line(to: NSPoint(x: frame.maxX, y: frame.minY + 30))
            back.line(to: NSPoint(x: frame.maxX, y: frame.maxY))
            Palette.color(0x5F9686).setFill()
            back.fill()
            let front = NSBezierPath()
            front.move(to: NSPoint(x: frame.minX, y: frame.maxY))
            front.line(to: NSPoint(x: frame.minX + 150, y: frame.minY + 85))
            front.line(to: NSPoint(x: frame.maxX, y: frame.maxY - 10))
            front.line(to: NSPoint(x: frame.maxX, y: frame.maxY))
            Palette.color(0x2F6A5A).setFill()
            front.fill()
            NSColor(white: 0.85, alpha: 1).setFill()
            NSRect(x: 104, y: 226, width: 200, height: 6).fill()
            return true
        }
    }()

    static let video = URL(fileURLWithPath: "/tmp/Screen Recording 2026-11-05 at 10.42.mov")
    static let shot = URL(fileURLWithPath: "/tmp/Screenshot 2026-11-05 at 10.42.png")

    func card(_ phase: ResultCard.Phase, source: URL = Self.shot, bytes: Int = 2_400_000, aggressive: Bool = false) -> ResultCard {
        let card = ResultCard(jobID: UUID(), source: source, origin: .clipboard, aggressive: aggressive, bytesBefore: bytes)
        card.thumbnail = Self.screenshot
        card.originalThumbnail = Self.screenshot
        card.hasPlayedArrival = true
        set(card, phase)
        return card
    }

    func set(_ card: ResultCard, _ phase: ResultCard.Phase) {
        card.phase = phase
        switch phase {
        case .working: break
        case .failed: card.machine.failed(at: Date(), hideAfter: nil)
        case .notice: card.machine.notice(at: Date(), hideAfter: 3)
        default: card.machine.finished(at: Date(), hideAfter: nil)
        }
    }

    func saved(_ source: URL = Self.shot, before: Int = 2_400_000, after: Int = 612_000, kind: MediaKind = .image) -> OptimisationResult {
        var result = OptimisationResult(
            source: source, output: source, backup: URL(fileURLWithPath: "/tmp/backup"), kind: kind,
            bytesBefore: before, bytesAfter: after, startedAt: Date(), finishedAt: Date()
        )
        result.width = 2940
        result.height = 1912
        if kind == .video { result.duration = 37 }
        return result
    }

    @discardableResult
    func render(_ view: some View, name: String, scheme: ColorScheme) throws -> CGSize {
        // A desktop like the prototype's, so the glass stand-in reads as it does on screen.
        let desktop = scheme == .dark
            ? [Palette.color(0x1E3A47), Palette.color(0x0F2230)]
            : [Palette.color(0x7FA3B5), Palette.color(0x3C6680)]
        let framed = view
            .padding(EdgeInsets(top: 52, leading: 24, bottom: 24, trailing: 24))
            .background(LinearGradient(colors: desktop.map { Color(nsColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing))
            .environment(\.panelBackdrop, .flat)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        let image = try #require(renderer.cgImage, "\(name) did not render")
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: Self.folder.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
        return CGSize(width: CGFloat(image.width) / 2 - 48, height: CGFloat(image.height) / 2 - 76)
    }

    func object(_ card: ResultCard) -> some View {
        FloatingResultView(card: card) { _ in }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func floatingResultStates(scheme: ColorScheme) throws {
        let hovered = card(.done(saved()))
        hovered.machine.pointerEnteredButtons(at: Date())
        let detail = card(.done(saved()))
        detail.machine.openDetail(at: Date())
        let long = card(.working(fraction: 0.3), source: Self.video, bytes: 148_000_000)
        long.startedAt = Date().addingTimeInterval(-5)
        let longDone = card(.working(fraction: 0.3), source: Self.video, bytes: 148_000_000)
        set(longDone, .done(saved(Self.video, before: 148_000_000, after: 37_000_000, kind: .video)))
        let thumbnails: [(String, ResultCard)] = [
            ("result-compressing", card(.working(fraction: 0.45))),
            ("result-saved", card(.done(saved()))),
            ("result-hover", hovered),
            ("result-harder", card(.done(saved(after: 360_000)), aggressive: true)),
            ("result-already-optimised", card(.unchanged(bytes: 41_200))),
            ("result-restored", card(.restored(saved()))),
            ("result-error", card(.failed("ffmpeg is missing. Reinstall L'Esclop or run Scripts/build-tools.sh."), source: Self.video)),
        ]
        for (name, card) in thumbnails {
            let size = try render(object(card), name: name, scheme: scheme)
            #expect(size.width == Metrics.thumbnailWidth, "\(name) is a 200 pt thumbnail")
        }
        let wide = Metrics.thumbnailWidth + Metrics.activityWidth - Metrics.activityTuck
        #expect(try render(object(long), name: "result-activity", scheme: scheme).width == wide)
        #expect(try render(object(longDone), name: "result-activity-done", scheme: scheme).width == wide)
        #expect(try render(object(detail), name: "result-detail", scheme: scheme).width == Metrics.detailWidth)
        try render(object(card(.notice(title: "Skipping the next copy", detail: "Press again to pause everything."))), name: "result-notice", scheme: scheme)
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
    func stackOfThree(scheme: ColorScheme) throws {
        let harness = Harness()
        harness.model.add(card(.done(saved())))
        harness.model.add(card(.done(saved(after: 1_100_000))))
        harness.model.add(card(.working(fraction: 0.7)))
        harness.model.add(card(.done(saved(after: 300_000))))
        #expect(harness.model.visibleCards.count == 3)
        try render(FloatingStackView(model: harness.model), name: "stack", scheme: scheme)
    }
}
