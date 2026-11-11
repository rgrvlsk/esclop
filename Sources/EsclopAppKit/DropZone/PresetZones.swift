// SPDX-License-Identifier: GPL-3.0-or-later
//
// Preset zones: targets beside the drop zone that run a pipeline on what is dropped, as in Clop.
// A saved pipeline is one when its triggers include `presetZone` (the pipeline editor's "A preset
// zone while dragging"); a built-in preset is one when the `presetZones` setting names it. The
// same setting orders them all; pipelines it does not name follow, by name. A drag shows the first
// four that do something for every kind of file in it, in a 2 × 2 grid like Clop's.

import EsclopCore
import EsclopPipelines
import Foundation

public struct PresetZone: Identifiable, Hashable, Sendable {
    /// The pipeline's name, which is what runs.
    public var name: String
    public var icon: String
    public var builtIn: Bool
    /// The kinds of file the pipeline does something for.
    public var kinds: Set<MediaKind>
    /// Shown as a zone (for a saved pipeline: its trigger; for a built-in: the setting names it).
    public var isOn: Bool

    public var id: String { name }

    public init(name: String, icon: String = PresetZone.defaultIcon, builtIn: Bool = false, kinds: Set<MediaKind> = Set(MediaKind.allCases), isOn: Bool = true) {
        self.name = name
        self.icon = icon
        self.builtIn = builtIn
        self.kinds = kinds
        self.isOn = isOn
    }

    public static let defaultIcon = "wand.and.stars"

    init(_ pipeline: Pipeline, builtIn: Bool, isOn: Bool) {
        let icon = pipeline.icon.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultIcon
        self.init(name: pipeline.name, icon: icon, builtIn: builtIn, kinds: pipeline.kinds, isOn: isOn)
    }

    /// Whether dropping files of these kinds on it does something for each of them. A drag of
    /// folders alone says nothing about kinds, and every zone takes it.
    public func takes(_ dragged: Set<MediaKind>) -> Bool {
        dragged.isSubset(of: kinds)
    }
}

public enum PresetZones {
    /// Clop's 2 × 2 grid.
    public static let limit = 4

    /// Every pipeline that can be a zone, on or off: the ones that are on in `order`'s order, then
    /// the other saved ones that are on by name, then the rest (off) by name. A saved pipeline
    /// with a built-in's name hides the built-in, as it does when a pipeline is run by name.
    public static func catalog(saved: [Pipeline], builtIn: [Pipeline] = PipelineStore.presets, order: [String]) -> [PresetZone] {
        let savedNames = Set(saved.map { $0.name.lowercased() })
        let named = Set(order.map { $0.lowercased() })
        var zones = saved.map { PresetZone($0, builtIn: false, isOn: $0.triggers.contains(.presetZone)) }
        zones += builtIn.filter { !savedNames.contains($0.name.lowercased()) }
            .map { PresetZone($0, builtIn: true, isOn: named.contains($0.name.lowercased())) }
        func rank(_ zone: PresetZone) -> Int? { order.firstIndex { $0.caseInsensitiveCompare(zone.name) == .orderedSame } }
        return zones.sorted { a, b in
            if a.isOn != b.isOn { return a.isOn }
            switch (a.isOn ? rank(a) : nil, b.isOn ? rank(b) : nil) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// The zones a drag shows: the ones that are on and take every kind dragged, at most four.
    public static func shown(_ catalog: [PresetZone], dragged: Set<MediaKind>) -> [PresetZone] {
        Array(catalog.filter { $0.isOn && $0.takes(dragged) }.prefix(limit))
    }

    /// The setting after a zone moves `offset` places among the zones that are on. The setting then
    /// names every zone that is on, so the order is the one on screen.
    public static func moving(_ name: String, by offset: Int, in catalog: [PresetZone]) -> [String] {
        var on = catalog.filter(\.isOn).map(\.name)
        guard let from = on.firstIndex(of: name) else { return on }
        let to = min(max(from + offset, 0), on.count - 1)
        on.insert(on.remove(at: from), at: to)
        return on
    }

    /// The setting after a built-in preset is turned on (at the end) or off.
    public static func turning(_ name: String, on: Bool, in catalog: [PresetZone]) -> [String] {
        var names = catalog.filter(\.isOn).map(\.name).filter { $0 != name }
        if on { names.append(name) }
        return names
    }
}
