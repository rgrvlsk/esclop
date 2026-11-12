// SPDX-License-Identifier: GPL-3.0-or-later
//
// The floating surface and its inks as real windows over a desktop, light and dark:
// `ESCLOP_RENDER_DIR=<folder> Scripts/test.sh --filter SurfaceRenderTests`. The contrast the
// design promises (docs/design/proposal.md › Tokens) is measured here on rendered pixels.

import AppKit
@testable import EsclopAppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct SurfaceRenderTests {
    static let schemes: [ColorScheme] = [.light, .dark]

    /// Every ink on the floating surface, over a white, a black and a busy desktop, measured on
    /// rendered pixels. Each ink is drawn as a square, so the sample is the ink itself and not an
    /// antialiased edge. Text, secondary text and the saving hold 4.5:1; the aggressive mark and
    /// the error triangle, symbols, 3:1 (the sentence beside the triangle is in text ink). The
    /// surface is probed at the card's size, a drop tile's (whose name keeps its contrast while
    /// the tile is dimmed) and a small capsule's, and the card under the strongest picture
    /// tones. On the 6 % fill (key caps) text and secondary text hold 4.5:1; on the 14 % fill (a
    /// button, a selected tile) words are set in text ink, which holds it.
    @Test(arguments: schemes)
    func inkContrastOnRenderedSurfaces(scheme: ColorScheme) async throws {
        let inks: [(String, AnyShapeStyle, Double)] = [
            ("saving", AnyShapeStyle(Ink.saving), 4.5), ("warm", AnyShapeStyle(Ink.warm), 3),
            ("error", AnyShapeStyle(Ink.error), 3), ("secondary", AnyShapeStyle(Ink.secondary), 4.5),
            ("text", AnyShapeStyle(Ink.text), 4.5),
        ]
        struct Probe {
            var name: String
            var size: CGSize
            var radius: CGFloat
            var small = false
            var fill: PinnedInk?
            var tone: Color?
        }
        var probes = [
            Probe(name: "card", size: CGSize(width: 240, height: 60), radius: Radius.card),
            Probe(name: "tile", size: CGSize(width: 240, height: 92), radius: Radius.tile),
            Probe(name: "capsule", size: CGSize(width: 240, height: 32), radius: 16, small: true),
            Probe(name: "resting-fill", size: CGSize(width: 240, height: 60), radius: Radius.card, fill: NeutralFill.resting),
            Probe(name: "button-fill", size: CGSize(width: 240, height: 60), radius: Radius.card, fill: NeutralFill.button),
        ]
        for (wash, tone) in [("red", Color.red), ("blue", Color.blue), ("yellow", Color.yellow)] {
            probes.append(Probe(name: "card-\(wash)", size: CGSize(width: 240, height: 60), radius: Radius.card, tone: tone))
        }
        let stage = CGSize(width: 300, height: 140)
        for probe in probes {
            let square = min(20, probe.size.height - 12)
            let row = HStack(spacing: 20) {
                ForEach(inks, id: \.0) { Rectangle().fill($0.1).frame(width: square, height: square) }
            }
            .frame(width: probe.size.width - 20, height: probe.size.height - 12)
            .background { if let fill = probe.fill { RoundedRectangle(cornerRadius: Radius.inner, style: .continuous).fill(fill) } }
            .frame(width: probe.size.width, height: probe.size.height)
            .floatingSurface(probe.radius, small: probe.small, tone: probe.tone)
            for (desktop, flat) in [("white", Color.white as Color?), ("black", Color.black as Color?), ("busy", nil)] {
                try await SurfaceRender.floating(row, size: stage, name: "ink-probe-\(probe.name)-\(desktop)", scheme: scheme, busy: flat == nil, flat: flat)
                guard let image = SurfaceRender.lastImage else { continue }
                let scale = Double(image.width) / stage.width
                let centre = stage.height / 2
                // The row is centred: five squares 20 apart, in a surface centred in the stage.
                let rowWidth = Double(inks.count) * square + Double(inks.count - 1) * 20
                let firstX = (stage.width - rowWidth) / 2 + square / 2
                // The ground: between the surface's edge and the first square, clear of the fill.
                let groundX = (stage.width - probe.size.width) / 2 + 6
                let ground = try #require(InkSample.color(in: image, x: groundX * scale, y: centre * scale))
                let fillGround = try #require(InkSample.color(in: image, x: (firstX - square / 2 - 5) * scale, y: centre * scale))
                // What is set on each fill: words in text ink on both, secondary on the resting one.
                let measured: Set<String> = switch probe.fill?.light {
                case nil: Set(inks.map(\.0))
                case NeutralFill.resting.light: ["text", "secondary"]
                default: ["text"]
                }
                for (index, ink) in inks.enumerated() where measured.contains(ink.0) {
                    let x = (firstX + Double(index) * (square + 20)) * scale
                    let color = try #require(InkSample.color(in: image, x: x, y: centre * scale))
                    let ratio = RGBA.contrast(color, probe.fill == nil ? ground : fillGround)
                    #expect(ratio >= ink.2, "\(scheme == .dark ? "dark" : "light"), \(ink.0) on the \(probe.name) over a \(desktop) desktop: \(String(format: "%.2f", ratio)):1")
                }
            }
        }
    }

    /// White on a lit tile, both fills, over any desktop: the fill is opaque.
    @Test(arguments: schemes)
    func litTilesHoldWhiteTextOnRenderedPixels(scheme: ColorScheme) async throws {
        let stage = CGSize(width: 200, height: 140)
        for (name, fill) in [("lit", Ink.lit), ("lit-warm", Ink.litWarm)] {
            let tile = Rectangle().fill(Ink.onLit).frame(width: 20, height: 20)
                .frame(width: 92, height: 92)
                .floatingSurface(Radius.tile, tint: fill)
            try await SurfaceRender.floating(tile, size: stage, name: "ink-probe-\(name)", scheme: scheme, busy: true)
            guard let image = SurfaceRender.lastImage else { continue }
            let scale = Double(image.width) / stage.width
            let ink = try #require(InkSample.color(in: image, x: 100 * scale, y: 70 * scale))
            let ground = try #require(InkSample.color(in: image, x: 70 * scale, y: 70 * scale))
            #expect(RGBA.contrast(ink, ground) >= 4.5, "\(name): \(RGBA.contrast(ink, ground))")
        }
    }

    /// The surface as a card would wear it, for the pull request: over white, black and a busy
    /// desktop, and lit by three pictures' tones; the four figure sizes.
    @Test(arguments: schemes)
    func surfaces(scheme: ColorScheme) async throws {
        let sheet = HStack(alignment: .top, spacing: 24) {
            SurfaceSample(picture: SurfaceSamples.screenshot)
            SurfaceSample(picture: SurfaceSamples.photo, toned: true)
            VStack(spacing: Spacing.floating) {
                Text("Uploaded · link copied").font(Typeface.label).foregroundStyle(Ink.text)
                    .padding(.horizontal, Spacing.m).frame(height: 32)
                    .floatingSurface(16, small: true)
                Label("Optimise", systemImage: "bolt.fill").font(Typeface.label).foregroundStyle(Ink.onLit)
                    .frame(width: 92, height: 92)
                    .floatingSurface(Radius.tile, tint: Ink.lit)
            }
        }
        for (ground, flat, busy) in [("white", Color.white as Color?, false), ("black", Color.black as Color?, false), ("busy", nil, true)] {
            try await SurfaceRender.floating(sheet, size: CGSize(width: 620, height: 300), name: "surface-on-\(ground)", scheme: scheme, busy: busy, flat: flat)
        }
        let figures = HStack(alignment: .firstTextBaseline, spacing: 28) {
            ForEach(Figure.Size.allCases, id: \.self) { Figure(percentSaved: 75, size: $0, locale: Locale(identifier: "ca_ES")) }
            Figure(bytesSaved: 38_000_000, size: .detail)
        }
        .padding(Spacing.xl)
        .floatingSurface(Radius.panel)
        try await SurfaceRender.floating(figures, size: CGSize(width: 620, height: 200), name: "figures", scheme: scheme)
    }

    /// A burst writes every frame on time, numbered, with the time each was taken.
    @Test func aBurstWritesNumberedFrames() async throws {
        _ = NSApplication.shared
        let temp = TempDir()
        let snapshots = try #require(WindowSnapshots(environment: [WindowSnapshots.environmentKey: temp.url.path]))
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Burst"
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        let manifest = try await snapshots.write(label: "arrival", burst: .init(frames: 5, interval: 40), windows: { [window] })
        let frames = try #require(manifest.frames)
        #expect(frames.map(\.index) == [1, 2, 3, 4, 5])
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.milliseconds < $1.milliseconds })
        #expect(frames.last!.milliseconds >= 160, "the last frame comes 4 intervals after the first")
        let stored = try JSONDecoder().decode(WindowSnapshots.Manifest.self, from: Data(contentsOf: temp.url.appendingPathComponent("arrival.json")))
        #expect(stored == manifest)
        // A runner without a window server session gives no image; the manifest is still written.
        guard let entry = frames.last?.windows.first else { return }
        #expect(entry.file == "arrival-f005-1-burst.png")
        #expect(NSBitmapImageRep(data: try Data(contentsOf: temp.url.appendingPathComponent(entry.file))) != nil)
    }
}

