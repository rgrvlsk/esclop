// SPDX-License-Identifier: GPL-3.0-or-later
//
// One step in the flow (`pr9-pipeline-editor`): its number on the line, its kind's symbol in a
// circle, its name and its settings in plain words. Opened, it shows the settings' controls,
// what the parser says, and Move Up, Move Down and Remove. A script step shows its code plainly.

import EsclopCore
import EsclopPipelines
import SwiftUI

struct StepRowView: View {
    @Binding var step: StepDraft
    let kind: MediaKind?
    let number: Int
    let count: Int
    let issues: [PipelineDiagnostic]
    /// An example's step: it opens to be read, its controls stay disabled.
    var isReadOnly = false
    @Binding var isOpen: Bool
    let move: (Int) -> Void
    let remove: () -> Void
    /// Where the keyboard is among the steps.
    var focus: FocusState<UUID?>.Binding?
    /// Gives the keyboard to the step this many places away.
    var neighbour: ((Int) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    private var title: String { PipelineVocabulary.stepTitle(step.name) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // The number on the flow's line.
            FlowRail(mark: .number(number), lineAbove: number > 1, lineBelow: true)
            VStack(alignment: .leading, spacing: 0) {
                heading
                if isOpen {
                    VStack(alignment: .leading, spacing: 10) {
                        if step.isScript {
                            Text(Strings.text("Runs code on your Mac. Read it before you run the pipeline."))
                                .font(.callout)
                                .foregroundStyle(Ink.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // Each problem sits under the setting it names, whose field is outlined;
                        // the rest come after.
                        StepParamsEditor(step: $step, kind: kind, issues: issues)
                            .disabled(isReadOnly)
                        StepIssues(issues: issues.filter { issue in !(step.spec?.params ?? []).contains { StepParamsEditor.names(issue, $0) } })
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        // The settings sit on a lighter panel inside the step's tile, in both
                        // appearances.
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(scheme == .dark ? 0.035 : 0.55))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.secondary.opacity(0.15), lineWidth: 0.5))
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
            .warmTile(ring: focus?.wrappedValue == step.id)
            .padding(.vertical, 5)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }


    /// The step's heading: its sign, name and summary, its marks, and the menu over them; a
    /// click opens or closes it.
    private var heading: some View {
        headingButton
            .modifier(StepFocus(focus: focus, id: step.id, move: isReadOnly ? nil : move, remove: isReadOnly ? nil : remove, toggle: toggle, neighbour: neighbour))
            .help(step.spec.map(PipelineVocabulary.stepHelp) ?? "")
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Strings.format("Step %d of %d: %@", number, count, title))
            .accessibilityValue(spokenValue)
            .accessibilityHint(isOpen ? Strings.text("Hides its settings") : Strings.text("Shows its settings"))
            .accessibilityAction { toggle() }
            // On the heading VoiceOver lands on. An example is read, not changed: no
            // actions that would change it.
            .accessibilityActions { spokenActions }
            // Move and remove, in words, from a menu on the heading: the open panel holds
            // the step's settings only.
            .overlay(alignment: .trailing) { stepMenu }
    }

    @ViewBuilder private var spokenActions: some View {
        if !isReadOnly {
            Button(Strings.text("Move Up")) { move(-1) }
            Button(Strings.text("Move Down")) { move(1) }
            Button(Strings.text("Remove Step"), action: remove)
        }
    }

    private var headingButton: some View {
        Button(action: toggle) {
            HStack(spacing: 14) {
                IconBadge(symbol: symbol, size: 44, ink: step.isScript ? Ink.warm : Ink.charcoalText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Ink.text)
                    Text(summary)
                        .font(step.isScript ? .system(size: 13, design: .monospaced) : .system(size: 14))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                // The trailing marks on one 28 pt pitch: problem, "…" (over the row),
                // chevron.
                HStack(spacing: 0) {
                    Group {
                        if let worst = issues.first(where: { $0.severity == .error }) ?? issues.first {
                            Image(systemName: worst.severity == .error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(worst.severity == .error ? Palette.error : Palette.caution)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 28)
                    Color.clear.frame(width: 28, height: 1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .frame(width: 28)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var hasKeyboard: Bool { focus?.wrappedValue == step.id }

    @ViewBuilder private var stepMenu: some View {
        if !isReadOnly {
            MoreMenu(size: 26, quiet: true) {
                // Shown here for the step the keyboard is on.
                Button(Strings.text("Move Up")) { move(-1) }
                    .keyboardShortcut(upKey)
                    .disabled(number == 1)
                Button(Strings.text("Move Down")) { move(1) }
                    .keyboardShortcut(downKey)
                    .disabled(number == count)
                Divider()
                Button(Strings.text("Remove Step"), role: .destructive, action: remove)
                    .keyboardShortcut(removeKey)
            }
            .padding(.trailing, 8 + 28 + 1)
            .accessibilityLabel(Strings.format("More options for %@", title))
        }
    }

    /// ⌥⌘↑ and ⌥⌘↓ belong to the step the keyboard is on: one step at a time, so a press moves
    /// that step only.
    private var upKey: KeyboardShortcut? { hasKeyboard ? KeyboardShortcut(.upArrow, modifiers: [.option, .command]) : nil }
    private var downKey: KeyboardShortcut? { hasKeyboard ? KeyboardShortcut(.downArrow, modifiers: [.option, .command]) : nil }
    private var removeKey: KeyboardShortcut? { hasKeyboard ? KeyboardShortcut(.delete, modifiers: .command) : nil }


    /// Open or closed, what it does, then its problems.
    private var spokenValue: String {
        let state = isOpen ? Strings.text("Expanded") : Strings.text("Collapsed")
        let problems = issues.map { StepIssues.readable(PipelineVocabulary.message($0)) }
        return ([state, summary] + problems).joined(separator: ". ")
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { isOpen.toggle() }
        // The step clicked has the keyboard: ⌥⌘↑ and ⌥⌘↓ move it.
        focus?.wrappedValue = step.id
    }

    /// The step's settings in plain words, in the order the step lists them: "Half size",
    /// "To WebP", "Long edge 1600 px". A step with none says what it does, without its full stop.
    var summary: String {
        let params = step.spec?.params ?? []
        let set = params.compactMap { param -> String? in
            guard let value = step.values[param.name], !value.isEmpty else { return nil }
            return Self.phrase(step: step.name, param: param.name, value: value)
        }
        if !set.isEmpty { return set.joined(separator: " · ") }
        if step.name == "copyToClipboard" { return Strings.text("The file’s path") }
        let help = step.spec.map(PipelineVocabulary.stepHelp) ?? step.name
        return help.hasSuffix(".") ? String(help.dropLast()) : help
    }

    /// One setting in words: a scale as a size, a format by its name, a number with its unit
    /// after it and in the language's own decimal mark.
    static func phrase(step: String, param: String, value: String, locale: Locale = Strings.locale) -> String {
        if step == "downscale", param == "factor", let factor = Double(value) {
            switch factor {
            case 0.5: return Strings.text("Half size", locale: locale)
            case 0.25: return Strings.text("A quarter of the size", locale: locale)
            default: return Strings.format("%@ of the size", (factor).formatted(.percent.locale(locale)), locale: locale)
            }
        }
        // What the clipboard gets; a script's own code, alone.
        if step == "copyToClipboard", param == "format" {
            switch value {
            case "imageData": return Strings.text("The picture itself", locale: locale)
            case "markdown": return Strings.text("A Markdown link", locale: locale)
            default: return Strings.text("The file’s path", locale: locale)
            }
        }
        if step == "runScript", param == "code" || param == "path" { return value }
        let title = PipelineVocabulary.paramTitle(param)
        // Numbers in the language's own marks, a minus sign, no grouping.
        let shown = Double(value).map { $0.formatted(.number.grouping(.never).locale(locale)).replacingOccurrences(of: "-", with: Figure.minus) } ?? ParamField.chipTitle(value)
        if step == "convert", param == "to" { return Strings.format("To %@", shown, locale: locale) }
        // "Long edge (px)" + 1600 → "Long edge 1600 px".
        if title.hasSuffix(")"), let open = title.lastIndex(of: "(") {
            let unit = title[title.index(after: open) ..< title.index(before: title.endIndex)]
            return "\(title[..<open].trimmingCharacters(in: .whitespaces)) \(shown) \(unit)"
        }
        return "\(title) \(shown)"
    }

    /// A symbol per kind of step (the proposal's symbols where it names them), else its category's.
    private var symbol: String {
        switch step.name {
        case "crop": return "crop"
        case "convert": return "arrow.triangle.2.circlepath"
        case "downscale": return "arrow.down.right.and.arrow.up.left"
        case "targetSize": return "arrow.down.right.and.arrow.up.left"
        case "stripExif": return "eye.slash"
        case "watermark": return "seal"
        case "rename": return "character.cursor.ibeam"
        case "copy", "copyToClipboard": return "square.on.square"
        case "move": return "folder"
        case "delete": return "trash"
        case "upload", "uploadWith", "copyLinkForSending": return "icloud.and.arrow.up"
        case "removeAudio": return "speaker.slash"
        case "changeSpeed": return "gauge.with.dots.needle.67percent"
        case "normalize": return "waveform"
        case "extractPagesAsImages": return "doc.on.doc"
        default: break
        }
        switch step.spec?.category {
        case .processing: return "wand.and.rays"
        case .fileOperation: return "folder"
        case .filter: return "line.3.horizontal.decrease"
        case .mediaSpecific: return "waveform"
        case .action: return step.isScript ? "terminal" : "square.and.arrow.up"
        case nil: return "questionmark"
        }
    }
}

/// The flow's line beside the steps, with a step's number on it, or the dashed + that adds one.
struct FlowRail: View {
    enum Mark { case number(Int), add }
    let mark: Mark
    var lineAbove = true
    var lineBelow = true
    /// Where the mark sits: level with a step's name.
    var centre: CGFloat = 37

    private let size: CGFloat = 28
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .top) {
            GeometryReader { geometry in
                Path { path in
                    let x = geometry.size.width / 2
                    if lineAbove {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: centre - size / 2))
                    }
                    if lineBelow {
                        path.move(to: CGPoint(x: x, y: centre + size / 2))
                        path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                    }
                }
                // Darker and a half point wider on cream; the walnut line already reads.
                .stroke(Ink.secondary.opacity(scheme == .dark ? 0.35 : 0.45), lineWidth: scheme == .dark ? 1 : 1.5)
            }
            Group {
                switch mark {
                case let .number(number):
                    Text("\(number)")
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Ink.text)
                        .frame(width: size, height: size)
                        .background(Color.clear.warmTile(size / 2))
                case .add:
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Ink.text)
                        .frame(width: size, height: size)
                        .background(DashedOutline(circle: true))
                }
            }
            .offset(y: centre - size / 2)
        }
        .frame(width: 30)
        .frame(maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}

/// A step's heading takes the keyboard; the tile shows the ring while it has it.
private struct StepFocus: ViewModifier {
    let focus: FocusState<UUID?>.Binding?
    let id: UUID
    /// Nil for an example's step, which stays where it is.
    let move: ((Int) -> Void)?
    let remove: (() -> Void)?
    let toggle: () -> Void
    let neighbour: ((Int) -> Void)?

    func body(content: Content) -> some View {
        if let focus {
            // Focusable without Full Keyboard Access, so a click gives the step the keyboard.
            // Space opens or closes it, ↑ and ↓ go to the next step, and ⌥⌘↑ and ⌥⌘↓ move it,
            // at any scroll position.
            content.focusable().focused(focus, equals: id).focusEffectDisabled()
                .onKeyPress(.space) {
                    toggle()
                    return .handled
                }
                // ⌘⌫ removes it, as Remove Step in its menu.
                .onKeyPress(keys: [.delete]) { press in
                    guard let remove, press.modifiers.contains(.command) else { return .ignored }
                    remove()
                    return .handled
                }
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    let delta = press.key == .upArrow ? -1 : 1
                    if press.modifiers.contains(.command), press.modifiers.contains(.option) {
                        guard let move else { return .ignored }
                        move(delta)
                        return .handled
                    }
                    guard press.modifiers.subtracting([.numericPad, .function]).isEmpty, let neighbour else { return .ignored }
                    neighbour(delta)
                    return .handled
                }
        } else {
            content
        }
    }
}
