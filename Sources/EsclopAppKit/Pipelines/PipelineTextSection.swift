// SPDX-License-Identifier: GPL-3.0-or-later
//
// The pipeline as the file holds it, editable. The form follows when the text reads; while it
// has errors the text stays as typed, each error's line is marked and its message listed.

import AppKit
import EsclopCore
import EsclopPipelines
import SwiftUI

struct PipelineTextSection: View {
    @Bindable var model: PipelineEditorModel

    var body: some View {
        Section {
            PipelineTextView(text: model.text, diagnostics: model.textDiagnostics, isEditable: !model.isTemplate) { model.editText($0) }
                .frame(minHeight: 220)
                .accessibilityLabel(Strings.text("Pipeline text"))
            ForEach(Array(model.textDiagnostics.enumerated()), id: \.offset) { _, issue in
                Label {
                    Text(StepIssues.markdown(Strings.format("Line %d: %@", issue.line, issue.message))).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: issue.severity == .error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                }
                .font(.callout)
                .foregroundStyle(issue.severity == .error ? Palette.error : Palette.caution)
            }
        } header: {
            Text(Strings.text("Text"))
        } footer: {
            Text(model.textDiagnostics.contains { $0.severity == .error }
                ? Strings.text("Fix the marked lines to go back to the form or to save.")
                : Strings.text("The same pipeline as the form. Saving writes it in this layout; comments are not kept."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A monospaced text view that marks the lines diagnostics point at.
struct PipelineTextView: NSViewRepresentable {
    let text: String
    let diagnostics: [PipelineDiagnostic]
    let isEditable: Bool
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let view = scroll.documentView as! NSTextView
        view.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 4, height: 6)
        view.delegate = context.coordinator
        view.setAccessibilityLabel(Strings.text("Pipeline text"))
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.onChange = onChange
        view.isEditable = isEditable
        if view.string != text {
            let selection = view.selectedRanges
            view.string = text
            view.selectedRanges = selection.filter { $0.rangeValue.upperBound <= (text as NSString).length }
        }
        mark(view)
    }

    /// Error lines get a red wash and the error's span a red underline; warnings the same in the caution colour.
    private func mark(_ view: NSTextView) {
        guard let layout = view.layoutManager else { return }
        let string = view.string as NSString
        let whole = NSRange(location: 0, length: string.length)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
        layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: whole)
        layout.removeTemporaryAttribute(.underlineColor, forCharacterRange: whole)
        let lines = Self.lineRanges(string)
        for diagnostic in diagnostics {
            guard let line = lines[safe: diagnostic.line - 1] else { continue }
            let color = diagnostic.severity == .error ? NSColor.systemRed : NSColor(Palette.caution)
            layout.addTemporaryAttribute(.backgroundColor, value: color.withAlphaComponent(0.14), forCharacterRange: line)
            let start = min(line.location + max(0, diagnostic.column - 1), NSMaxRange(line))
            let span = NSRange(location: start, length: min(diagnostic.length, NSMaxRange(line) - start))
            if span.length > 0 {
                layout.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue, forCharacterRange: span)
                layout.addTemporaryAttribute(.underlineColor, value: color, forCharacterRange: span)
            }
        }
    }

    static func lineRanges(_ string: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            ranges.append(range)
        }
        return ranges
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (String) -> Void
        init(onChange: @escaping (String) -> Void) { self.onChange = onChange }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            onChange(view.string)
        }
    }
}
