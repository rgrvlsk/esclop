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

    /// The parser writes names and values in backticks: shown as code.
    static func markdown(_ message: String) -> AttributedString {
        (try? AttributedString(markdown: message)) ?? AttributedString(message)
    }
}
