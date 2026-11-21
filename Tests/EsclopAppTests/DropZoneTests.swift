// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EsclopCore
@testable import EsclopAppKit
import Foundation
import Testing
import UniformTypeIdentifiers

/// A drag carrying files, as Finder sends one.
final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard

    @MainActor
    init(_ urls: [URL]) {
        draggingPasteboard = NSPasteboard.withUniqueName()
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects(urls as [NSURL])
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

@MainActor
@Suite struct DropZoneTests {
    @Test func dropTargetHandsTheFilesOver() throws {
        let temp = TempDir()
        let file = temp.file("a.png")
        let view = DropTargetView(frame: .zero)
        let state = DropZoneState(fileCount: 1)
        // The plain target under the drag's point (a frameless view: the origin).
        state.frames[DropZoneState.plainTarget] = CGRect(x: -1, y: -1, width: 2, height: 2)
        view.state = state
        var dropped: [URL] = []
        var zone: String? = "unset"
        view.onDrop = { intake, _, _, target in dropped = intake.files; zone = target }
        let drag = FakeDrag([file])
        defer { drag.draggingPasteboard.releaseGlobally() }
        #expect(view.draggingEntered(drag) == .copy)
        #expect(state.hovering)
        view.draggingExited(drag)
        #expect(!state.hovering)
        #expect(view.performDragOperation(drag))
        #expect(dropped.map(\.lastPathComponent) == ["a.png"])
        #expect(zone == nil, "the plain target optimises")
        #expect(DropZoneController.media(on: drag.draggingPasteboard).count == 1)
    }

    @Test func dragsWithoutMediaDoNotCount() throws {
        let temp = TempDir()
        let drag = FakeDrag([temp.file("notes.txt"), temp.file("b.mov")])
        defer { drag.draggingPasteboard.releaseGlobally() }
        let media = DropZoneController.media(on: drag.draggingPasteboard)
        #expect(media.count == 1)
        #expect(media.kinds == [.video])
    }

    /// A browser drag: an image's address is taken, a page's link is not.
    @Test func aBrowserDragOffersTheImageAddressNotThePageLink() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(string: "https://example.com/cat.jpg")! as NSURL])
        #expect(DropIntake(pasteboard: pasteboard).addresses.map(\.lastPathComponent) == ["cat.jpg"])
        let media = DropZoneController.media(on: pasteboard)
        #expect(media.count == 1 && media.kinds == [.image])
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(string: "https://example.com/article")! as NSURL])
        #expect(DropIntake(pasteboard: pasteboard).isEmpty)
        #expect(DropZoneController.media(on: pasteboard).count == 0)
    }

    /// Promised files (Photos, Mail) and web addresses become local files before they are
    /// optimised, together when they come together.
    @Test func promisesAndAddressesArriveAsLocalFiles() async throws {
        let temp = TempDir()
        let intake = DropIntake(promises: [FakePromise(names: ["photo.png", "clip.mov"])], addresses: [URL(string: "https://example.com/a.jpg")!])
        #expect(intake.remoteMedia.count == 3 && intake.remoteMedia.kinds == [.image, .video])
        let downloads = temp.url.appendingPathComponent("downloads")
        let handed = Handed()
        // The function `resolve` returns stops it; these drops run to the end.
        _ = intake.resolve(into: temp.url, gather: .seconds(30), download: { address in
            let file = try Paths.ensure(downloads).appendingPathComponent(address.lastPathComponent)
            try pngData().write(to: file)
            return file
        }, deliver: handed.take)
        #expect(await eventually { handed.batches.count == 1 })
        #expect(handed.batches[0].files.map(\.lastPathComponent).sorted() == ["a.jpg", "clip.mov", "photo.png"])
        #expect(handed.batches[0].failures == 0)
        #expect(handed.batches[0].files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        // A failed download leaves the others to go ahead.
        let failing = Handed()
        _ = DropIntake(promises: [FakePromise(names: ["b.png"])], addresses: [URL(string: "https://example.com/c.jpg")!])
            .resolve(into: temp.url, gather: .seconds(30), download: { _ in throw EsclopError.other("offline") }, deliver: failing.take)
        #expect(await eventually { failing.batches.count == 1 })
        #expect(failing.batches[0].files.map(\.lastPathComponent) == ["b.png"] && failing.batches[0].failures == 1)
        // A promise never kept holds back nothing: the dropped file goes after the pause.
        let stuck = Handed()
        _ = DropIntake(files: [temp.file("here.png")], promises: [FakePromise(names: ["never.png"], delivers: false)])
            .resolve(into: temp.url, gather: .milliseconds(100), deliver: stuck.take)
        #expect(await eventually { stuck.batches.count == 1 })
        #expect(stuck.batches[0].files.map(\.lastPathComponent) == ["here.png"])
    }

    @MainActor final class Handed {
        var batches: [(files: [URL], failures: Int)] = []
        func take(_ files: [URL], _ failures: [any Error]) { batches.append((files, failures.count)) }
    }

    @Test func aPromisedFileIsOptimisedAsADroppedOne() async {
        let harness = Harness()
        harness.model.takeDrop(DropIntake(promises: [FakePromise(names: ["from-photos.png"])]), harder: false, keepOriginals: false, zone: nil)
        #expect(await eventually { harness.model.cards.first?.result != nil })
        #expect(harness.requests.requests.first?.origin == .dropZone)
    }

    /// ⌥ at the drop: the results go beside the originals, which stay byte for byte, on the plain
    /// tile and on a preset zone (its pipeline optimises in place, so it runs on a copy).
    @Test func optionKeepsTheOriginalsByteForByte() async throws {
        let harness = Harness()
        let file = harness.temp.png("keep.png")
        let original = try Data(contentsOf: file)
        harness.model.optimiseDropped([file], harder: false, keepOriginals: true)
        #expect(await eventually { harness.model.cards.first?.result != nil })
        let result = try #require(harness.model.cards.first?.result)
        #expect(result.output != file && result.output.deletingLastPathComponent() == file.deletingLastPathComponent(), "beside the original")
        #expect(try Data(contentsOf: file) == original)
        // Another choice on the card runs again beside the original, not over it.
        let card = try #require(harness.model.cards.first)
        harness.model.reprocess(card, choice: OptimiseChoice(compression: .aggressive))
        #expect(await eventually { harness.requests.requests.count == 2 && card.result != nil })
        #expect(harness.requests.requests.last?.location == .sameFolder)
        #expect(try Data(contentsOf: file) == original)

        try harness.model.service.context.pipelines.save(PresetZonesTests.pipeline("Shrink", PresetZonesTests.everything))
        let zoned = harness.temp.png("zone.png")
        harness.model.runPresetZone("Shrink", on: [zoned], keepOriginals: true)
        #expect(await eventually { harness.model.cards.count == 2 && harness.model.cards.allSatisfy { $0.result != nil } })
        #expect(try Data(contentsOf: zoned) == original)
        let zonedResult = try #require(harness.model.cards.last?.result)
        #expect(zonedResult.source.deletingLastPathComponent() == zoned.deletingLastPathComponent() && zonedResult.source != zoned, "the copy sits beside")
        #expect(FileManager.default.fileExists(atPath: zonedResult.output.path), "the optimised copy is the result")

        // A pipeline that writes elsewhere leaves no copy behind; its result starts from the original.
        try harness.model.service.context.pipelines.save(PresetZonesTests.pipeline("Beside", "convert(to: webp)"))
        let converted = harness.temp.png("beside.png")
        let folder = converted.deletingLastPathComponent()
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        harness.model.runPresetZone("Beside", on: [converted], keepOriginals: true)
        #expect(await eventually { harness.model.cards.count == 3 && harness.model.cards.allSatisfy { $0.result != nil } })
        let besideResult = try #require(harness.model.cards.last?.result)
        #expect(besideResult.source == converted)
        #expect(try Data(contentsOf: converted) == original)
        let added = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)).subtracting(before)
        #expect(added == [besideResult.output.lastPathComponent], "only the pipeline's output is new")

        // Without ⌥ the setting's default, in place, still applies.
        let plain = harness.temp.png("plain.png")
        harness.model.optimiseDropped([plain], harder: false)
        #expect(await eventually { harness.model.cards.count == 4 && harness.model.cards.allSatisfy { $0.result != nil } })
        #expect(try Data(contentsOf: plain) != original)
    }

    /// With `dropZoneOnlyWithOption`, a drag shows nothing until ⌥ is tapped; the zone then opens
    /// under the pointer, and the next tap hides it. ⌥ held, or with another modifier, is no tap.
    @Test func theSettingLeavesTheZoneToAnOptionTap() throws {
        let harness = Harness()
        try EsclopSettings.dropZoneOnlyWithOption.set(true, in: harness.settings.store)
        let controller = DropZoneController(model: harness.model, resultsFrame: { nil })
        defer { controller.hide() }
        let start = Date()
        func tap(at seconds: TimeInterval, held: TimeInterval = 0.1, with other: NSEvent.ModifierFlags = []) {
            controller.modifiersChanged(.option, at: start + seconds)
            if !other.isEmpty { controller.modifiersChanged([.option, other], at: start + seconds + held / 2) }
            controller.modifiersChanged([], at: start + seconds + held)
        }
        tap(at: 0)
        #expect(!controller.isVisible, "no drag under way")
        controller.dragCarries((count: 1, kinds: [.image]))
        #expect(!controller.isVisible)
        tap(at: 1, held: 1)
        tap(at: 3, with: .command)
        #expect(!controller.isVisible)
        tap(at: 5)
        #expect(controller.isVisible && controller.state.atPointer)
        #expect(controller.state.hint == "Tap ⌥ to hide")
        tap(at: 7)
        #expect(!controller.isVisible)

        // Without the setting, the drag shows the zone at the corner, and a tap moves it to the pointer.
        try EsclopSettings.dropZoneOnlyWithOption.set(false, in: harness.settings.store)
        controller.dragCarries((count: 1, kinds: [.image]))
        #expect(controller.isVisible && !controller.state.atPointer)
        #expect(controller.state.hint == "Hold ⌘ to optimise harder")
        tap(at: 9)
        #expect(controller.isVisible && controller.state.atPointer)
    }

    /// Under the pointer, the zone opens just below it, inside the screen.
    @Test func theZoneOpensBelowThePointer() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 300, height: 160)
        let frame = DropZoneController.frame(for: size, under: CGPoint(x: 500, y: 400), in: visible)
        #expect(frame.midX == 500 && frame.maxY - Metrics.screenMargin < 400)
        // Near the bottom of the screen, above the pointer instead.
        let low = DropZoneController.frame(for: size, under: CGPoint(x: 990, y: 10), in: visible)
        #expect(visible.contains(low) && low.minY + Metrics.screenMargin > 10)
    }

    /// Over a preset zone the line names its pipeline, and ⌘, which a pipeline does not use, is not offered.
    @Test func overAPresetZoneTheLineNamesItsPipeline() {
        let state = DropZoneState(fileCount: 2, harder: true, zones: [PresetZone(name: "to WebP")])
        #expect(state.title == "Drop to optimise harder" && state.hint == "With the aggressive settings")
        state.hover("to WebP")
        #expect(state.title == "Drop to run “to WebP”")
        #expect(state.hint.isEmpty)
        state.keepOriginals = true
        #expect(state.hint == "The originals stay as they are")
        state.hover(DropZoneState.plainTarget)
        #expect(state.title == "Drop to optimise harder" && state.hint == "The originals stay as they are")
    }

    /// A folder counts the media inside it, deep too, and their kinds pick the preset zones.
    @Test func aFolderCountsTheMediaInside() {
        let temp = TempDir()
        _ = temp.file("shoot/a.png")
        _ = temp.file("shoot/deep/b.mov")
        _ = temp.file("shoot/notes.txt")
        let media = DropZoneController.media(in: [temp.url.appendingPathComponent("shoot")])
        #expect(media.count == 2 && media.kinds == [.image, .video])
        #expect(PresetZones.shown([PresetZone(name: "Images", kinds: [.image])], dragged: media.kinds).isEmpty)
        #expect(DropZoneController.media(in: [temp.url.appendingPathComponent("empty-or-missing")]).count == 0)
        // Past the scan's limit with no media found yet, the folder still shows the zone.
        _ = temp.file("big/1.txt")
        _ = temp.file("big/2.txt")
        #expect(DropZoneController.media(in: [temp.url.appendingPathComponent("big")], limit: 1) == (count: 1, kinds: []))
    }

    @Test func panelsAnchorToTheirCorner() {
        let visible = CGRect(x: 0, y: 84, width: 1920, height: 966)
        let size = CGSize(width: 332, height: 116)
        #expect(FloatingPanelController.frame(for: size, corner: .bottomRight, in: visible) == CGRect(x: 1588, y: 84, width: 332, height: 116))
        #expect(FloatingPanelController.frame(for: size, corner: .topLeft, in: visible) == CGRect(x: 0, y: 934, width: 332, height: 116))
    }
}

