// SPDX-License-Identifier: GPL-3.0-or-later

import EsclopPipelines
import SwiftUI

/// What the parser says about a step, under it: errors in red, warnings in the caution colour.
struct StepIssues: View {
    let issues: [PipelineDiagnostic]

    var body: some View {
        ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
            Label {
                Text(Self.markdown(PipelineVocabulary.message(issue))).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: issue.severity == .error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
            }
            .font(.callout)
            .foregroundStyle(issue.severity == .error ? Palette.error : Palette.caution)
        }
    }

    /// The parser writes names and values in backticks. A setting's name reads as its title in
    /// quotes ("“Long edge (px)” must be…", not "`longEdge` must be…"); other values stay code.
    static func markdown(_ message: String) -> AttributedString {
        let named = readable(message)
        return (try? AttributedString(markdown: named)) ?? AttributedString(named)
    }

    static func readable(_ message: String) -> String {
        var out = ""
        var rest = Substring(message)
        while let open = rest.firstIndex(of: "`"), let close = rest[rest.index(after: open)...].firstIndex(of: "`") {
            let name = String(rest[rest.index(after: open) ..< close])
            let title = PipelineVocabulary.paramTitle(name)
            out += rest[..<open] + (title == name ? "`\(name)`" : "“\(title)”")
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }
}
