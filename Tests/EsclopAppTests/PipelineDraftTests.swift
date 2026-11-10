// SPDX-License-Identifier: GPL-3.0-or-later

import EsclopCore
import EsclopPipelines
@testable import EsclopAppKit
import Foundation
import Testing

/// The editor's form against the language: what the form saves is what the serializer writes,
/// and a pipeline read into the form comes back unchanged.
@Suite struct PipelineDraftTests {
    static let samples: [String] = [
        """
        ---
        description: Screenshots for the blog
        icon: photo
        triggers: clipboard, folder("~/Desktop/To blog"), dropZone
        optimiseFirst: true
        ---
        if(types: png, regex: "^Screenshot") -> crop(longEdge: 1600) -> convert(to: webp, location: "~/Blog/%f") -> copyToClipboard(format: markdown)
        """,
        """
        ---
        hideResult: true
        ---
        if(nameContains: "draft") -> optimise

        [image]
        if(nameContains: "draft") -> downscale(factor: 0.5) -> rename(to: "%f-small")

        [video]
        if(nameContains: "draft") -> capFps(fps: 30) -> removeAudio
        """,
        """
        [pdf]
        optimise(dpi: 150) -> move(to: "~/Documents/Scans/%y/")

        [audio]
        normalize(lufs: -16) -> lowerBitrate(kbps: 96) -> runScript(code: "echo $1")
        """,
        "ifNot(fileSizeLowerThan: 50000) -> targetSize(size: 2MB) -> delete(path: sourceFile)",
        "if(types: image) -> optimise",
        "watermark(image: \"~/logo.png\", position: topLeft, opacity: 0.5) -> fork -> openWith(app: \"Preview\")",
    ]

    static func pipelines() throws -> [Pipeline] {
        try samples.enumerated().map { try PipelineParser.parse($1, name: "sample \($0)") } + PipelineStore.presets
    }

    @Test func formToTextToParserToFormIsIdentical() throws {
        for pipeline in try Self.pipelines() {
            let draft = PipelineDraft(pipeline)
            let check = draft.check()
            let built = try #require(check.pipeline, "\(pipeline.name): \(check.issues.values.flatMap { $0 }) \(check.general)")
            #expect(built == pipeline, "\(pipeline.name)")
            let text = PipelineSerializer.serialize(built)
            #expect(text == PipelineSerializer.serialize(pipeline), "byte for byte: \(pipeline.name)")
            let reparsed = try PipelineParser.parse(text, name: pipeline.name)
            let again = PipelineDraft(reparsed)
            #expect(again.allSteps.map(\.text) == draft.allSteps.map(\.text), "\(pipeline.name)")
            #expect(again.triggers == draft.triggers && again.filter?.text == draft.filter?.text)
        }
    }

    @Test func aSharedLeadingIfIsTheFilter() throws {
        let draft = PipelineDraft(try PipelineParser.parse(Self.samples[1], name: "x"))
        #expect(draft.filter?.text == "if(nameContains: \"draft\")")
        #expect(draft.sections.map { $0.steps.map(\.name) } == [["optimise"], ["downscale", "rename"], ["capFps", "removeAudio"]])
        let partial = PipelineDraft(try PipelineParser.parse("[image]\nif(types: png) -> optimise\n\n[video]\noptimise", name: "y"))
        #expect(partial.filter == nil, "only some sections start with it: it stays a step")
        #expect(partial.sections[0].steps.map(\.name) == ["if", "optimise"])
        let alone = PipelineDraft(try PipelineParser.parse("if(types: png)", name: "z"))
        #expect(alone.filter == nil, "an if that is all a section has stays a step")
    }

    @Test func valuesAreEditedAsPlainText() throws {
        var draft = PipelineDraft(name: "web", steps: [StepDraft(name: "convert", values: ["to": "webp"])])
        draft.sections[0].steps.append(StepDraft(name: "copy", values: ["to": "~/Sync/%f"]))
        draft.sections[0].steps.append(StepDraft(name: "delete", values: ["path": "sourceFile"]))
        let pipeline = try #require(draft.check().pipeline)
        #expect(pipeline.text == "convert(to: webp) -> copy(to: \"~/Sync/%f\") -> delete(path: sourceFile)\n")
        #expect(StepDraft(try PipelineParser.parseStep("copy(to: 'say \"hi\"')")).values["to"] == "say \"hi\"")
    }

    @Test func aWrongValueIsReportedOnItsStep() throws {
        let good = StepDraft(name: "optimise")
        let bad = StepDraft(name: "downscale", values: ["factor": "2"])
        let missing = StepDraft(name: "convert")
        var draft = PipelineDraft(name: "x", steps: [good, bad, missing])
        var check = draft.check()
        #expect(check.pipeline == nil)
        #expect(check.issues[good.id] == nil)
        #expect(check.issues[bad.id]?.first?.message.contains("factor") == true)
        #expect(check.issues[missing.id]?.isEmpty == false, "a required argument")
        draft.sections[0].steps[1].values["factor"] = "0.5"
        draft.sections[0].steps[2].values["to"] = "avif"
        check = draft.check()
        #expect(check.isValid)
    }

    @Test func pipelineWarningsLandOnTheirStep() throws {
        let filter = StepDraft(name: "if", values: ["types": "png"])
        let script = StepDraft(name: "runScript", values: ["path": "~/bin/a.sh", "code": "echo $1"])
        var draft = PipelineDraft(name: "x", steps: [StepDraft(name: "optimise"), script, StepDraft(name: "convert", values: ["to": "webp"])])
        draft.sections.append(SectionDraft(kind: .image, steps: [StepDraft(name: "stripExif")]))
        draft.filter = filter
        let check = draft.check()
        #expect(check.isValid, "warnings do not stop a save")
        #expect(Array(check.issues.keys) == [script.id], "on the script, not its neighbours: \(check.issues)")
        #expect(check.issues[script.id]?.first?.severity == .warning)
    }

    @Test func namesAreChecked() {
        let steps = [StepDraft(name: "optimise")]
        #expect(PipelineDraft(name: "", steps: steps).check().general.first == "Give the pipeline a name.")
        #expect(PipelineDraft(name: "a/b", steps: steps).check().general.isEmpty == false)
        #expect(PipelineDraft(name: "Web", steps: steps).check(existingNames: ["web"]).general.first == "There is already a pipeline named “Web”.")
        #expect(PipelineDraft(name: "Web", steps: []).check().general == ["Add at least one step."])
    }

    @Test func triggersKeepTheirOrder() {
        var draft = PipelineDraft(name: "x", steps: [StepDraft(name: "optimise")])
        draft.set(.mcp, on: true)
        draft.set(.folder("~/In"), on: true)
        draft.set(.clipboard, on: true)
        draft.set(.mcp, on: false)
        #expect(draft.triggers == [.folder("~/In"), .clipboard])
        #expect(draft.check().pipeline?.text.hasPrefix("---\ntriggers: folder(\"~/In\"), clipboard\n---\n") == true)
    }
}
