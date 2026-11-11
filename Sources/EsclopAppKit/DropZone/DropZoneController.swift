// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shows the drop zone while files are dragged anywhere, as Clop does: a global mouse-drag monitor
// notices the drag, the drag pasteboard (read off the main thread, it is a slow XPC round trip)
// says whether it carries files L'Esclop can optimise, and mouse-up hides the zone again. The
// preset zones beside it (PresetZones) run a pipeline on what is dropped on them.

import AppKit
import EsclopCore
import EsclopPipelines
import SwiftUI

/// The panel's content view: accepts file drops, tells which target (the plain zone or a preset
/// zone) a drag is over, and tracks Command for "harder".
final class DropTargetView: NSView {
    var state: DropZoneState?
    /// Files dropped: the preset zone's name, or nil for the plain zone.
    var onDrop: (([URL], Bool, String?) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        state?.hover(nil)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty, let target = target(of: sender) else { return false }
        onDrop?(urls, NSEvent.modifierFlags.contains(.command), target == DropZoneState.plainTarget ? nil : target)
        return true
    }

    /// The target under the drag, in the SwiftUI space the views report their frames in.
    func target(at windowPoint: NSPoint) -> String? {
        let point = convert(windowPoint, from: nil)
        return state?.target(at: CGPoint(x: point.x, y: bounds.height - point.y))
    }

    private func target(of sender: any NSDraggingInfo) -> String? { target(at: sender.draggingLocation) }

    private func update(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let target = target(of: sender)
        state?.hover(target)
        state?.harder = NSEvent.modifierFlags.contains(.command)
        return target == nil ? [] : .copy
    }
}

@MainActor
final class DropZoneController {
    private let model: AppModel
    let state = DropZoneState()
    private let panel: FloatingPanel
    let target: DropTargetView
    private let resultsFrame: () -> CGRect?
    /// The saved pipelines, for the preset zones.
    private let pipelines: () -> [Pipeline]
    private var monitors: [Any] = []
    private let queue = DispatchQueue(label: "dev.esclop.app.drag", qos: .userInteractive)
    private var resolving = false
    private var lastChangeCount = -1
    /// Shown by `esclop://dropzone`: stays until a drop, the link with `?hide`, or a minute.
    private(set) var pinned = false
    private var unpin: Task<Void, Never>?

    init(model: AppModel, pipelines: @escaping () -> [Pipeline] = { [] }, resultsFrame: @escaping () -> CGRect?) {
        self.model = model
        self.pipelines = pipelines
        self.resultsFrame = resultsFrame
        target = DropTargetView(frame: .zero)
        let root = DropZoneView(state: state)
            .padding(Metrics.screenMargin)
            .coordinateSpace(name: DropZoneState.space)
        let hosting = NSHostingView(rootView: root)
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
        target.onDrop = { [weak self] urls, harder, zone in
            guard let self else { return }
            self.hide()
            if let zone {
                self.model.runPresetZone(zone, on: urls)
            } else {
                self.model.optimiseDropped(urls, harder: harder)
            }
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

    // MARK: esclop://dropzone

    /// Handles `esclop://dropzone`, which shows the zone without a drag so it can be looked at and
    /// dropped on: `?kind=image|video|pdf|audio` shows the preset zones for that kind (all of
    /// them without it), `?hide` hides it. False when the link is not one.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard url.scheme == "esclop", url.host() == "dropzone" else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if items.contains(where: { $0.name == "hide" }) {
            hide()
            return true
        }
        let kind = items.first { $0.name == "kind" }?.value.flatMap(MediaKind.init(rawValue:))
        pinned = true
        show(files: 0, kinds: kind.map { [$0] } ?? [])
        unpin?.cancel()
        unpin = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
        return true
    }

    // MARK: Dragging

    private func dragged() {
        guard !resolving, EsclopSettings.enableDragAndDrop.value(in: model.settings) else { return }
        resolving = true
        let last = lastChangeCount
        queue.async { [weak self] in
            let pasteboard = NSPasteboard(name: .drag)
            let count = pasteboard.changeCount
            let media: (count: Int, kinds: Set<MediaKind>)? = count == last ? nil : Self.media(on: pasteboard)
            Task { @MainActor in
                guard let self else { return }
                self.resolving = false
                guard let media else { return }
                self.lastChangeCount = count
                if media.count > 0 { self.show(files: media.count, kinds: media.kinds) }
            }
        }
    }

    /// The files of a kind L'Esclop optimises (and folders) on the drag pasteboard, and their kinds.
    nonisolated static func media(on pasteboard: NSPasteboard) -> (count: Int, kinds: Set<MediaKind>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return media(in: urls)
    }

    nonisolated static func media(in urls: [URL]) -> (count: Int, kinds: Set<MediaKind>) {
        var count = 0
        var kinds = Set<MediaKind>()
        for url in urls {
            if let kind = MediaKind.of(url) {
                count += 1
                kinds.insert(kind)
            } else {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue { count += 1 }
            }
        }
        return (count, kinds)
    }

    private func mouseUp() {
        // A drop calls performDragOperation first; this only hides a zone nobody dropped on.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !self.pinned else { return }
            self.hide()
        }
    }

    /// The preset zones for a drag of these kinds, from the saved pipelines and the setting.
    func zones(for kinds: Set<MediaKind>) -> [PresetZone] {
        let catalog = PresetZones.catalog(saved: pipelines(), order: EsclopSettings.presetZones.value(in: model.settings))
        return PresetZones.shown(catalog, dragged: kinds)
    }

    func show(files: Int, kinds: Set<MediaKind>) {
        state.fileCount = files
        state.hover(nil)
        state.harder = NSEvent.modifierFlags.contains(.command)
        state.zones = zones(for: kinds)
        state.zonesLeading = model.corner.isRight
        let screen = FloatingPanelController.targetScreen(followCursor: model.followCursorScreen)
        guard let visible = screen?.visibleFrame else { return }
        target.layoutSubtreeIfNeeded()
        let size = target.fittingSize
        var frame = FloatingPanelController.frame(for: size, corner: model.corner, in: visible)
        if let results = resultsFrame(), visible.intersects(results) {
            // Above the result cards (below them in a top corner), never on top of them.
            frame.origin.y = model.corner.isTop ? results.minY - size.height + Metrics.screenMargin : results.maxY - Metrics.screenMargin
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        state.hover(nil)
        pinned = false
        unpin?.cancel()
        unpin = nil
    }

    var isVisible: Bool { panel.isVisible }
}
