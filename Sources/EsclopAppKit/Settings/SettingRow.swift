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
    /// A shorter name the tile makes clear ("Images" under "When aggressive"); it drops the
    /// explanation, which only said the same.
    var shortTitle: String?

    var key: String { descriptor.key }

    var body: some View {
        let enabled = model.isEnabled(key)
        VStack(alignment: .leading, spacing: 3) {
            if simple {
                // The title and its control on one line, the reset arrow in one column at the
                // trailing edge; the explanation under them, the tile's whole width.
                HStack(alignment: .center, spacing: Spacing.s) {
                    control
                        .accessibilityHint(shortTitle == nil ? "" : descriptor.summary)
                    resetButton
                        .frame(width: 24)
                }
                if shortTitle == nil {
                    Text(Typeset.smart(descriptor.summary))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, isCheckbox ? 24 : 0)
                        .padding(.trailing, 32)
                }
            } else {
                control
            }
            if let error = model.errors[key] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Ink.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!enabled)
        // A row that waits on another setting reads as waiting, its words too (still 3:1).
        .opacity(enabled ? 1 : 0.7)
        .markable(key)
        .settingMenu(descriptor, model: model, actions: actions)
    }

    /// A control that sits on the title's line; the editors of lists lay themselves out.
    private var simple: Bool {
        switch SettingPresentation.control(for: descriptor) {
        case .toggle, .picker, .slider, .number, .text, .extensions: return true
        default: return false
        }
    }

    private var isCheckbox: Bool {
        if case .toggle = SettingPresentation.control(for: descriptor) { return true }
        return false
    }

    /// The row's title alone; the explanation goes under the row.
    private var title: some View {
        Text(shortTitle ?? Typeset.smart(descriptor.title))
            .font(.system(size: 13))
            .foregroundStyle(Ink.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The arrow back to the default while the value differs; an empty slot otherwise, so the
    /// controls stay in one column.
    @ViewBuilder private var resetButton: some View {
        if model.isModified(key) {
            Button {
                model.reset(key)
            } label: {
                Image(systemName: "arrow.uturn.backward.circle")
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.borderless)
            // Drawn and pressed at 24 pt, laid out at the line's height: a changed row is as
            // tall as an unchanged one.
            .padding(.vertical, -4)
            .foregroundStyle(Ink.secondary)
            .help(Strings.format("Reset to the default: %@", SettingPresentation.display(descriptor.defaultValue, for: descriptor)))
            .accessibilityLabel(Strings.format("Reset %@ to the default", descriptor.title))
        } else {
            Color.clear.frame(height: 1).accessibilityHidden(true)
        }
    }

    /// The title, its explanation and the reset arrow, for the editors that lay out a list.
    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            SettingLabel(title: shortTitle ?? descriptor.title, summary: descriptor.summary)
            if model.isModified(key) {
                Spacer(minLength: 8)
                resetButton
            }
        }
    }

    /// The name VoiceOver and Voice Control use: the one on screen. With a short name the
    /// explanation is not on screen, so it becomes the control's hint.
    private var spokenName: String { shortTitle ?? descriptor.title }

    @ViewBuilder private var control: some View {
        switch SettingPresentation.control(for: descriptor) {
        case .toggle:
            let isOn = Binding(get: { descriptor.value?.boolValue ?? false }, set: { model.set(key, to: .bool($0)) })
            Toggle(isOn: isOn) { title }
                .switchLabel(title: descriptor.title, hint: descriptor.summary)
                // A checkbox that holds its own on cream (3:1), its words after it.
                .toggleStyle(WarmCheckboxStyle())
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .picker(choices):
            let chosen = choices.first { SettingsViewModel.same($0.value, descriptor.value ?? descriptor.defaultValue) }
            LabeledContent {
                // The value in a white pill with its chevron; the choices in the menu. Every
                // control starts on one column edge.
                PillMenu(
                    // A value no choice has shows the default's name, not an empty pill.
                    title: spokenName, current: (chosen ?? choices.first { SettingsViewModel.same($0.value, descriptor.defaultValue) })?.label ?? "",
                    selection: Binding(get: { chosen?.value ?? descriptor.defaultValue }, set: { model.set(key, to: $0) })
                ) {
                    ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
                }
                .frame(width: Self.controlColumn, alignment: .leading)
            } label: {
                title
            }
        case let .slider(range, step, format):
            LabeledContent {
                SliderField(value: descriptor.value?.doubleValue ?? 0, range: range, step: step, format: format, title: spokenName) { value in
                    model.set(key, to: step >= 1 ? .int(Int(value.rounded())) : .double(value))
                }
            } label: {
                title
            }
        case let .number(unit, step):
            LabeledContent {
                NumberField(descriptor: descriptor, model: model, unit: unit, step: step, title: spokenName)
                    .frame(width: Self.controlColumn, alignment: .leading)
            } label: {
                title
            }
        case .text, .extensions:
            LabeledContent {
                TextValueField(descriptor: descriptor, model: model)
            } label: {
                title
            }
        case .folders:
            FolderListEditor(descriptor: descriptor, model: model, label: AnyView(label))
        case .apps:
            StringListEditor(descriptor: descriptor, model: model, label: AnyView(label))
        case .clipboardRules:
            // With no rules yet, the line under the title says how to make one; the explanation
            // would say it twice.
            ClipboardRuleList(descriptor: descriptor, model: model, label: (descriptor.value?.arrayValue ?? []).isEmpty ? AnyView(title) : AnyView(label))
        case .presetZones:
            PresetZoneList(descriptor: descriptor, model: model, label: AnyView(label))
        case .uploadTargets:
            UploadTargetList(descriptor: descriptor, model: model, label: AnyView(label))
        case .uploadTarget:
            UploadTargetPicker(descriptor: descriptor, model: model, label: AnyView(label))
        case .uploadSources:
            UploadSourceSwitches(descriptor: descriptor, model: model, label: AnyView(label))
        }
    }

    /// The control column's width: a slider with its figure, a field, a menu all start on it.
    static let controlColumn: CGFloat = 230

    static func shellQuoted(_ text: String) -> String {
        let safe = text.allSatisfy { $0.isLetter || $0.isNumber || "-_.,/~%".contains($0) }
        return safe && !text.isEmpty ? text : ServerCommand.quoted(text)
    }
}

