// SPDX-License-Identifier: GPL-3.0-or-later
//
// Settings › Floating results › Preset zones: every pipeline that can be a preset zone, with a
// switch and, for the ones that are on, buttons to move it up or down. A saved pipeline's switch
// is its "A preset zone while dragging" trigger, the same one the pipeline editor shows; a
// built-in preset's switch adds it to the `presetZones` setting, which also holds the order.

import EsclopCore
import EsclopIPC
import EsclopPipelines
import SwiftUI

struct PresetZoneList: View {
    let descriptor: SettingDescriptor
    let model: SettingsViewModel
    let label: AnyView
    /// Bumped after a trigger changes in a pipeline file, which the setting alone may not show.
    @State private var revision = 0

    private var order: [String] { (descriptor.value?.arrayValue ?? []).compactMap(\.stringValue) }

    private var catalog: [PresetZone] {
        _ = revision
        let saved = (try? model.pipelines?.list()) ?? []
        return PresetZones.catalog(saved: saved, order: order)
    }

    var body: some View {
        let zones = catalog
        let on = zones.filter(\.isOn)
        VStack(alignment: .leading, spacing: 6) {
            label
            ForEach(zones) { zone in
                HStack(spacing: 8) {
                    Image(systemName: zone.icon)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    TitledToggle(
                        title: zone.name,
                        subtitle: zone.builtIn ? Strings.text("Built-in template") : Strings.text("Saved pipeline"),
                        isOn: Binding(get: { zone.isOn }, set: { turn(zone, on: $0, in: zones) })
                    )
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    // A fixed width keeps the switches in one column, with or without the arrows.
                    HStack(spacing: 4) {
                        if zone.isOn {
                            let index = on.firstIndex(of: zone) ?? 0
                            moveButton(zone, by: -1, in: zones, enabled: index > 0)
                            moveButton(zone, by: 1, in: zones, enabled: index < on.count - 1)
                        }
                    }
                    .frame(width: 48, alignment: .trailing)
                }
                .padding(.leading, 12)
            }
            Text(Strings.text("A drag shows the first four that work on every file in it, beside the drop zone."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func moveButton(_ zone: PresetZone, by offset: Int, in zones: [PresetZone], enabled: Bool) -> some View {
        Button {
            model.set(descriptor.key, to: .array(PresetZones.moving(zone.name, by: offset, in: zones).map { .string($0) }))
        } label: {
            Image(systemName: offset < 0 ? "chevron.up" : "chevron.down")
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(offset < 0 ? Strings.text("Move up") : Strings.text("Move down"))
        .accessibilityLabel(Strings.format(offset < 0 ? "Move “%@” up" : "Move “%@” down", zone.name))
    }

    private func turn(_ zone: PresetZone, on: Bool, in zones: [PresetZone]) {
        Self.turn(zone, on: on, in: zones, model: model)
        revision += 1
    }

    /// A saved pipeline's switch is its trigger; every switch rewrites the order. A pipeline that
    /// went away meanwhile is left alone.
    static func turn(_ zone: PresetZone, on: Bool, in zones: [PresetZone], model: SettingsViewModel) {
        if !zone.builtIn, let store = model.pipelines {
            if on { try? store.attach(.presetZone, to: zone.name) } else { _ = try? store.detach(.presetZone, from: zone.name) }
        }
        model.set(EsclopSettings.presetZones.key, to: .array(PresetZones.turning(zone.name, on: on, in: zones).map { .string($0) }))
    }
}
