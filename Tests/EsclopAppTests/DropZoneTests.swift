// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
@testable import EsclopAppKit
import Foundation
import Testing

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
    var draggingSourceOperationMask: NSDragOperation { .copy }
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
        view.onDrop = { urls, _, target in dropped = urls; zone = target }
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

    @Test func panelsAnchorToTheirCorner() {
        let visible = CGRect(x: 0, y: 84, width: 1920, height: 966)
        let size = CGSize(width: 332, height: 116)
        #expect(FloatingPanelController.frame(for: size, corner: .bottomRight, in: visible) == CGRect(x: 1588, y: 84, width: 332, height: 116))
        #expect(FloatingPanelController.frame(for: size, corner: .topLeft, in: visible) == CGRect(x: 0, y: 934, width: 332, height: 116))
    }
}
