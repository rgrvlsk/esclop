// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shows the drop zone while files are dragged anywhere, as Clop does: a global mouse-drag monitor
// notices the drag, the drag pasteboard (read off the main thread, it is a slow XPC round trip)
// says whether it carries files L'Esclop can optimise (DropIntake: files, promises, web
// addresses), and mouse-up hides the zone again. A tap on ⌥ during the drag opens it under the
// pointer, the only way with `dropZoneOnlyWithOption`; ⌥ held at the drop keeps the originals.
// The preset zones beside it (PresetZones) run a pipeline on what is dropped on them.

import AppKit
import EsclopCore
import EsclopPipelines
import SwiftUI

/// The panel's content view: accepts drops, tells which target (the plain zone or a preset
/// zone) a drag is over, and tracks Command for "harder" and Option for "keep the originals".
final class DropTargetView: NSView {
    var state: DropZoneState?
    /// What was dropped, harder (⌘), keep the originals (⌥), and the preset zone's name, or nil
    /// for the plain zone.
    var onDrop: ((DropIntake, Bool, Bool, String?) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(DropIntake.draggedTypes)
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
        let intake = DropIntake(pasteboard: sender.draggingPasteboard)
        guard !intake.isEmpty, let target = target(of: sender) else { return false }
        let flags = NSEvent.modifierFlags
        onDrop?(intake, flags.contains(.command), flags.contains(.option), target == DropZoneState.plainTarget ? nil : target)
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
        let flags = NSEvent.modifierFlags
        state?.harder = flags.contains(.command)
        state?.keepOriginals = flags.contains(.option)
        return target == nil ? [] : Self.operation(for: sender.draggingSourceOperationMask)
    }

