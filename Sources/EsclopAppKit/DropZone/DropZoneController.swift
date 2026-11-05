// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shows the drop zone while files are dragged anywhere, as Clop does: a global mouse-drag monitor
// notices the drag, the drag pasteboard (read off the main thread, it is a slow XPC round trip)
// says whether it carries files L'Esclop can optimise, and mouse-up hides the zone again.

import AppKit
import EsclopCore
import SwiftUI

/// The panel's content view: accepts file drops and tracks Command for "harder".
final class DropTargetView: NSView {
    var state: DropZoneState?
    var onDrop: (([URL], Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        update(hovering: true)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        update(hovering: true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        update(hovering: false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(urls, NSEvent.modifierFlags.contains(.command))
        return true
    }

    private func update(hovering: Bool) {
        state?.hovering = hovering
        state?.harder = NSEvent.modifierFlags.contains(.command)
    }
}

@MainActor
final class DropZoneController {
    private let model: AppModel
    private let state = DropZoneState()
    private let panel: FloatingPanel
    private let target: DropTargetView
    private let resultsFrame: () -> CGRect?
    private var monitors: [Any] = []
    private let queue = DispatchQueue(label: "dev.esclop.app.drag", qos: .userInteractive)
    private var resolving = false
    private var lastChangeCount = -1

    init(model: AppModel, resultsFrame: @escaping () -> CGRect?) {
        self.model = model
        self.resultsFrame = resultsFrame
        target = DropTargetView(frame: .zero)
        let hosting = NSHostingView(rootView: DropZoneView(state: state).padding(Metrics.screenMargin))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        target.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: target.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: target.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: target.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: target.bottomAnchor),
        ])
        panel = FloatingPanel(content: target)
        panel.title = "L'Esclop drop zone"
        panel.level = .popUpMenu
        target.state = state
        target.onDrop = { [weak self] urls, harder in
            guard let self else { return }
            self.hide()
            self.model.optimiseDropped(urls, harder: harder)
        }
    }

    func start() {
        guard monitors.isEmpty else { return }
        // Whatever the last drag left on the drag pasteboard is not a new drag.
        lastChangeCount = NSPasteboard(name: .drag).changeCount
        if let drag = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dragged() }
        }) { monitors.append(drag) }
        if let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseUp() }
        }) { monitors.append(up) }
        if let flags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            let command = event.modifierFlags.contains(.command)
            MainActor.assumeIsolated { self?.state.harder = command }
        }) { monitors.append(flags) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        hide()
    }

    private func dragged() {
        guard !resolving, EsclopSettings.enableDragAndDrop.value(in: model.settings) else { return }
        resolving = true
        let last = lastChangeCount
        queue.async { [weak self] in
            let pasteboard = NSPasteboard(name: .drag)
            let count = pasteboard.changeCount
            let files: Int? = count == last ? nil : Self.mediaFileCount(on: pasteboard)
            Task { @MainActor in
                guard let self else { return }
                self.resolving = false
                guard let files else { return }
                self.lastChangeCount = count
                if files > 0 { self.show(files: files) }
            }
        }
    }

    nonisolated static func mediaFileCount(on pasteboard: NSPasteboard) -> Int {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { url in
            var isDirectory: ObjCBool = false
            return MediaKind.of(url) != nil
                || (FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        }.count
    }

    private func mouseUp() {
        // A drop calls performDragOperation first; this only hides a zone nobody dropped on.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.hide()
        }
    }

    private func show(files: Int) {
        state.fileCount = files
        state.hovering = false
        state.harder = NSEvent.modifierFlags.contains(.command)
        let screen = FloatingPanelController.targetScreen(followCursor: model.followCursorScreen)
        guard let visible = screen?.visibleFrame else { return }
        let size = target.fittingSize
        var frame = FloatingPanelController.frame(for: size, corner: model.corner, in: visible)
        if let results = resultsFrame(), visible.intersects(results) {
            // Above the result cards (below them in a top corner), never on top of them.
            frame.origin.y = model.corner.isTop ? results.minY - size.height + Metrics.screenMargin : results.maxY - Metrics.screenMargin
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel.orderOut(nil)
        state.hovering = false
    }
}