extension View {
    /// A setting's context menu, wherever its control is drawn: reset, its link, its command.
    func settingMenu(_ descriptor: SettingDescriptor, model: SettingsViewModel, actions: SettingsActions) -> some View {
        let key = descriptor.key
        return contextMenu {
            Button(Strings.text("Reset to Default")) { model.reset(key) }
                .disabled(!model.isModified(key))
            Divider()
            if let link = model.link(to: key) {
                Button(Strings.text("Copy Link to Setting")) { actions.copy(link.absoluteString) }
            }
            Button(Strings.text("Copy Terminal Command")) {
                actions.copy("esclop settings set \(key) \(SettingRow.shellQuoted(SettingsViewModel.text(for: descriptor.value ?? descriptor.defaultValue)))")
            }
        }
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
            .tint(Ink.charcoal)
            .accessibilityLabel(title)
            .accessibilityValue(figure)
            .frame(width: 180)
            Text(figure)
                .monospacedDigit()
                .foregroundStyle(Ink.secondary)
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
    /// The name on screen, when the row shows a shorter one.
    var title: String?

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let problem = model.problem(descriptor.key, text: draft)
        HStack(spacing: 6) {
            TextField(title ?? descriptor.title, text: $draft)
                .labelsHidden()
                .textFieldStyle(WarmFieldStyle(focused: focused))
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 70)
                .focused($focused)
                .onSubmit(commit)
                .overlay {
                    if problem != nil {
                        RoundedRectangle(cornerRadius: 5).strokeBorder(Ink.error, lineWidth: 1).allowsHitTesting(false)
                    }
                }
                .help(problem ?? range)
            Stepper(title ?? descriptor.title, onIncrement: { nudge(+step) }, onDecrement: { nudge(-step) })
                .labelsHidden()
            if let unit {
                Text(SettingPresentation.unit(unit, key: descriptor.key, value: descriptor.value)).foregroundStyle(Ink.secondary)
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
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        // The default as the prompt, in the secondary ink (4.5:1). While the row waits, the value
        // in the row's own ink, not the system's fainter disabled text.
        WarmPlaceholder(text: draft, prompt: SettingPresentation.text(for: descriptor.defaultValue)) {
            if enabled {
                TextField(descriptor.title, text: $draft, prompt: Text(""))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(commit)
                    // The drawn prompt is hidden from VoiceOver: the default, said as a hint.
                    .accessibilityHint(draft.isEmpty ? Strings.format("Default: %@", SettingPresentation.text(for: descriptor.defaultValue)) : "")
            } else {
                Text(draft).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
            .padding(.horizontal, 8)
            .frame(minHeight: 26)
            .background { WarmFieldGround() }
            .overlay { if focused { WarmFieldRing() } }
            // The same width as a slider with its figure, so the controls share one edge.
            .frame(width: 230)
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