/// A card-shaped sample of the surface: a picture with its hairline, a figure and a caption.
private struct SurfaceSample: View {
    let picture: NSImage
    var toned = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 200, height: 130)
                .clipShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                .pictureHairline(Radius.inner)
            HStack(alignment: .firstTextBaseline) {
                Figure(percentSaved: 75, size: .card, locale: Locale(identifier: "en_GB"))
                Spacer()
                Text("612 KB").font(Typeface.caption).foregroundStyle(Ink.secondary)
            }
            .padding(.horizontal, Spacing.s)
            Text("Screenshot").font(Typeface.label).foregroundStyle(Ink.text).padding([.horizontal, .bottom], Spacing.s)
        }
        .padding(Spacing.xs)
        .frame(width: 208)
        .floatingSurface(Radius.card, tone: toned ? PictureTone.of(picture, dark: scheme == .dark) : nil)
    }
}

@MainActor
enum SurfaceSamples {
    static let screenshot = RenderTests.screenshot

    /// A photograph stand-in: dusk over water.
    static let photo: NSImage = NSImage(size: NSSize(width: 400, height: 300), flipped: true) { rect in
        NSGradient(colors: [Palette.color(0xF2A65A), Palette.color(0xD9627A), Palette.color(0x3B3F78)])?.draw(in: rect, angle: 90)
        Palette.color(0xFFE2A8).setFill()
        NSBezierPath(ovalIn: NSRect(x: 250, y: 120, width: 56, height: 56)).fill()
        return true
    }
}

