// SPDX-License-Identifier: GPL-3.0-or-later
//
// One registry setting: its title and explanation, a native control chosen by
// `SettingPresentation`, the reason a typed value was refused, and a reset arrow while the value
// differs from the default. The context menu copies a deep link or the matching CLI command.

import EsclopCore
import EsclopIPC
import EsclopMCP
import SwiftUI

struct SettingRow: View {
    let descriptor: SettingDescriptor
    let model: SettingsViewModel
    let actions: SettingsActions

    var key: String { descriptor.key }

    var body: some View {
        let enabled = model.isEnabled(key)
        VStack(alignment: .leading, spacing: 6) {
            control
            if let error = model.errors[key] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!enabled)
        .id(key)
        .highlighted(model.highlighted == key)
        .contextMenu {
            Button(Strings.text("Reset to Default")) { model.reset(key) }
                .disabled(!model.isModified(key))
            Divider()
            if let link = model.link(to: key) {
                Button(Strings.text("Copy Link to Setting")) { actions.copy(link.absoluteString) }
            }
            Button(Strings.text("Copy Terminal Command")) {
                actions.copy("esclop settings set \(key) \(Self.shellQuoted(SettingsViewModel.text(for: descriptor.value ?? descriptor.defaultValue)))")
            }
        }
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            SettingLabel(title: descriptor.title, summary: descriptor.summary)
            if model.isModified(key) {
                Button {
                    model.reset(key)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(Strings.format("Reset to the default: %@", SettingPresentation.display(descriptor.defaultValue, for: descriptor)))
                .accessibilityLabel(Strings.format("Reset %@ to the default", descriptor.title))
            }
        }
    }

    @ViewBuilder private var control: some View {
        switch SettingPresentation.control(for: descriptor) {
        case .toggle:
            Toggle(isOn: Binding(get: { descriptor.value?.boolValue ?? false }, set: { model.set(key, to: .bool($0)) })) { label }
                .switchLabel(title: descriptor.title, hint: descriptor.summary)

        case let .picker(choices):
            Picker(selection: Binding(
                get: { choices.first { SettingsViewModel.same($0.value, descriptor.value ?? descriptor.defaultValue) }?.value ?? descriptor.defaultValue },
                set: { model.set(key, to: $0) }
            )) {
                ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
            } label: {
                label
            }
            .pickerStyle(.menu)
        case let .slider(range, step, format):
            LabeledContent {
                SliderField(value: descriptor.value?.doubleValue ?? 0, range: range, step: step, format: format, title: descriptor.title) { value in
                    model.set(key, to: step >= 1 ? .int(Int(value.rounded())) : .double(value))
                }
            } label: {
                label
            }
        case let .number(unit, step):
            LabeledContent {
                NumberField(descriptor: descriptor, model: model, unit: unit, step: step)
            } label: {
                label
            }
        case .text, .extensions:
            LabeledContent {
                TextValueField(descriptor: descriptor, model: model)
            } label: {
                label
            }
        case .folders:
            FolderListEditor(descriptor: descriptor, model: model, label: AnyView(label))
        case .apps:
            StringListEditor(descriptor: descriptor, model: model, label: AnyView(label))
        case .clipboardRules:
            ClipboardRuleList(descriptor: descriptor, model: model, label: AnyView(label))
        case .hoverButtons:
            HoverButtonSwitches(descriptor: descriptor, model: model, label: AnyView(label))
        case .uploadTargets:
            UploadTargetList(descriptor: descriptor, model: model, label: AnyView(label))
        case .uploadTarget:
            UploadTargetPicker(descriptor: descriptor, model: model, label: AnyView(label))
        case .uploadSources:
            UploadSourceSwitches(descriptor: descriptor, model: model, label: AnyView(label))
        }
    }

    static func shellQuoted(_ text: String) -> String {
        let safe = text.allSatisfy { $0.isLetter || $0.isNumber || "-_.,/~%".contains($0) }
        return safe && !text.isEmpty ? text : ServerCommand.quoted(text)
    }
}

