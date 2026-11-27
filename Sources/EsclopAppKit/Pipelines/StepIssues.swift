// SPDX-License-Identifier: GPL-3.0-or-later

import EsclopPipelines
import SwiftUI

/// What the parser says about a step, under it: errors in red, warnings in the caution colour.
struct StepIssues: View {
    let issues: [PipelineDiagnostic]
    /// A setting's title the problem need not repeat: it sits under that setting.
    var dropping: String?

    var body: some View {
        ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
            Label {
                Text(Self.markdown(Self.trimmed(PipelineVocabulary.message(issue), dropping: dropping))).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: issue.severity == .error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
            }
            .font(.callout)
            // A lighter coral in dark, so it holds 4.5:1 on the open step's panel.
            .foregroundStyle(issue.severity == .error ? Self.error : Palette.caution)
        }
    }

    static let error = Color(nsColor: Palette.dynamic(light: 0xC4281C, dark: 0xFF8E80))

    /// "“Long edge (px)” must be…" under the Long edge field reads "Must be…".
    static func trimmed(_ message: String, dropping title: String?) -> String {
        guard let title else { return message }
        let named = readable(message)
        for quoted in [Strings.format("“%@”", title), "“\(title)”"] where named.hasPrefix(quoted) {
            let rest = named.dropFirst(quoted.count).trimmingCharacters(in: .whitespaces)
            return rest.prefix(1).uppercased() + rest.dropFirst()
        }
        return message
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
            // The language's own quotes: “…” in English, «…» in Catalan.
            out += rest[..<open] + (title == name ? "`\(name)`" : Strings.format("“%@”", title))
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }
}
