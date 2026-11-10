// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EsclopCore
import EsclopPipelines
import SwiftUI

/// The outcome of a "Try it" run: each step, then the saving and the result file.
struct PipelineTryResultView: View {
    let result: PipelineEditorModel.TryResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(result.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(step.outcome)).foregroundStyle(color(step.outcome)).frame(width: 16).accessibilityHidden(true)
                    Text("\(index + 1). \(step.step)").font(.callout.monospaced())
                    Text(PipelineVocabulary.outcomeTitle(step.outcome)).foregroundStyle(color(step.outcome))
                    if let message = step.message, !message.isEmpty {
                        Text(message).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Divider()
            HStack(spacing: 8) {
                Text(summary).font(.headline).monospacedDigit()
                Spacer()
                if let file = result.finalFile, FileManager.default.fileExists(atPath: file.path) {
                    Button(Strings.text("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        .accessibilityLabel(Strings.text("Show the tried copy in Finder"))
                }
            }
            if let error = result.error {
                Text(error).foregroundStyle(Palette.error).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var summary: String {
        switch result.status {
        case .filtered: return Strings.format("“%@” does not match the filter: nothing ran.", result.file)
        case .unsupported: return Strings.format("This pipeline has no steps for “%@”.", result.file)
        case .failed, .cancelled: return Strings.format("“%@” did not get through.", result.file)
        case .completed:
            guard let after = result.bytesAfter else { return Strings.text("Done") }
            let figures = "\(Figures.bytes(result.bytesBefore)) → \(Figures.bytes(after))"
            guard result.bytesBefore > 0, after < result.bytesBefore else { return figures }
            let saving = Int((Double(result.bytesBefore - after) / Double(result.bytesBefore) * 100).rounded())
            return Strings.format("%@, %d %% smaller", figures, saving).replacingOccurrences(of: " %", with: Figures.space + "%")
        }
    }

    private func symbol(_ outcome: PipelineLogEntry.Outcome) -> String {
        switch outcome {
        case .done: "checkmark.circle.fill"
        case .unchanged: "equal.circle"
        case .skipped: "arrow.right.circle"
        case .stopped: "line.3.horizontal.decrease.circle"
        case .failed: "xmark.circle.fill"
        }
    }

    private func color(_ outcome: PipelineLogEntry.Outcome) -> Color {
        switch outcome {
        case .done: Palette.accent
        case .failed: Palette.error
        default: .secondary
        }
    }
}
