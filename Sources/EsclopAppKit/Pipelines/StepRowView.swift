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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var title: String { PipelineVocabulary.stepTitle(step.name) }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            // The number on the flow's line.
            Text("\(number)")
                .font(Typeface.label)
                .monospacedDigit()
                .foregroundStyle(Ink.text)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Surface.tile))
                .overlay(Circle().strokeBorder(Ink.secondary.opacity(0.35), lineWidth: 0.5))
                .padding(.top, 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.s) {
                Button(action: toggle) {
                    HStack(spacing: Spacing.m) {
                        Image(systemName: symbol)
                            .font(.system(size: 14))
                            .foregroundStyle(step.isScript ? Ink.warm : Ink.charcoalText)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(NeutralFill.resting))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title).font(Typeface.title)
                            Text(summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if let worst = issues.first(where: { $0.severity == .error }) ?? issues.first {
                            Image(systemName: worst.severity == .error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(worst.severity == .error ? Palette.error : Palette.caution)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(step.spec.map(PipelineVocabulary.stepHelp) ?? "")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Strings.format("Step %d of %d: %@", number, count, title))
                .accessibilityValue(([summary] + issues.map { StepIssues.readable(PipelineVocabulary.message($0)) }).joined(separator: ". "))
                .accessibilityHint(isOpen ? Strings.text("Hides its settings") : Strings.text("Shows its settings"))
                if isOpen {
                    if step.isScript {
                        Text(Strings.text("Runs code on your Mac. Read it before you run the pipeline."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    StepParamsEditor(step: $step, kind: kind)
                        .disabled(isReadOnly)
                    StepIssues(issues: issues)
                    HStack(spacing: Spacing.s) {
                        Button(Strings.text("Move Up"), systemImage: "chevron.up") { move(-1) }
                            .disabled(number == 1)
                            .accessibilityLabel(Strings.format("Move %@ up", title))
                        Button(Strings.text("Move Down"), systemImage: "chevron.down") { move(1) }
                            .disabled(number == count)
                            .accessibilityLabel(Strings.format("Move %@ down", title))
                        Spacer()
                        Button(Strings.text("Remove Step"), systemImage: "minus.circle", action: remove)
                            .accessibilityLabel(Strings.format("Remove %@", title))
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(isReadOnly)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Strings.text("Move Up")) { move(-1) }
        .accessibilityAction(named: Strings.text("Move Down")) { move(1) }
        .accessibilityAction(named: Strings.text("Remove Step"), remove)
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { isOpen.toggle() }
    }

    /// The step's settings in plain words, in the order the step lists them: "Long edge (px)
    /// 1600 · Format webp". A step with none says what it does.
    var summary: String {
        let params = step.spec?.params ?? []
        let set = params.compactMap { param -> String? in
            guard let value = step.values[param.name], !value.isEmpty else { return nil }
            return "\(PipelineVocabulary.paramTitle(param.name)) \(value)"
        }
        if !set.isEmpty { return set.joined(separator: " · ") }
        return step.spec.map(PipelineVocabulary.stepHelp) ?? step.name
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
