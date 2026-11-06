// SPDX-License-Identifier: GPL-3.0-or-later
//
// Renders the options popover's states, light and dark. ImageRenderer cannot draw AppKit-backed
// controls (segmented pickers, sliders, switches, text fields), so these draw an NSHostingView
// into a bitmap instead. The popover's material is a flat window background here. Set
// ESCLOP_RENDER_DIR to keep the PNGs.

import AppKit
import EsclopCore
@testable import EsclopAppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers

@MainActor
@Suite struct OptionsRenderTests {
    let renders = RenderTests()

    func card(_ phase: ResultCard.Phase, source: URL = RenderTests.shot, origin: FileOrigin = .screenshot, input: UTType = .png) -> ResultCard {
        let card = renders.card(phase, source: source)
        card.fileOrigin = origin
        card.inputType = input.identifier
        return card
    }

    func model(_ card: ResultCard, harness: Harness, facts: FileFacts = FileFacts(width: 2940, height: 1912), change: (OptionsModel) -> Void = { _ in }) -> OptionsModel {
        harness.model.add(card)
        let model = OptionsModel(card: card, app: harness.model)
        model.facts = facts
        change(model)
        return model
    }

    /// Draws the popover at its own size, in an appearance, into a PNG.
    @discardableResult
    func snapshot(_ model: OptionsModel, name: String, scheme: ColorScheme) async throws -> CGSize {
        try await snapshot(OptionsPopover(model: model), name: name, scheme: scheme)
    }

    @discardableResult
    func snapshot(_ view: some View, name: String, scheme: ColorScheme) async throws -> CGSize {
        let host = NSHostingView(rootView: view
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(20)
            .background(Color(nsColor: scheme == .dark ? Palette.color(0x1E3A47) : Palette.color(0x7FA3B5)))
            .environment(\.colorScheme, scheme))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        // Let the measured heights settle (the scroll area sizes itself to its content).
        for _ in 0 ..< 4 {
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
        }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: RenderTests.folder, withIntermediateDirectories: true)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: RenderTests.folder.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
        return CGSize(width: host.bounds.width - 40, height: host.bounds.height - 40)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func optimiseTab(scheme: ColorScheme) async throws {
        let harness = Harness()
        let suggestion = model(card(.done(renders.saved())), harness: harness)
        let size = try await snapshot(suggestion, name: "options-suggestion", scheme: scheme)
        #expect(size.width == OptionsType.width)
        #expect(size.height <= OptionsType.maxHeight)

        let expanded = model(card(.done(renders.saved())), harness: harness) { model in
            model.showsFormatOptions = true
            let sizes: [OutputFormat: Int] = [.png: 612_000, .jpeg: 320_000, .webp: 410_000, .avif: 285_000, .heic: 360_000, .gif: 1_100_000]
            for (format, bytes) in sizes { model.estimates[model.request(format: format)] = bytes }
            model.estimates[model.qualityRequest] = 612_000
        }
        let tall = try await snapshot(expanded, name: "options-format", scheme: scheme)
        #expect(tall.height <= OptionsType.maxHeight, "never taller than 560 pt: the content scrolls")

        let ruled = card(.done(renders.saved(after: 410_000)))
        ruled.choice = OptimiseChoice(format: .webp)
        ruled.appliedRule = ClipboardRule(origin: .screenshot, inputType: UTType.png.identifier, choice: ruled.choice)
        try await snapshot(model(ruled, harness: harness), name: "options-rule", scheme: scheme)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func sizeAndShareTabs(scheme: ColorScheme) async throws {
        let harness = Harness()
        let size = model(card(.done(renders.saved())), harness: harness) { model in
            model.tab = .size
            model.scale = 0.5
            model.estimates[model.scaleRequest] = 180_000
            model.startCrop(aspect: .ratio(16, 9))
            if let request = model.cropRequest { model.estimates[request] = 520_000 }
        }
        try await snapshot(size, name: "options-size", scheme: scheme)
        let share = model(card(.done(renders.saved())), harness: harness) { $0.tab = .share }
        try await snapshot(share, name: "options-share", scheme: scheme)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func otherKinds(scheme: ColorScheme) async throws {
        let harness = Harness()
        let recording = card(.done(renders.saved(RenderTests.video, before: 84_000_000, after: 19_000_000, kind: .video)), source: RenderTests.video, origin: .screenRecording, input: .quickTimeMovie)
        try await snapshot(model(recording, harness: harness, facts: FileFacts(width: 3840, height: 2160, duration: 134)), name: "options-video", scheme: scheme)

        let pdf = URL(fileURLWithPath: "/tmp/Dossier.pdf")
        let document = card(.done(renders.saved(pdf, before: 12_800_000, after: 3_100_000, kind: .pdf)), source: pdf, origin: .pdfExport, input: .pdf)
        try await snapshot(model(document, harness: harness, facts: FileFacts(pages: 28)), name: "options-pdf", scheme: scheme)

        let memo = URL(fileURLWithPath: "/tmp/Notes.m4a")
        let audio = card(.done(renders.saved(memo, before: 18_000_000, after: 6_200_000, kind: .audio)), source: memo, origin: .voiceMemo, input: .mpeg4Audio)
        try await snapshot(model(audio, harness: harness, facts: FileFacts(duration: 522)) { model in
            model.tab = .sound
            model.estimates[EstimateRequest(choice: model.card.choice)] = 6_200_000
        }, name: "options-sound", scheme: scheme)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func clipboardRulesInSettings(scheme: ColorScheme) async throws {
        let harness = Harness()
        try harness.model.rules.save(ClipboardRule(origin: .screenshot, inputType: UTType.png.identifier, choice: OptimiseChoice(format: .webp)))
        try harness.model.rules.save(ClipboardRule(origin: .photos, inputType: UTType.heic.identifier, choice: OptimiseChoice(format: .jpeg, stripMetadata: true)))
        let settings = SettingsViewModel(provider: harness.model.service.context.settings)
        let rules = try #require(settings.descriptor(EsclopSettings.clipboardRules.key))
        #expect(SettingPresentation.control(for: rules) == .clipboardRules)
        #expect(settings.pane(of: rules.key) == .clipboard, "the rules sit in Settings › Clipboard")
        let hover = try #require(settings.descriptor(EsclopSettings.hoverButtons.key))
        #expect(SettingsPane.pane(for: SettingsViewModel.section(of: hover)) == .floatingResults)
        let label = AnyView(SettingLabel(title: rules.title, summary: rules.summary))
        let list = Form { ClipboardRuleList(descriptor: rules, model: settings, label: label) }.formStyle(.grouped).frame(width: 480, height: 240)
        try await snapshot(list, name: "settings-clipboard-rules", scheme: scheme)

        // Search finds the rules and the hover buttons.
        settings.query = "clipboard rules"
        #expect(settings.hits.contains { $0.id == EsclopSettings.clipboardRules.key && $0.pane == .clipboard })
        settings.query = "hover buttons"
        #expect(settings.hits.contains { $0.id == EsclopSettings.hoverButtons.key && $0.pane == .floatingResults })

        // Deleting goes through the registry, like any other setting.
        let stored = EsclopSettings.clipboardRules.value(in: harness.settings.store)
        settings.set(rules.key, to: .array(Array(stored.dropFirst()).map { .string($0) }))
        #expect(harness.model.rules.all.map(\.origin) == [.photos])
    }
}
