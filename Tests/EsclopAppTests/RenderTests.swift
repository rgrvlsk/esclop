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

    /// A photo with a tone of its own, so a hovered card shows its glow.
    static let sunset: NSImage = NSImage(size: NSSize(width: 400, height: 260), flipped: false) { rect in
        NSGradient(colors: [Palette.color(0x6B3FA0), Palette.color(0xE0566B), Palette.color(0xF29A3A)])?.draw(in: rect, angle: 90)
        Palette.color(0x7A3B2A).setFill()
        NSRect(x: 0, y: 0, width: rect.width, height: 70).fill()
        return true
    }

    /// A picture of `size` with a light frame round its edge, so a crop shows.
    static func framed(_ size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            sunset.draw(in: rect)
            NSColor.white.setStroke()
            let edge = NSBezierPath(rect: rect.insetBy(dx: 6, dy: 6))
            edge.lineWidth = 12
            edge.stroke()
            return true
        }
    }

    static let video = URL(fileURLWithPath: "/tmp/Screen Recording 2026-11-05 at 10.42.mov")
    static let shot = URL(fileURLWithPath: "/tmp/Screenshot 2026-11-05 at 10.42.png")

    func card(_ phase: ResultCard.Phase, source: URL = Self.shot, bytes: Int = 2_400_000, aggressive: Bool = false, origin: RequestOrigin = .clipboard) -> ResultCard {
        let card = ResultCard(jobID: UUID(), source: source, origin: origin, aggressive: aggressive, bytesBefore: bytes)
        card.thumbnail = Self.screenshot
        card.originalThumbnail = Self.screenshot
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

    /// A result's upload: going, done with the link copied, and refused with the reason.
    @Test(arguments: [ColorScheme.light, .dark])
    func uploadStates(scheme: ColorScheme) throws {
        let uploading = card(.done(saved()))
        uploading.upload = .uploading(fraction: 0.4)
        let uploaded = card(.done(saved()))
        uploaded.upload = .uploaded(URL(string: "https://files.example.com/2026/11/photo.png")!)
        let failed = card(.done(saved()))
        failed.upload = .failed(Strings.format("The upload target refused the file (%d): %@.", 403, "AccessDenied, Access Denied"))
        for (name, card) in [("result-uploading", uploading), ("result-uploaded", uploaded), ("result-upload-failed", failed)] {
            #expect(try render(object(card), name: name, scheme: scheme).width == Metrics.thumbnailWidth, "\(name) is a 208 pt card")
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func ruleGlyphOnTheCapsule(scheme: ColorScheme) throws {
        let ruled = card(.done(saved(after: 410_000)))
        ruled.appliedRule = ClipboardRule(origin: .screenshot, inputType: "public.png", choice: OptimiseChoice(format: .webp))
        try render(object(ruled), name: "result-rule", scheme: scheme)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func floatingResultStates(scheme: ColorScheme) throws {
        // Hovered: a copied screenshot offers Copy, a dropped file Show in Finder.
        let hovered = card(.done(saved()))
        hovered.machine.pointerEntered(at: Date())
        let droppedHover = card(.done(saved()), origin: .dropZone)
        droppedHover.machine.pointerEntered(at: Date())
        // A photo with a tone: the hovered card glows in it.
        let toned = card(.done(saved()), origin: .dropZone)
        toned.thumbnail = Self.sunset
        toned.machine.pointerEntered(at: Date())
        // A long video says the time left instead of the percentage.
        let long = card(.working(fraction: 0.3), source: Self.video, bytes: 148_000_000)
        long.startedAt = Date().addingTimeInterval(-5)
        long.expectedDuration = 80
        let thumbnails: [(String, ResultCard)] = [
            ("result-compressing", card(.working(fraction: 0.45))),
            ("result-compressing-long", long),
            ("result-saved", card(.done(saved()))),
            ("result-hover", hovered),
            ("result-hover-dropped", droppedHover),
            ("result-hover-tone", toned),
            ("result-grew", card(.done(saved(after: 2_470_000)))),
            ("result-harder", card(.done(saved(after: 360_000)), aggressive: true)),
            ("result-already-optimised", card(.unchanged(bytes: 41_200))),
            ("result-restored", card(.restored(saved()))),
            ("result-error", card(.failed(CardPresentation.message(for: EsclopError.unreadable(kind: .video))), source: Self.video)),
        ]
        for (name, card) in thumbnails {
            let size = try render(object(card), name: name, scheme: scheme)
            #expect(size.width == Metrics.thumbnailWidth, "\(name) is a 208 pt card")
        }
        try render(object(card(.notice(title: "Skipping the next copy", detail: "Press again to pause everything."))), name: "result-notice", scheme: scheme)
    }

    /// The detail (pr2-detail-card): a dropped photo shows its folder, a copied screenshot goes back
    /// to the clipboard, and the states with no saving or an upload keep the same layout.
    @Test(arguments: [ColorScheme.light, .dark])
    func detailStates(scheme: ColorScheme) throws {
        let beach = URL(fileURLWithPath: "/tmp/Desktop/Beach.jpg")
        func open(_ card: ResultCard) -> ResultCard {
            card.machine.openDetail(at: Date())
            return card
        }
        let photo = open(card(.done(saved(beach)), source: beach, origin: .dropZone))
        photo.thumbnail = Self.sunset
        let uploading = open(card(.done(saved())))
        uploading.upload = .uploading(fraction: 0.4)
        // Run again from the open detail: it stays open, aqua, with Stop as its charcoal button.
        let working = open(card(.done(saved(beach)), source: beach, origin: .dropZone))
        working.phase = .working(fraction: 0.45)
        working.machine.restarted()
        // A photo that lost its location, camera and date shows the "Removed" strip.
        let stripped = open(card(.done(saved(beach)), source: beach, origin: .dropZone))
        stripped.thumbnail = Self.sunset
        stripped.removedMetadata = [.location, .camera, .date]
        // A tall and a wide picture are fitted whole, not cropped.
        let tall = open(card(.done(saved(beach)), source: beach, origin: .dropZone))
        tall.thumbnail = Self.framed(NSSize(width: 300, height: 600))
        let wide = open(card(.done(saved(beach)), source: beach, origin: .dropZone))
        wide.thumbnail = Self.framed(NSSize(width: 900, height: 200))
        let details: [(String, ResultCard)] = [
            ("detail-dropped", photo),
            ("detail-clipboard", open(card(.done(saved())))),
            ("detail-grew", open(card(.done(saved(after: 2_470_000)), origin: .dropZone))),
            ("detail-already-optimised", open(card(.unchanged(bytes: 41_200), origin: .dropZone))),
            ("detail-uploading", uploading),
            ("detail-working", working),
            ("detail-metadata", stripped),
            ("detail-tall", tall),
            ("detail-wide", wide),
        ]
        for (name, card) in details {
            #expect(card.machine.level == .detail, "\(name) opened")
            #expect(try render(object(card), name: name, scheme: scheme).width == Metrics.detailWidth, "\(name) is 320 pt")
        }
    }

    /// The ring at a small, half, three-quarter and nearly whole saving: the dot never touches the
    /// figure.
    @Test(arguments: [ColorScheme.light, .dark])
    func savingRing(scheme: ColorScheme) throws {
        for percent in [5, 50, 75, 99] {
            let after = 2_400_000 * (100 - percent) / 100
            try render(object(card(.done(saved(after: after)))), name: "result-saved-\(percent)", scheme: scheme)
        }
    }

    /// The white dot clears the figure by 3 pt or more wherever the saving puts it, on the card
    /// and in the detail. Measured on the figure's rendered ink, at both ends of each percentage.
    @Test func theDotClearsTheFigure() throws {
        for ring in [CardFooter.ring, CardFooter.largeRing] {
            let radius = SavingGauge.radius(side: ring.side, lineWidth: ring.lineWidth)
            let dot = SavingGauge.dotRadius(lineWidth: ring.lineWidth)
            for percent in 1 ... 99 {
                let ink = try Self.ink(of: Figure(number: Figure.percentParts(percent).number, unit: "%", spoken: "", size: ring.figure))
                for saved in [Double(percent) - 0.5, Double(percent), Double(percent) + 0.49].map({ $0 / 100 }) {
                    let angle = SavingGauge.dotAngle(saved: saved, shape: .ring) * .pi / 180
                    let centre = CGPoint(x: radius * cos(angle), y: radius * sin(angle))
                    let gap = ink.map { hypot($0.x - centre.x, $0.y - centre.y) }.min()! - dot
                    #expect(gap >= 3, "\(ring.side) pt ring at \(saved): the dot is \(gap) pt from the figure")
                }
            }
        }
    }

    /// The inked points of a view, in points from its centre, at 4x.
    static func ink(of view: some View) throws -> [CGPoint] {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 4
        let rep = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        let width = CGFloat(rep.pixelsWide) / 4, height = CGFloat(rep.pixelsHigh) / 4
        var points: [CGPoint] = []
        for y in 0 ..< rep.pixelsHigh {
            for x in 0 ..< rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                points.append(CGPoint(x: (CGFloat(x) + 0.5) / 4 - width / 2, y: (CGFloat(y) + 0.5) / 4 - height / 2))
            }
        }
        return points
    }

    /// A round button drawn smaller than the pointer minimum still takes the whole target.
    @Test func smallRoundButtonsTakeAWholePointerTarget() throws {
        for size in [CardFace.closeSize, DetailCard.closeSize, Metrics.toolSize] {
            let image = try #require(ImageRenderer(content: PillButton(action: .dismiss, size: size) { _ in }).cgImage)
            #expect(CGFloat(image.width) >= Spacing.hit && CGFloat(image.height) >= Spacing.hit, "\(size) pt button")
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func dropZone(scheme: ColorScheme) throws {
        try render(DropZoneView(state: DropZoneState(fileCount: 3)), name: "drop-zone", scheme: scheme)
        try render(DropZoneView(state: DropZoneState(fileCount: 3, hovering: true)), name: "drop-zone-hover", scheme: scheme)
        try render(DropZoneView(state: DropZoneState(fileCount: 1, hovering: true, harder: true)), name: "drop-zone-harder", scheme: scheme)
        // Preset zones: four in the grid with one under the drag, and three on the other side.
        let zones = [
            PresetZone(name: "to WebP", icon: "photo", builtIn: true), PresetZone(name: "fit under 1 MB", icon: "arrow.down.circle", builtIn: true),
            PresetZone(name: "Screenshots for the blog post", icon: "camera.viewfinder"), PresetZone(name: "Share", icon: "square.and.arrow.up"),
        ]
        let four = try render(DropZoneView(state: DropZoneState(fileCount: 2, zones: zones, hoveredZone: "fit under 1 MB")), name: "drop-zone-presets", scheme: scheme)
        #expect(four.width > Metrics.dropZoneWidth, "the zones sit beside the plain target")
        try render(DropZoneView(state: DropZoneState(fileCount: 0, zones: Array(zones.prefix(3)), zonesLeading: false)), name: "drop-zone-presets-left", scheme: scheme)
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

    /// The newest result is hovered: its buttons lie over its own picture and its glow does not
    /// move its neighbours.
    @Test(arguments: [ColorScheme.light, .dark])
    func stackWithHoverButtons(scheme: ColorScheme) throws {
        let harness = Harness()
        harness.model.add(card(.done(saved(after: 1_100_000))))
        harness.model.add(card(.done(saved(after: 257_000))))
        let hovered = card(.done(saved()))
        harness.model.add(hovered)
        hovered.machine.pointerEntered(at: Date())
        #expect(hovered.machine.showsHoverButtons)
        try render(FloatingStackView(model: harness.model), name: "stack-hover", scheme: scheme)
    }
}
