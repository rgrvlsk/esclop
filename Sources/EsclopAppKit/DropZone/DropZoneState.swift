// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import Observation

/// What the drop zone shows while a drag is under way.
@MainActor @Observable
public final class DropZoneState {
    /// Files of a kind L'Esclop optimises in the drag (0 while it is shown without one).
    public var fileCount: Int
    /// The drag is over the plain "optimise" target.
    public var hovering: Bool
    /// Command is held: drop to optimise harder.
    public var harder: Bool
    /// The preset zones beside the plain target, at most four.
    public var zones: [PresetZone]
    /// The preset zone under the drag, by name.
    public var hoveredZone: String?
    /// The zones sit on the left of the plain target (a right corner), so they face the screen.
    public var zonesLeading: Bool
    /// Each target's frame in `DropZoneState.space`, top-left origin: the plain target under
    /// `plainTarget`, the zones under their names. The drop target reads them to tell which one a
    /// drag is over.
    @ObservationIgnored public var frames: [String: CGRect] = [:]

    nonisolated public static let space = "dev.esclop.dropzone"
    nonisolated public static let plainTarget = "\u{0}plain"

    public init(fileCount: Int = 0, hovering: Bool = false, harder: Bool = false, zones: [PresetZone] = [], hoveredZone: String? = nil, zonesLeading: Bool = true) {
        self.fileCount = fileCount
        self.hovering = hovering
        self.harder = harder
        self.zones = zones
        self.hoveredZone = hoveredZone
        self.zonesLeading = zonesLeading
    }

    /// The line under the tiles: what a drop does.
    public var title: String { harder ? Strings.text("Drop to optimise harder") : Strings.text("Drop to optimise") }

    /// The plain tile's name.
    public var tileTitle: String { harder ? Strings.text("Optimise harder") : Strings.text("Optimise") }

    /// What the drag carries, under the plain tile's name; empty while it is shown without a drag.
    public var count: String {
        switch fileCount {
        case 0: ""
        case 1: Strings.text("1 file")
        default: Strings.format("%d files", fileCount)
        }
    }

    /// After the title, on the same line: how to change what a drop does, or what it now does.
    public var hint: String { harder ? Strings.text("With the aggressive settings") : Strings.text("Hold ⌘ to optimise harder") }

    /// Which target is at `point` (top-left origin): a zone's name, `plainTarget`, or nil.
    public func target(at point: CGPoint) -> String? {
        if let zone = zones.first(where: { frames[$0.name]?.contains(point) ?? false }) { return zone.name }
        return frames[Self.plainTarget]?.contains(point) ?? false ? Self.plainTarget : nil
    }

    /// The drag moved to `target` (nil: off every target).
    public func hover(_ target: String?) {
        hovering = target == Self.plainTarget
        let zone = target == Self.plainTarget ? nil : target
        if hoveredZone != zone { hoveredZone = zone }
    }
}