/// Files another app promises, written when asked for, off the main thread as a real source does.
struct FakePromise: FilePromise {
    var names: [String]
    var delivers = true

    var promisedTypes: [String] { names.map { UTType(filenameExtension: ($0 as NSString).pathExtension)?.identifier ?? UTType.data.identifier } }

    func receive(into folder: URL, reader: @escaping @Sendable (Result<URL, any Error>) -> Void) {
        for name in names where delivers {
            let file = folder.appendingPathComponent(name)
            DispatchQueue.global().async {
                do {
                    try pngData().write(to: file)
                    reader(.success(file))
                } catch {
                    reader(.failure(error))
                }
            }
        }
    }
}

@MainActor @Suite struct OpenWithTests {
    /// Open With and a drop on the app's icon reach `open` as file URLs: they go the drop zone's
    /// way (here a file it does not handle, so nothing runs and the drop's notice says why).
    @Test func openedFilesAreADrop() async throws {
        let services = AppServices(settings: TestSettings().store)
        let temp = TempDir()
        // Before launch finishes (Open With on a closed app) the files wait for `start`.
        services.open([temp.file("notes.txt", bytes: 10)])
        #expect(services.model.cards.isEmpty)
        services.releaseHeldFiles()
        #expect(services.model.cards.last?.presentation.capsule == .notice(title: "Nothing to optimise", detail: "Drop images, videos, PDFs or audio files."))
        services.open([temp.file("more.txt", bytes: 10)])
        #expect(services.model.cards.count == 1, "once started, files go at once")
    }
}