    /// What the drop answers, from what the source allows: a copy where it can (the files stay
    /// where they are), else generic, which is all ⌘ held leaves in the mask, so that drag is not
    /// refused. Never a move: L'Esclop only reads a dropped file.
    static func operation(for mask: NSDragOperation) -> NSDragOperation {
        [.copy, .generic].first { mask.contains($0) } ?? []
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
    /// What the drag under way carries, once read: an ⌥ tap shows the zone only during one.
    private var dragMedia: (count: Int, kinds: Set<MediaKind>)?
    private var optionTap = OptionTap()
    /// The frame of the screen the zone was placed on, to follow the drag to another display.
    private var shownOn: CGRect?

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
        target.onDrop = { [weak self] intake, harder, keepOriginals, zone in
            guard let self else { return }
            self.hide()
            self.dragMedia = nil
            self.model.takeDrop(intake, harder: harder, keepOriginals: keepOriginals, zone: zone)
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
            let flags = event.modifierFlags
            MainActor.assumeIsolated { self?.modifiersChanged(flags) }
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
        guard EsclopSettings.enableDragAndDrop.value(in: model.settings) else { return }
        followPointer()
        guard !resolving else { return }
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
                // Read after the button came up, the drag is over: nothing to show it for.
                guard media.count > 0, NSEvent.pressedMouseButtons & 1 != 0 else { return }
                self.dragCarries(media)
            }
        }
    }

    /// A drag under way carries media: the zone shows at once, or with `dropZoneOnlyWithOption`
    /// after a tap on ⌥.
    func dragCarries(_ media: (count: Int, kinds: Set<MediaKind>)) {
        dragMedia = media
        guard !EsclopSettings.dropZoneOnlyWithOption.value(in: model.settings) else { return }
        show(files: media.count, kinds: media.kinds)
    }

    /// The media on the drag pasteboard (files, inside folders too, promised files and web
    /// addresses) and their kinds.
    nonisolated static func media(on pasteboard: NSPasteboard) -> (count: Int, kinds: Set<MediaKind>) {
        let intake = DropIntake(pasteboard: pasteboard)
        var media = media(in: intake.files)
        let remote = intake.remoteMedia
        media.count += remote.count
        media.kinds.formUnion(remote.kinds)
        return media
    }

    /// The files of a kind L'Esclop optimises, the ones inside folders too, and their kinds: what a
    /// drop optimises, so the count and the preset zones match it.
    // ponytail: at most `limit` folder entries are looked at, so a drag of a huge folder shows at
    // once; past them the count is short, and a folder with no media among them counts as one
    // file of unknown kind (every preset zone). Count in the background after showing if that matters.
    nonisolated static func media(in urls: [URL], limit: Int = 10_000) -> (count: Int, kinds: Set<MediaKind>) {
        var count = 0
        var kinds = Set<MediaKind>()
        var left = limit
        func add(_ url: URL) {
            guard let kind = MediaKind.of(url) else { return }
            count += 1
            kinds.insert(kind)
        }
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  let entries = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else {
                add(url)
                continue
            }
            let before = count
            for case let entry as URL in entries {
                guard left > 0 else {
                    if count == before { count += 1 }
                    break
                }
                left -= 1
                add(entry)
            }
        }
        return (count, kinds)
    }

    // MARK: Modifiers

    func modifiersChanged(_ flags: NSEvent.ModifierFlags, at now: Date = Date()) {
        state.harder = flags.contains(.command)
        state.keepOriginals = flags.contains(.option)
        guard optionTap.tapped(flags, at: now), let media = dragMedia else { return }
        // A tap opens the zone under the pointer (moving it there from the corner); the next one hides it.
        if panel.isVisible, state.atPointer {
            hide()
        } else {
            show(files: media.count, kinds: media.kinds, atPointer: true)
        }
    }

    func mouseUp() {
        dragMedia = nil
        optionTap = OptionTap()
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

    /// `atPointer`: under the pointer (an ⌥ tap) instead of at the results corner.
    func show(files: Int, kinds: Set<MediaKind>, atPointer: Bool = false) {
        state.fileCount = files
        state.hover(nil)
        let flags = NSEvent.modifierFlags
        state.harder = flags.contains(.command)
        state.keepOriginals = flags.contains(.option)
        state.atPointer = atPointer
        state.zones = zones(for: kinds)
        state.zonesLeading = model.corner.isRight
        guard place() else { return }
        panel.orderFrontRegardless()
    }

    @discardableResult
    private func place() -> Bool {
        let pointer = NSEvent.mouseLocation
        let followCursor = state.atPointer || model.followCursorScreen
        guard let screen = FloatingPanelController.targetScreen(followCursor: followCursor) else { return false }
        let visible = screen.visibleFrame
        target.layoutSubtreeIfNeeded()
        let size = target.fittingSize
        var frame: CGRect
        if state.atPointer {
            frame = Self.frame(for: size, under: pointer, in: visible)
        } else {
            frame = FloatingPanelController.frame(for: size, corner: model.corner, in: visible)
            if let results = resultsFrame(), visible.intersects(results) {
                // Above the result cards (below them in a top corner), never on top of them.
                frame.origin.y = model.corner.isTop ? results.minY - size.height + Metrics.screenMargin : results.maxY - Metrics.screenMargin
            }
        }
        shownOn = screen.frame
        panel.setFrame(frame, display: true)
        return true
    }

    /// Just below the pointer and centred on it (above it near the bottom of the screen), inside
    /// the screen: no tile is under the pointer when the zone opens, so a drop that was already
    /// on its way does not land on one by chance.
    nonisolated static func frame(for size: CGSize, under pointer: CGPoint, in visible: CGRect) -> CGRect {
        // The panel's transparent margin may cover the pointer; only the tiles take a drop.
        let gap = 12 - Metrics.screenMargin
        var y = pointer.y - gap - size.height
        if y < visible.minY { y = pointer.y + gap }
        let x = min(max(pointer.x - size.width / 2, visible.minX), visible.maxX - size.width)
        y = min(max(y, visible.minY), visible.maxY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// A drag that moves to another display takes the zone along, when results follow the pointer.
    private func followPointer() {
        guard panel.isVisible, !pinned, !state.atPointer, model.followCursorScreen,
              let screen = FloatingPanelController.targetScreen(followCursor: true), screen.frame != shownOn
        else { return }
        place()
    }

    func hide() {
        panel.orderOut(nil)
        state.hover(nil)
        state.atPointer = false
        pinned = false
        unpin?.cancel()
        unpin = nil
    }

    var isVisible: Bool { panel.isVisible }
}

/// A tap on ⌥: pressed on its own and released within `longest`, no other modifier on the way.
struct OptionTap {
    static let longest: TimeInterval = 0.4
    private var pressedAt: Date?
    private var last: NSEvent.ModifierFlags = []

    /// Feeds a modifier change; true when it ends a tap.
    mutating func tapped(_ raw: NSEvent.ModifierFlags, at now: Date = Date()) -> Bool {
        let flags = raw.intersection([.command, .option, .control, .shift, .function])
        defer { last = flags }
        if flags == .option {
            if last.isEmpty { pressedAt = now }
            return false
        }
        defer { pressedAt = nil }
        guard flags.isEmpty, last == .option, let pressedAt else { return false }
        return now.timeIntervalSince(pressedAt) <= Self.longest
    }
}
