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

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(Array(model.textDiagnostics.enumerated()), id: \.offset) { _, issue in
                Label {
                    Text(StepIssues.markdown(Strings.format("Line %d: %@", issue.line, PipelineVocabulary.brief(PipelineVocabulary.message(issue))))).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: issue.severity == .error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                }
                .font(.callout)
                .foregroundStyle(issue.severity == .error ? Palette.error : Palette.caution)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            PipelineTextView(text: model.text, diagnostics: model.textDiagnostics, isEditable: !model.isTemplate) { model.editText($0) }
                // Down to the window's foot, the lines and the notes under it; small enough at
                // its least that the window keeps its own smallest size.
                .frame(minHeight: 240, idealHeight: 400, maxHeight: .infinity)
                .accessibilityLabel(Strings.text("Pipeline text"))
                .padding(Spacing.s)
                .warmTile(fill: Surface.tile)
                .padding(.top, Spacing.s)
            // A few marked lines sit under the editor; more scroll in a short list, so the window
            // never grows to hold them.
            if model.textDiagnostics.count > 4 {
                ScrollView { diagnostics }.frame(height: 110)
            } else if !model.textDiagnostics.isEmpty {
                diagnostics
            }
            Text(model.textDiagnostics.contains { $0.severity == .error }
                ? Strings.text("Fix the marked lines to go back to the steps or to save.")
                : Strings.text("The same pipeline as the steps. Saving writes it in this layout; comments are not kept."))
                .font(.system(size: 12))
                .foregroundStyle(Ink.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PipelineTextView: NSViewRepresentable {
    let text: String
    let diagnostics: [PipelineDiagnostic]
    let isEditable: Bool
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        // No empty track while the text fits.
        scroll.autohidesScrollers = true
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