/// The desktop behind the floating surfaces: a wallpaper, or a plain ground, or strong colour
/// and text right under the surface.
private struct TestDesktop: View {
    @Environment(\.colorScheme) private var scheme
    var busy = false
    var flat: Color?

    var body: some View {
        let colors = scheme == .dark ? [0x1B2B45, 0x3A1F4A, 0x0E1420] : [0x9CC3E6, 0xE9C6B0, 0x7FA3C9]
        ZStack(alignment: .topLeading) {
            if let flat { flat } else {
                LinearGradient(colors: colors.map { Color(nsColor: Palette.color(UInt32($0))) }, startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            if busy {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(0 ..< 40, id: \.self) { row in
                        HStack(spacing: 8) {
                            ForEach(0 ..< 12, id: \.self) { column in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill([Color.red, .yellow, .white, .black, .green, .purple][(row + column) % 6].opacity(0.85))
                                    .frame(width: CGFloat(30 + (row * 7 + column * 13) % 60), height: 10)
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
        .ignoresSafeArea()
    }
}

@MainActor
enum SurfaceRender {
    /// The last capture, for tests that measure rendered pixels.
    static var lastImage: CGImage?

    /// A floating surface over the desktop, in a borderless window the size of the stage.
    static func floating(_ view: some View, size: CGSize, name: String, scheme: ColorScheme, busy: Bool = false, flat: Color? = nil) async throws {
        lastImage = nil
        _ = NSApplication.shared
        let stage = ZStack { TestDesktop(busy: busy, flat: flat); view }
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: stage)
        let window = KeyWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(450))
        host.layoutSubtreeIfNeeded()
        defer {
            window.orderOut(nil)
            window.close()
        }
        // A runner without a window server session gives no image: the layout still ran.
        guard let image = WindowSnapshots.image(of: window) else { return }
        lastImage = image
        try FileManager.default.createDirectory(at: RenderTests.folder, withIntermediateDirectories: true)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: RenderTests.folder.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
    }
}

/// Reads one pixel of a capture as an sRGB colour.
enum InkSample {
    static func color(in image: CGImage, x: Double, y: Double) -> RGBA? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: -x, y: -(Double(image.height) - y - 1), width: Double(image.width), height: Double(image.height)))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: 4)
        return RGBA(UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2]))
    }
}
