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
            ("working", .working(progress: 0.62, left: "4 s")), ("done", .done), ("hover", .hover), ("aggressive", .aggressive),
            ("already", .already), ("restored", .restored), ("failed", .failed), ("failed-open", .failedOpen), ("uploaded", .uploaded),
        ]
        let sheet = VStack(spacing: 20) {
            ForEach(0 ..< 3, id: \.self) { row in
                HStack(alignment: .bottom, spacing: 20) {
                    ForEach(states[row * 3 ..< row * 3 + 3], id: \.0) { ProtoResultCard(state: $0.1) }
                }
            }
        }
        try await ProtoRender.floating(sheet, size: CGSize(width: 760, height: 660), name: "result-states", scheme: scheme)
        try await ProtoRender.floating(ProtoResultCard(state: .done), size: CGSize(width: 300, height: 240), name: "result-busy", scheme: scheme, busy: true)
        try await ProtoRender.floating(ProtoStack(), size: CGSize(width: 300, height: 620), name: "result-stack", scheme: scheme, alignment: .bottomTrailing)
        try await ProtoRender.floating(ProtoDetailCard(), size: CGSize(width: 400, height: 470), name: "result-detail", scheme: scheme)
        try await ProtoRender.floating(ProtoNotice(), size: CGSize(width: 360, height: 110), name: "result-notice", scheme: scheme)
    }

    @Test(arguments: schemes)
    func menu(scheme: ColorScheme) async throws {
        let panels = HStack(alignment: .top, spacing: 20) {
            ProtoMenuPanel()
            ProtoMenuPanel(mode: .paused)
            ProtoMenuPanel(mode: .empty)
        }
        try await ProtoRender.floating(panels, size: CGSize(width: 1060, height: 420), name: "menu-panel", scheme: scheme, alignment: .top)
        try await ProtoRender.floating(
            HStack(alignment: .top, spacing: 20) { ProtoMenuPanel(catalan: true); ProtoPauseMenu() },
            size: CGSize(width: 600, height: 420), name: "menu-panel-ca", scheme: scheme, alignment: .top
        )
        try await ProtoRender.floating(ProtoMenuPanel(), size: CGSize(width: 380, height: 420), name: "menu-panel-busy", scheme: scheme, busy: true, alignment: .top)
        try await ProtoRender.floating(ProtoGlyphStrip(), size: CGSize(width: 520, height: 120), name: "glyph", scheme: scheme)
    }

    @Test(arguments: schemes)
    func options(scheme: ColorScheme) async throws {
        let tabs = HStack(alignment: .top, spacing: 20) {
            ProtoOptions(tab: .format)
            ProtoOptions(tab: .size)
            ProtoOptions(tab: .share)
        }
        try await ProtoRender.floating(tabs, size: CGSize(width: 1120, height: 500), name: "options", scheme: scheme, alignment: .top)
        let catalan = HStack(alignment: .top, spacing: 20) {
            ProtoOptions(tab: .format, catalan: true)
            ProtoOptions(tab: .share, catalan: true)
        }
        try await ProtoRender.floating(catalan, size: CGSize(width: 760, height: 500), name: "options-ca", scheme: scheme, alignment: .top)
    }

    @Test(arguments: schemes)
    func dropZone(scheme: ColorScheme) async throws {
        let zones = VStack(alignment: .trailing, spacing: 26) {
            ProtoDropZone(mode: .idle)
            ProtoDropZone(mode: .target)
            ProtoDropZone(mode: .preset)
            ProtoDropZone(mode: .aggressive, presets: false)
            ProtoDropZone(mode: .idle, catalan: true)
        }
        try await ProtoRender.floating(zones, size: CGSize(width: 620, height: 660), name: "drop-zone", scheme: scheme)
    }

    @Test(arguments: schemes)
    func windows(scheme: ColorScheme) async throws {
        try await ProtoRender.window(NavigationStack { ProtoBatch() }, size: CGSize(width: 560, height: 480), name: "batch", scheme: scheme, title: "9 files")
        try await ProtoRender.window(NavigationStack { ProtoBatch(running: true) }, size: CGSize(width: 560, height: 480), name: "batch-running", scheme: scheme, title: "9 files")
        try await ProtoRender.window(ProtoSettings(pane: .general), size: CGSize(width: 760, height: 560), name: "settings-general", scheme: scheme)
        try await ProtoRender.window(ProtoSettings(pane: .automatic), size: CGSize(width: 760, height: 560), name: "settings-automatic", scheme: scheme)
        try await ProtoRender.window(ProtoSettings(pane: .quality), size: CGSize(width: 760, height: 560), name: "settings-quality", scheme: scheme)
        try await ProtoRender.window(ProtoOnboarding(step: .tryIt), size: CGSize(width: 600, height: 480), name: "onboarding-1-try", scheme: scheme)
        try await ProtoRender.window(ProtoOnboarding(step: .tried), size: CGSize(width: 600, height: 480), name: "onboarding-2-tried", scheme: scheme)
        try await ProtoRender.window(ProtoOnboarding(step: .menuBar), size: CGSize(width: 600, height: 480), name: "onboarding-3-menu-bar", scheme: scheme)
        try await ProtoRender.window(ProtoPipeline(), size: CGSize(width: 820, height: 560), name: "pipeline", scheme: scheme)
        try await ProtoRender.window(NavigationStack { ProtoCompare() }, size: CGSize(width: 820, height: 560), name: "compare", scheme: scheme, title: "Beach 01.jpg")
    }
}
