// SPDX-License-Identifier: GPL-3.0-or-later
//
// Finder's Quick Actions, through Services as Clop does: "Optimise with L'Esclop", "Optimise
// Harder", "Convert to WebP" and "Run a Pipeline…". The menu items are declared in Info.plist
// (NSServices, only for images, videos, audio and PDFs); macOS sends the chosen files here,
// and they go through the app's usual jobs: floating results, or the batch window from
// `batchWindowFrom` files. Nothing opens. "Run a Pipeline…" offers the pipelines whose triggers
// include Finder's right-click menu.

import AppKit
import EsclopCore
import EsclopIPC
import EsclopPipelines

@MainActor
final class FinderServices: NSObject {
    enum Action: Equatable, Sendable {
        case optimise
        case optimiseHarder
        case convertToWebP
        case runPipeline
    }

    let model: AppModel
    let pipelines: () -> [Pipeline]
    /// Shows the pipeline choice; a menu at the pointer in the app, recorded in tests.
    var choosePipeline: @MainActor ([Pipeline], @escaping (Pipeline) -> Void) -> Void = FinderServices.popUpMenu

    init(model: AppModel, pipelines: @escaping () -> [Pipeline]) {
        self.model = model
        self.pipelines = pipelines
    }

    // MARK: Service messages (NSMessage in Info.plist)

    @objc func optimiseFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        handle(.optimise, files: Self.files(on: pasteboard))
    }

    @objc func optimiseFilesHarder(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        handle(.optimiseHarder, files: Self.files(on: pasteboard))
    }

    @objc func convertFilesToWebP(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        handle(.convertToWebP, files: Self.files(on: pasteboard))
    }

    @objc func runPipelineOnFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        handle(.runPipeline, files: Self.files(on: pasteboard))
    }

    static func files(on pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// The pipelines Finder's "Run a Pipeline…" offers.
    var finderPipelines: [Pipeline] {
        pipelines().filter { $0.triggers.contains(.rightClick) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Handling

    func handle(_ action: Action, files: [URL]) {
        let media = PathInput.expand(files, recursive: true).filter { MediaKind.of($0) != nil }
        guard !media.isEmpty else {
            return model.notice(Strings.text("Nothing to optimise"), Strings.text("Choose images, videos, PDFs or audio files in Finder."))
        }
        switch action {
        case .optimise:
            model.optimise(media, origin: .finder)
        case .optimiseHarder:
            model.optimise(media, origin: .finder, aggressive: true)
        case .convertToWebP:
            let images = media.filter { MediaKind.of($0) == .image }
            guard !images.isEmpty else {
                return model.notice(Strings.text("Nothing to convert"), Strings.text("Only images convert to WebP."))
            }
            var choice = OptimiseChoice()
            choice.format = .webp
            model.optimise(images, origin: .finder, aggressive: false, copy: nil) { choice.apply(to: &$0.request) }
        case .runPipeline:
            let offered = finderPipelines
            switch offered.count {
            case 0:
                model.notice(
                    Strings.text("No pipeline for Finder yet"),
                    Strings.text("Turn on “Finder’s right-click menu” for a pipeline in the pipeline editor.")
                )
            case 1:
                model.runPipeline(offered[0].name, on: media)
            default:
                choosePipeline(offered) { [weak self] pipeline in self?.model.runPipeline(pipeline.name, on: media) }
            }
        }
    }

    /// A menu at the pointer, the way a context menu shows: no window opens.
    static func popUpMenu(_ pipelines: [Pipeline], _ chosen: @escaping (Pipeline) -> Void) {
        let menu = NSMenu(title: Strings.text("Run a pipeline"))
        let target = MenuTarget(chosen)
        for pipeline in pipelines {
            let item = NSMenuItem(title: pipeline.name, action: #selector(MenuTarget.choose(_:)), keyEquivalent: "")
            item.representedObject = pipeline
            item.target = target
            if let icon = pipeline.icon { item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) }
            menu.addItem(item)
        }
        NSApp.activate()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        withExtendedLifetime(target) {}
    }

    private final class MenuTarget: NSObject {
        let chosen: (Pipeline) -> Void
        init(_ chosen: @escaping (Pipeline) -> Void) { self.chosen = chosen }
        @objc func choose(_ item: NSMenuItem) {
            if let pipeline = item.representedObject as? Pipeline { chosen(pipeline) }
        }
    }
}
