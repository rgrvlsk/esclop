// SPDX-License-Identifier: GPL-3.0-or-later
//
// Renders the design overhaul's prototype (docs/design/proposal.md), light and dark, as real
// windows: `ESCLOP_RENDER_DIR=<folder> Scripts/test.sh --filter 'PrototypeRenderTests'`.

@testable import EsclopAppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct PrototypeRenderTests {
    static let schemes: [ColorScheme] = [.light, .dark]

    @Test(arguments: schemes)
    func results(scheme: ColorScheme) async throws {
        let states: [(String, ProtoResultCard.State)] = [
            ("working", .working(progress: 0.62, left: "4 s")), ("done", .done), ("aggressive", .aggressive),
            ("ruled", .ruled), ("already", .already), ("restored", .restored),
            ("failed", .failed), ("failed-open", .failedOpen), ("unreadable", .unreadable),
            ("uploaded", .uploaded),
        ]
        func sheet(hover: Bool, catalan: Bool = false) -> some View {
            VStack(spacing: 24) {
                ForEach(0 ..< 3, id: \.self) { row in
                    HStack(alignment: .bottom, spacing: 24) {
                        ForEach(states[row * 3 ..< row * 3 + 3], id: \.0) { ProtoResultCard(state: $0.1, hover: hover, catalan: catalan) }
                    }
                }
                HStack(alignment: .bottom, spacing: 24) {
                    ProtoResultCard(state: .uploaded, hover: hover, catalan: catalan)
                    ProtoResultCard(state: .failed, hover: hover, failures: 3, catalan: catalan)
                }
            }
        }
        try await ProtoRender.floating(sheet(hover: false, catalan: true), size: CGSize(width: 780, height: 900), name: "result-states-ca", scheme: scheme)
        try await ProtoRender.floating(sheet(hover: false), size: CGSize(width: 780, height: 900), name: "result-states", scheme: scheme)
        try await ProtoRender.floating(sheet(hover: true), size: CGSize(width: 780, height: 900), name: "result-states-hover", scheme: scheme)
        try await ProtoRender.floating(ProtoResultCard(state: .done), size: CGSize(width: 300, height: 240), name: "result-busy", scheme: scheme, busy: true)
        let edges = HStack(spacing: 24) { ProtoResultCard(state: .done); ProtoNotice() }
        try await ProtoRender.floating(edges, size: CGSize(width: 640, height: 240), name: "result-on-white", scheme: scheme, flat: .white)
        try await ProtoRender.floating(edges, size: CGSize(width: 640, height: 240), name: "result-on-black", scheme: scheme, flat: .black)
        try await ProtoRender.floating(ProtoStack(), size: CGSize(width: 300, height: 620), name: "result-stack", scheme: scheme, alignment: .bottomTrailing)
        try await ProtoRender.floating(ProtoStackWithFailures(), size: CGSize(width: 300, height: 620), name: "result-stack-failures", scheme: scheme, alignment: .bottomTrailing)
        try await ProtoRender.floating(ProtoStackWithFailures(catalan: true), size: CGSize(width: 300, height: 620), name: "result-stack-failures-ca", scheme: scheme, alignment: .bottomTrailing)
        try await ProtoRender.floating(edges, size: CGSize(width: 640, height: 240), name: "result-on-busy", scheme: scheme, busy: true)
        try await ProtoRender.floating(ProtoStackWithDetail(), size: CGSize(width: 400, height: 620), name: "result-detail", scheme: scheme, alignment: .bottomTrailing)
        try await ProtoRender.floating(ProtoNotice(), size: CGSize(width: 420, height: 110), name: "result-notice", scheme: scheme)
    }

    @Test(arguments: schemes)
    func menu(scheme: ColorScheme) async throws {
        let panels = HStack(alignment: .top, spacing: 20) {
            ProtoMenuPanel()
            ProtoMenuPanel(mode: .batch)
            ProtoMenuPanel(mode: .paused)
            ProtoMenuPanel(mode: .empty)
        }
        try await ProtoRender.floating(panels, size: CGSize(width: 1400, height: 520), name: "menu-panel", scheme: scheme, alignment: .top)
        try await ProtoRender.floating(
            HStack(alignment: .top, spacing: 20) { ProtoMenuPanel(catalan: true); ProtoMenuPanel(mode: .paused, catalan: true); ProtoPauseMenu(catalan: true); ProtoPauseMenu() },
            size: CGSize(width: 1150, height: 520), name: "menu-panel-ca", scheme: scheme, alignment: .top
        )
        try await ProtoRender.floating(ProtoMenuPanel(), size: CGSize(width: 380, height: 560), name: "menu-panel-busy", scheme: scheme, busy: true, alignment: .top)
        try await ProtoRender.floating(ProtoGlyphStrip(), size: CGSize(width: 520, height: 120), name: "glyph", scheme: scheme)
    }

    @Test(arguments: schemes)
    func options(scheme: ColorScheme) async throws {
        let tabs = HStack(alignment: .top, spacing: 20) {
            ProtoOptions(tab: .format)
            ProtoOptions(tab: .size)
            ProtoOptions(tab: .actions)
        }
        try await ProtoRender.floating(tabs, size: CGSize(width: 1120, height: 480), name: "options", scheme: scheme, alignment: .top)
        let kinds = HStack(alignment: .top, spacing: 20) {
            ProtoOptions(kind: .video, pending: true)
            ProtoOptions(kind: .pdf)
            ProtoOptions(kind: .audio)
        }
        try await ProtoRender.floating(kinds, size: CGSize(width: 1120, height: 440), name: "options-kinds", scheme: scheme, alignment: .top)
        let catalan = HStack(alignment: .top, spacing: 20) {
            ProtoOptions(tab: .format, catalan: true)
            ProtoOptions(tab: .size, catalan: true)
            ProtoOptions(tab: .actions, catalan: true)
        }
        try await ProtoRender.floating(catalan, size: CGSize(width: 1120, height: 480), name: "options-ca", scheme: scheme, alignment: .top)
    }

    @Test(arguments: schemes)
    func dropZone(scheme: ColorScheme) async throws {
        let zones = VStack(alignment: .trailing, spacing: 26) {
            ProtoDropZone(mode: .idle)
            ProtoDropZone(mode: .target)
            ProtoDropZone(mode: .preset)
            ProtoDropZone(mode: .aggressive)
            ProtoDropZone(mode: .idle, catalan: true)
        }
        try await ProtoRender.floating(zones, size: CGSize(width: 640, height: 680), name: "drop-zone", scheme: scheme)
    }

    @Test(arguments: schemes)
    func windows(scheme: ColorScheme) async throws {
        try await ProtoRender.window(NavigationStack { ProtoBatch() }, size: CGSize(width: 560, height: 480), name: "batch", scheme: scheme, title: "9 files")
        try await ProtoRender.window(NavigationStack { ProtoBatch(running: true) }, size: CGSize(width: 560, height: 480), name: "batch-running", scheme: scheme, title: "9 files")
        try await ProtoRender.window(NavigationStack { ProtoAllResults() }, size: CGSize(width: 560, height: 480), name: "all-results", scheme: scheme, title: "All Results")
        try await ProtoRender.window(ProtoSettings(pane: .general), size: CGSize(width: 760, height: 560), name: "settings-general", scheme: scheme)
        try await ProtoRender.window(ProtoSettings(pane: .automatic), size: CGSize(width: 760, height: 560), name: "settings-automatic", scheme: scheme)
        try await ProtoRender.window(ProtoSettings(pane: .quality), size: CGSize(width: 760, height: 560), name: "settings-quality", scheme: scheme)
        try await ProtoRender.window(ProtoOnboarding(step: .tryIt), size: CGSize(width: 600, height: 480), name: "onboarding-1-try", scheme: scheme)
        try await ProtoRender.window(ProtoOnboarding(step: .tried), size: CGSize(width: 600, height: 480), name: "onboarding-2-tried", scheme: scheme)
        try await ProtoRender.window(ProtoOnboarding(step: .menuBar), size: CGSize(width: 600, height: 480), name: "onboarding-3-menu-bar", scheme: scheme)
        try await ProtoRender.window(ProtoPipeline(), size: CGSize(width: 820, height: 560), name: "pipeline", scheme: scheme)
        try await ProtoRender.window(NavigationStack { ProtoCompare() }, size: CGSize(width: 820, height: 560), name: "compare", scheme: scheme, title: "Beach 01.jpg")
    }

    /// The contrast the proposal promises, measured on rendered pixels: the saving green, the
    /// aggressive mark and secondary text on the floating surface, over a white, a black and a
    /// busy desktop, in both appearances and both directions. Each ink is drawn as a square on
    /// the surface, so the sample is the ink itself and not an antialiased edge.
    @Test(arguments: schemes)
    func inkContrastOnRenderedSurfaces(scheme: ColorScheme) async throws {
        for own in [false, true] {
            Proto.own = own
            defer { Proto.own = false }
            let inks: [(String, Color)] = [("saving", Proto.saving), ("warm", Proto.warm), ("secondary", Proto.quiet), ("text", Proto.ink)]
            // `error` marks a symbol; the sentence beside it is set in text ink.
            let probe = HStack(spacing: 20) {
                ForEach(inks, id: \.0) { Rectangle().fill($0.1).frame(width: 20, height: 20) }
            }
            .frame(width: 200, height: 60)
            .protoGlass(Proto.cardRadius)
            for (ground, flat, busy) in [("white", Color.white as Color?, false), ("black", Color.black as Color?, false), ("busy", nil, true)] {
                try await ProtoRender.floating(probe, size: CGSize(width: 260, height: 120), name: "ink-probe-\(ground)", scheme: scheme, busy: busy, flat: flat)
                guard let image = ProtoRender.lastImage else { continue }
                let scale = Double(image.width) / 260
                // Squares are centred in the 200 pt surface, which is centred in the 260 pt stage.
                let ground = try #require(InkProbe.color(in: image, x: 45 * scale, y: 60 * scale))
                for (index, ink) in inks.enumerated() {
                    let x = (70 + 40 * Double(index)) * scale
                    let color = try #require(InkProbe.color(in: image, x: x, y: 60 * scale))
                    let ratio = RGBA.contrast(color, ground)
                    // The aggressive mark is a symbol, not text: 3:1.
                    #expect(ratio >= (ink.0 == "warm" ? 3 : 4.5), "\(own ? "B" : "A") \(scheme == .dark ? "dark" : "light"), \(ink.0) on the surface over a \(busy ? "busy" : "\(flat == .white ? "white" : "black")") desktop: \(String(format: "%.2f", ratio)):1")
                }
            }
        }
    }

    /// The competing direction: the same surfaces with the app's own material and colours.
    @Test(arguments: schemes)
    func ownBrand(scheme: ColorScheme) async throws {
        Proto.own = true
        defer { Proto.own = false }
        try await results(scheme: scheme)
        try await menu(scheme: scheme)
        try await options(scheme: scheme)
        try await dropZone(scheme: scheme)
        try await windows(scheme: scheme)
    }
}

/// Reads one pixel of a capture as an sRGB colour.
enum InkProbe {
    static func color(in image: CGImage, x: Double, y: Double) -> RGBA? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Draw the image so that the wanted pixel lands on the context's one pixel (converted to sRGB).
        context.draw(image, in: CGRect(x: -x, y: -(Double(image.height) - y - 1), width: Double(image.width), height: Double(image.height)))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: 4)
        return RGBA(UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2]))
    }
}
