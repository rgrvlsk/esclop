// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import EsclopPipelines

/// A small deterministic generator so failures reproduce.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

let fragments = [
    "optimise", "convert", "crop", "if", "ifNot", "(", ")", "(", ")", ":", ",", " ", " ", "\n", "->", "-", ">",
    "\"", "'", "#", "[", "]", "image", "to", "webp", "width", "100", "0.5", "%f", "~/x/", "$1", "---",
    "triggers", "folder", "é", "🎉", "\\", "regex", "location", "sameFolder", "targetSize", "size", "10MB",
]

@Test func parserAndCompletionsSurviveRandomInput() {
    var rng = SplitMix(state: 42)
    for _ in 0 ..< 1500 {
        let text = (0 ..< Int.random(in: 1 ... 24, using: &rng)).map { _ in fragments.randomElement(using: &rng)! }.joined()
        let result = PipelineParser.check(text)
        // Diagnostics point inside the text.
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        for d in result.diagnostics {
            #expect(d.line >= 1 && d.line <= lineCount + 1, "\(text.debugDescription): \(d)")
            #expect(d.column >= 1)
        }
        // Whatever parses serializes to text that parses back to the same pipeline.
        if let p = result.pipeline {
            let again = PipelineParser.check(p.text)
            #expect(again.pipeline == p, "\(text.debugDescription) -> \(p.text.debugDescription): \(again.errors)")
        }
        let length = text.utf16.count
        for offset in stride(from: 0, through: length, by: max(1, length / 6)) {
            for c in PipelineLanguage.completions(in: text, at: offset) {
                #expect(c.replaceStart >= 0 && c.replaceLength >= 0 && c.replaceStart + c.replaceLength <= offset, "\(text.debugDescription) @\(offset): \(c)")
            }
        }
    }
}
