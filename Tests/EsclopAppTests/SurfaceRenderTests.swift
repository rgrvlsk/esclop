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

    /// One probe: a fill inside the floating surface (or the surface itself), and the inks set
    /// on it with the contrast each must hold.
    struct Probe {
        var name: String
        var fill: AnyShapeStyle?
        var inks: [(String, AnyShapeStyle, Double)]
        var tone: Color?
    }

    static let text = ("text", AnyShapeStyle(Ink.text), 4.5)
    static let secondary = ("secondary", AnyShapeStyle(Ink.secondary), 4.5)
    static let original = ("original", AnyShapeStyle(Ink.original), 4.5)
    static let saving = ("saving", AnyShapeStyle(Ink.saving), 4.5)
    static let charcoalText = ("charcoal-text", AnyShapeStyle(Ink.charcoalText), 4.5)
    static let warm = ("warm", AnyShapeStyle(Ink.warm), 3.0)
    static let error = ("error", AnyShapeStyle(Ink.error), 3.0)

    /// Every ink on every fill it is set on, measured on rendered pixels, over a white, a black
    /// and a busy desktop: the material is opaque, so all three must agree. Each ink is drawn as
    /// a square, so the sample is the ink itself and not an antialiased edge. Text, secondary
    /// text (the new size), the original size, the saving and charcoal as text hold 4.5:1; the amber mark, the
    /// error triangle and the progress bar, which are not text, 3:1. On a charcoal fill (selected
    /// or on) white holds 4.5:1. On the 14 % fill words are set in text ink.
    @Test(arguments: schemes)
    func inkContrastOnRenderedSurfaces(scheme: ColorScheme) async throws {
        var probes = [
            Probe(name: "surface", inks: [Self.text, Self.secondary, Self.original, Self.saving, Self.charcoalText, Self.warm, Self.error]),
            Probe(name: "tile", fill: AnyShapeStyle(Surface.tile), inks: [Self.text, Self.secondary, Self.original, Self.saving, Self.charcoalText, Self.warm, Self.error]),
            Probe(name: "progress", fill: AnyShapeStyle(Surface.progress), inks: [Self.text, Self.secondary, ("bar", AnyShapeStyle(Ink.progress), 3.0)]),
            Probe(name: "decision", fill: AnyShapeStyle(Surface.decision), inks: [Self.text, Self.secondary, Self.warm, Self.error]),
            Probe(name: "charcoal", fill: AnyShapeStyle(Ink.charcoal), inks: [("on-charcoal", AnyShapeStyle(Ink.onCharcoal), 4.5)]),
            Probe(name: "resting-fill", fill: AnyShapeStyle(NeutralFill.resting), inks: [Self.text, Self.secondary]),
            Probe(name: "button-fill", fill: AnyShapeStyle(NeutralFill.button), inks: [Self.text]),
        ]
        for (wash, tone) in [("red", Color.red), ("blue", Color.blue), ("yellow", Color.yellow)] {
            probes.append(Probe(name: "surface-\(wash)", inks: [Self.text, Self.secondary, Self.original, Self.saving], tone: tone))
        }
        let stage = CGSize(width: 340, height: 140)
        let square: CGFloat = 20
        for probe in probes {
            let row = HStack(spacing: 20) {
                ForEach(probe.inks, id: \.0) { Rectangle().fill($0.1).frame(width: square, height: square) }
            }
            .padding(.horizontal, 20)
            .frame(height: 44)
            .background { if let fill = probe.fill { RoundedRectangle(cornerRadius: Radius.inner, style: .continuous).fill(fill) } }
            .padding(8)
            .floatingSurface(Radius.card, tone: probe.tone)
            for (desktop, flat) in [("white", Color.white as Color?), ("black", Color.black as Color?), ("busy", nil)] {
                try await SurfaceRender.floating(row, size: stage, name: "ink-probe-\(probe.name)-\(desktop)", scheme: scheme, busy: flat == nil, flat: flat)
                guard let image = SurfaceRender.lastImage else { continue }
                let scale = Double(image.width) / stage.width
                let centre = stage.height / 2
                let rowWidth = Double(probe.inks.count) * square + Double(probe.inks.count - 1) * 20
                let firstX = (stage.width - rowWidth) / 2 + square / 2
                // The ground: 10 pt left of the first square, inside the fill (or the surface).
                let ground = try #require(InkSample.color(in: image, x: (firstX - square / 2 - 10) * scale, y: centre * scale))
                for (index, ink) in probe.inks.enumerated() {
                    let x = (firstX + Double(index) * (square + 20)) * scale
                    let color = try #require(InkSample.color(in: image, x: x, y: centre * scale))
                    let ratio = RGBA.contrast(color, ground)
                    #expect(ratio >= ink.2, "\(scheme == .dark ? "dark" : "light"), \(ink.0) on the \(probe.name) over a \(desktop) desktop: \(String(format: "%.2f", ratio)):1")
                }
            }
        }
    }

    /// The material, the fills and the gauge as a card would wear them, for the pull request:
    /// over white, black and a busy desktop; the figure's sizes; headings and a section label.
    @Test(arguments: schemes)
    func surfaces(scheme: ColorScheme) async throws {
        let sheet = HStack(alignment: .top, spacing: 24) {
            SurfaceSample(picture: SurfaceSamples.screenshot)
            SurfaceSample(picture: SurfaceSamples.photo, toned: true)
            VStack(spacing: Spacing.floating) {
                HStack(spacing: Spacing.s) {
                    Text("Holiday.mov").font(Typeface.title).foregroundStyle(Ink.text)
                    Spacer()
                    Text("40 %").font(Typeface.caption).foregroundStyle(Ink.secondary).monospacedDigit()
                }
                .padding(.horizontal, Spacing.m).frame(width: 160, height: 44)
                .overlay(alignment: .bottom) {
                    Capsule().fill(Ink.progress).frame(width: 136 * 0.4, height: 4).frame(width: 136, alignment: .leading)
                        .background(alignment: .leading) { Capsule().fill(Ink.secondary.opacity(0.2)).frame(width: 136, height: 4) }
                        .padding(.bottom, 6)
                }
                .floatingSurface(Radius.card, fill: Surface.progress)
                Label("Couldn't compress", systemImage: "exclamationmark.triangle").font(Typeface.label).foregroundStyle(Ink.text)
                    .padding(.horizontal, Spacing.m).frame(width: 160, height: 44)
                    .floatingSurface(Radius.card, fill: Surface.decision)
                VStack(spacing: 6) {
                    Image(systemName: "photo").font(.system(size: 20))
                    Text("Optimise").font(Typeface.label)
                }
                .foregroundStyle(Ink.onCharcoal)
                .frame(width: 92, height: 92)
                .floatingSurface(Radius.tile, fill: Ink.charcoal)
            }
        }
        for (ground, flat, busy) in [("white", Color.white as Color?, false), ("black", Color.black as Color?, false), ("busy", nil, true)] {
            try await SurfaceRender.floating(sheet, size: CGSize(width: 660, height: 330), name: "surface-on-\(ground)", scheme: scheme, busy: busy, flat: flat)
        }
        let type = VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Today").font(Typeface.heading).foregroundStyle(Ink.text)
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Saved").sectionLabel()
                HStack(alignment: .bottom, spacing: 28) {
                    ForEach(Figure.Size.allCases, id: \.self) { Figure(percentSaved: 75, size: $0, locale: Locale(identifier: "ca_ES")) }
                    Figure(bytesSaved: 2_800_000_000, size: .detail)
                }
                HStack(spacing: Spacing.s) {
                    Text("2.4 MB").foregroundStyle(Ink.original)
                    Image(systemName: "arrow.right").foregroundStyle(Ink.secondary)
                    Text("612 kB").foregroundStyle(Ink.secondary)
                }
                .font(Typeface.body)
            }
            .padding(Spacing.m)
            .background(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous).fill(Surface.tile))
        }
        .padding(Spacing.xl)
        .floatingSurface(Radius.panel)
        try await SurfaceRender.floating(type, size: CGSize(width: 680, height: 320), name: "type", scheme: scheme)
        let gauges = HStack(alignment: .center, spacing: 32) {
            ZStack {
                SavingGauge(saved: 0.75)
                Figure(percentSaved: 75, size: .card, locale: Locale(identifier: "ca_ES"))
            }
            .frame(width: 84, height: 84)
            VStack(spacing: 0) {
                SavingGauge(saved: 0.68, shape: .arc).frame(width: 220, height: 80)
                Figure(bytesSaved: 2_800_000_000, size: .panel).offset(y: -44)
            }
        }
        .padding(Spacing.xl)
        .floatingSurface(Radius.panel)
        try await SurfaceRender.floating(gauges, size: CGSize(width: 480, height: 220), name: "gauges", scheme: scheme)
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

/// A card-shaped sample of the surface: a picture with its hairline, the ring and the figure,
/// the original size in brick red and the new one in grey.
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
            HStack(spacing: Spacing.s) {
                ZStack {
                    SavingGauge(saved: 0.75, lineWidth: 4)
                    Figure(percentSaved: 75, size: .card, locale: Locale(identifier: "en_GB"))
                        .scaleEffect(0.7)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("2.4 MB").foregroundStyle(Ink.original)
                        Image(systemName: "arrow.right").foregroundStyle(Ink.secondary)
                        Text("612 kB").foregroundStyle(Ink.secondary)
                    }
                    .font(Typeface.label)
                    Text("Screenshot.png").font(Typeface.caption).foregroundStyle(Ink.secondary)
                }
            }
            .padding([.horizontal, .bottom], Spacing.s)
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
