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
    /// Asks the question and says whether to go on; an alert in the app, recorded in tests.
    var confirm: @MainActor (_ question: String, _ button: String) -> Bool = FinderServices.ask

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
        // ponytail: a folder is listed on the main actor, all of it; list it off the main actor if
        // a large folder (a whole Pictures folder) shows as a hang.
        let media = PathInput.expand(files, recursive: true).filter { MediaKind.of($0) != nil }
        guard !media.isEmpty else {
            return model.notice(Strings.text("Nothing to optimise"), Strings.text("Choose images, videos, PDFs or audio files in Finder."))
        }
        // A pipeline is asked about once there is one to run.
        guard action == .runPipeline || confirmed(action, media, in: files) else { return }
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
                guard confirmed(action, media, in: files) else { return }
                run(offered[0], on: media)
            default:
                guard confirmed(action, media, in: files) else { return }
                choosePipeline(offered) { [weak self] pipeline in self?.run(pipeline, on: media) }
            }
        }
    }

    /// A folder can hold far more than the person had in mind, and the files change in place:
    /// past the batch threshold, ask once. A selection of files only goes ahead as it is.
    func confirmed(_ action: Action, _ media: [URL], in selection: [URL]) -> Bool {
        let count = action == .convertToWebP ? media.filter { MediaKind.of($0) == .image }.count : media.count
        guard count > model.batchThreshold, let place = Self.folders(in: selection) else { return true }
        switch action {
        case .optimise, .optimiseHarder:
            return confirm(Strings.format("Optimise %d files in %@?", count, place), Strings.text("Optimise"))
        case .convertToWebP:
            return confirm(Strings.format("Convert %d images in %@ to WebP?", count, place), Strings.text("Convert"))
        case .runPipeline:
            return confirm(Strings.format("Run a pipeline on %d files in %@?", count, place), Strings.text("Continue"))
        }
    }

    /// The folder's name, or "3 folders", when the selection holds folders.
    static func folders(in selection: [URL]) -> String? {
        let folders = selection.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        guard !folders.isEmpty else { return nil }
        return folders.count == 1 ? folders[0].lastPathComponent : Strings.format("%d folders", folders.count)
    }

    static func ask(_ question: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = Strings.text("Every image, video, PDF and audio file inside, subfolders included.")
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: Strings.text("Cancel"))
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Like a plain Finder optimisation: floating results, or the batch window from
    /// `batchWindowFrom` files, and automatic uploads for Finder.
    func run(_ pipeline: Pipeline, on files: [URL]) {
        model.optimise(files, origin: .finder, copy: nil, pipeline: { _ in pipeline })
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