// MARK: - Controls

/// A slider that writes once, when the person lets go, with its figure beside it.
struct SliderField: View {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: SettingControl.SliderFormat
    let title: String
    let commit: (Double) -> Void

    @State private var draft = 0.0

    var body: some View {
        HStack(spacing: 10) {
            // No `step:` here: macOS draws a tick per step. Values snap when they are written.
            Slider(value: $draft, in: range) { editing in
                if !editing, draft != value { commit(draft) }
            }
            .labelsHidden()
            .accessibilityLabel(title)
            .accessibilityValue(figure)
            .frame(width: 180)
            Text(figure)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 40, alignment: .trailing)
        }
        .onAppear { draft = value }
        .onChange(of: value) { draft = value }
        .onChange(of: draft) {
            let snapped = min(range.upperBound, ((draft - range.lowerBound) / step).rounded() * step + range.lowerBound)
            if abs(snapped - draft) > 1e-9 { draft = snapped }
        }
    }

    var figure: String {
        switch format {
        case .plain: return String(Int(draft.rounded()))
        case .percent: return "\(Int((draft * 100).rounded())) %"
        }
    }
}

/// A number typed in a field with a stepper beside it. The field checks the text as it is typed
/// and writes on Return, on leaving the field, or with the stepper.
struct NumberField: View {
    let descriptor: SettingDescriptor
    let model: SettingsViewModel
    let unit: String?
    let step: Double

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let problem = model.problem(descriptor.key, text: draft)
        HStack(spacing: 6) {
            TextField(descriptor.title, text: $draft)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 70)
                .focused($focused)
                .onSubmit(commit)
                .overlay {
                    if problem != nil {
                        RoundedRectangle(cornerRadius: 5).strokeBorder(.red, lineWidth: 1).allowsHitTesting(false)
                    }
                }
                .help(problem ?? range)
            Stepper(descriptor.title, onIncrement: { nudge(+step) }, onDecrement: { nudge(-step) })
                .labelsHidden()
            if let unit {
                Text(unit).foregroundStyle(.secondary)
            }
        }
        .onAppear { draft = current }
        .onChange(of: descriptor.value) { if !focused { draft = current } }
        .onChange(of: focused) { if !focused { commit() } }
    }

    var current: String { SettingPresentation.text(for: descriptor.value ?? descriptor.defaultValue) }

    var range: String {
        switch (descriptor.minimum, descriptor.maximum) {
        case let (low?, high?): return Strings.format("From %@ to %@", SettingPresentation.number(low), SettingPresentation.number(high))

        default: return descriptor.title
        }
    }

    func commit() {
        guard draft != current else { return }
        if !model.set(descriptor.key, text: draft) { return }
        draft = current
    }

    func nudge(_ delta: Double) {
        let now = Double(draft) ?? descriptor.value?.doubleValue ?? 0
        var next = now + delta
        if let low = descriptor.minimum { next = max(low, next) }
        if let high = descriptor.maximum { next = min(high, next) }
        draft = SettingPresentation.number(next)
        commit()
    }
}

/// A text value: a name template, or file extensions typed comma separated.
struct TextValueField: View {
    let descriptor: SettingDescriptor
    let model: SettingsViewModel

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(descriptor.title, text: $draft, prompt: Text(SettingPresentation.text(for: descriptor.defaultValue)))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
            .focused($focused)
            .onSubmit(commit)
            .onAppear { draft = current }
            .onChange(of: descriptor.value) { if !focused { draft = current } }
            .onChange(of: focused) { if !focused { commit() } }
    }

    var current: String { SettingPresentation.text(for: descriptor.value ?? descriptor.defaultValue) }

    func commit() {
        guard draft != current else { return }
        if case .extensions = SettingPresentation.control(for: descriptor) {
            let items = draft.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }
                .filter { !$0.isEmpty }
            if model.set(descriptor.key, to: .array(items.map(JSONValue.string))) { draft = current }
        } else if model.set(descriptor.key, text: draft) {
            draft = current
        }
    }
}
