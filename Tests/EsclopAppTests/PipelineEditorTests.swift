// SPDX-License-Identifier: GPL-3.0-or-later

import EsclopCore
import EsclopIPC
import EsclopPipelines
@testable import EsclopAppKit
import Foundation
import Testing

/// The pipeline editor's model over a temporary store.
@MainActor @Suite struct PipelineEditorTests {
    let temp = TempDir()
    var store: PipelineStore { PipelineStore(directory: temp.url.appendingPathComponent("pipelines", isDirectory: true), useTrash: false) }

    func editor() -> PipelineEditorModel {
        let engine = ShrinkingEngine(backups: temp.url.appendingPathComponent("backups", isDirectory: true))
        return PipelineEditorModel(store: store, engine: engine)
    }

    func fileText(_ name: String) throws -> String {
        try String(contentsOf: store.directory.appendingPathComponent("\(name).pipeline"), encoding: .utf8)
    }

    @Test func aNewPipelineIsSavedAsTheSerializerWritesIt() throws {
        let model = editor()
        model.newPipeline()
        #expect(model.selection == .new)
        model.draft.name = "Web"
        model.addStep("convert")
        model.draft.sections[0].steps[1].values["to"] = "webp"
        model.draft.set(.clipboard, on: true)
        model.draft.set(.folder("~/Desktop/To blog"), on: true)
        model.save()
        #expect(model.failure == nil)
        #expect(model.selection == .saved("Web"))
        let saved = try store.load("Web")
        #expect(try fileText("Web") == PipelineSerializer.serialize(saved), "byte for byte")
        #expect(try fileText("Web") == "---\ntriggers: clipboard, folder(\"~/Desktop/To blog\")\n---\noptimise -> convert(to: webp)\n")
        #expect(!model.hasChanges)
        let app = Harness()
        _ = try app.model.service.context.pipelines.save(saved)
        #expect(app.model.pipelineNames == ["Web"], "the Share tab lists what the editor saves")
    }

    @Test func templatesAreReadOnlyAndDuplicateIntoAnEditableCopy() throws {
        let model = editor()
        let template = try #require(model.templates.first)
        model.request(.template(template.name))
        #expect(model.isTemplate)
        model.save()
        #expect(try store.list().isEmpty, "a template is never saved over")
        model.duplicate()
        #expect(model.selection == .new)
        #expect(model.draft.name == "\(template.name) copy")
        model.save()
        var expected = template
        expected.name = "\(template.name) copy"
        #expect(try store.load(expected.name) == expected)
        #expect(try fileText(expected.name) == PipelineSerializer.serialize(expected))
    }

    @Test func renameEditAndDelete() throws {
        _ = try store.save(Pipeline(name: "Old", steps: [.optimise()]))
        let model = editor()
        model.request(.saved("Old"))
        model.draft.name = "New"
        model.addStep("stripExif")
        model.save()
        #expect(try store.list().map(\.name) == ["New"])
        #expect(try store.load("New")[nil].map(\.name) == ["optimise", "stripExif"])
        model.delete()
        #expect(try store.list().isEmpty)
    }

    @Test func movingAndRemovingSteps() throws {
        let model = editor()
        model.newPipeline()
        model.addStep("stripExif")
        model.addStep("downscale")
        let ids = model.draft.sections[0].steps.map(\.id)
        model.moveStep(ids[2], by: -1)
        #expect(model.draft.sections[0].steps.map(\.name) == ["optimise", "downscale", "stripExif"])
        model.moveStep(ids[0], by: -1)
        #expect(model.draft.sections[0].steps.first?.id == ids[0], "the first step cannot move up")
        model.moveSteps(from: [0], to: 3)
        #expect(model.draft.sections[0].steps.map(\.name) == ["downscale", "stripExif", "optimise"])
        model.removeStep(ids[1])
        #expect(model.draft.sections[0].steps.map(\.name) == ["downscale", "optimise"])
        #expect(model.check.issues[ids[2]]?.isEmpty == false, "downscale needs its factor")
    }

    @Test func unsavedChangesAskBeforeSwitching() throws {
        _ = try store.save(Pipeline(name: "A", steps: [.optimise()]))
        _ = try store.save(Pipeline(name: "B", steps: [.stripExif]))
        let model = editor()
        model.request(.saved("A"))
        model.addStep("stripExif")
        model.request(.saved("B"))
        #expect(model.selection == .saved("A"))
        #expect(model.pendingSelection == .saved("B"))
        model.select(model.pendingSelection)
        #expect(model.selection == .saved("B"))
        #expect(try store.load("A")[nil].count == 1, "discarded")
    }

    @Test func theTextViewFollowsTheFormAndKeepsTextWithErrors() throws {
        let model = editor()
        model.newPipeline()
        model.draft.name = "T"
        model.setShowsText(true)
        #expect(model.text == "optimise\n")
        model.editText("optimise -> convert(to: webp)\n")
        #expect(model.textDiagnostics.isEmpty)
        #expect(model.draft.sections[0].steps.map(\.text) == ["optimise", "convert(to: webp)"], "the form follows")
        let broken = "---\ntriggers: clipboard\n---\noptimise -> convert(to: bmpx)\n"
        model.editText(broken)
        #expect(model.text == broken, "kept as typed")
        let error = try #require(model.textDiagnostics.first { $0.severity == .error })
        #expect(error.line == 4, "the line is marked")
        model.setShowsText(false)
        #expect(model.showsText, "the form waits until the text reads")
        model.save()
        #expect(try store.list().isEmpty)
        model.editText("---\ntriggers: clipboard\n---\noptimise -> convert(to: avif)\n")
        model.setShowsText(false)
        #expect(!model.showsText)
        #expect(model.draft.triggers == [.clipboard])
        model.save()
        #expect(try fileText("T") == "---\ntriggers: clipboard\n---\noptimise -> convert(to: avif)\n")
    }

    @Test func aFileWithErrorsOpensInTheTextView() throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try "optimise -> nonsense\n".write(to: store.directory.appendingPathComponent("Broken.pipeline"), atomically: true, encoding: .utf8)
        let model = editor()
        model.request(.saved("Broken"))
        #expect(model.showsText)
        #expect(model.text == "optimise -> nonsense\n")
        #expect(model.textDiagnostics.first?.line == 1)
    }

    @Test func tryItRunsOnACopyAndLeavesTheOriginal() async throws {
        let model = editor()
        model.newPipeline()
        model.addStep("rename")
        model.draft.sections[0].steps[1].values["to"] = "%f-tried"
        let original = temp.file("photo.png", bytes: 100_000)
        let before = try Data(contentsOf: original)
        let modified = try FileManager.default.attributesOfItem(atPath: original.path)[.modificationDate] as? Date
        await model.tryIt(on: original)
        guard case let .done(result) = model.tryState else {
            Issue.record("no result: \(model.tryState)")
            return
        }
        #expect(result.status == .completed)
        #expect(result.steps.map(\.outcome) == [.done, .done])
        #expect(result.bytesBefore == 100_000 && result.bytesAfter == 40_000)
        #expect(result.finalFile?.lastPathComponent == "photo-tried.png")
        #expect(result.finalFile?.deletingLastPathComponent().path != original.deletingLastPathComponent().path)
        #expect(try Data(contentsOf: original) == before, "the original is only read")
        #expect(try FileManager.default.attributesOfItem(atPath: original.path)[.modificationDate] as? Date == modified)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path).filter { $0.hasPrefix("photo") } == ["photo.png"], "nothing new beside it")
        #expect(PipelineTryResultView(result: result).summary.contains("60"))
    }

    @Test func theFilterIsCheckedAgainstASampleFile() async throws {
        let model = editor()
        model.newPipeline()
        model.setFilter(true)
        model.draft.filter?.values = ["types": "png"]
        model.setSample(temp.file("shot.png"))
        await model.checkFilter()
        #expect(model.filterMatches == true)
        model.draft.filter?.values = ["types": "jpeg"]
        await model.checkFilter()
        #expect(model.filterMatches == false)
        model.draft.filter?.values = ["nameContains": "sho", "types": "png"]
        await model.checkFilter()
        #expect(model.filterMatches == true)
        #expect(model.check.pipeline?.text == "if(types: png, nameContains: \"sho\") -> optimise\n")
    }

    @Test func linksOpenTheWindowOnAPipeline() throws {
        #expect(PipelineEditorWindowController.route(URL(string: "esclop://pipelines")!) == PipelinesRoute(name: nil))
        #expect(PipelineEditorWindowController.route(URL(string: "esclop://pipelines/Shots%20to%20web")!) == PipelinesRoute(name: "Shots to web"))
        #expect(PipelineEditorWindowController.route(URL(string: "esclop://settings/images")!) == nil)
        _ = try store.save(Pipeline(name: "Shots to web", steps: [.optimise()]))
        let model = editor()
        model.open(name: "shots to WEB")
        #expect(model.selection == .saved("Shots to web"))
        model.open(name: try #require(model.templates.last?.name))
        #expect(model.isTemplate)
        model.open(name: "missing")
        #expect(model.failure == "There is no pipeline named “missing”.")
    }

    @Test func scriptStepsAreShownAsScripts() throws {
        let draft = PipelineDraft(try PipelineParser.parse("optimise -> runScript(code: \"echo $1\")", name: "s"))
        #expect(draft.hasScripts)
        #expect(draft.sections[0].steps[1].values["code"] == "echo $1")
        #expect(!PipelineDraft(try PipelineParser.parse("optimise", name: "s")).hasScripts)
    }
}

/// P2, P3: a file that did not read is not "changed" until its text is, and "Try it" cleans up.
@MainActor @Suite struct PipelineEditorHousekeepingTests {
    let temp = TempDir()
    var store: PipelineStore { PipelineStore(directory: temp.url.appendingPathComponent("pipelines", isDirectory: true), useTrash: false) }

    func editor() -> PipelineEditorModel {
        let model = PipelineEditorModel(store: store, engine: ShrinkingEngine(backups: temp.url.appendingPathComponent("backups", isDirectory: true)))
        model.tryRoot = temp.url.appendingPathComponent("tries", isDirectory: true)
        return model
    }

    @Test func aBrokenFileOpenedAndLeftAloneIsNotChanged() throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try "optimise -> nonsense\n".write(to: store.directory.appendingPathComponent("broken.pipeline"), atomically: true, encoding: .utf8)
        _ = try store.save(Pipeline(name: "good", steps: [.optimise()]))
        let model = editor()
        model.request(.saved("broken"))
        #expect(!model.hasChanges)
        model.request(.saved("good"))
        #expect(model.pendingSelection == nil, "no question")
        #expect(model.selection == .saved("good"))
        model.request(.saved("broken"))
        model.editText("optimise -> nonsens\n")
        #expect(model.hasChanges)
        model.request(.saved("good"))
        #expect(model.pendingSelection == .saved("good"), "now it asks")
    }

    @Test func warningsAloneAreNotChanges() throws {
        _ = try store.save(text: "runScript(path: \"~/a.sh\", code: \"echo $1\")", name: "warned")
        let model = editor()
        model.request(.saved("warned"))
        model.setShowsText(true)
        #expect(!model.textDiagnostics.isEmpty || model.text.contains("runScript"))
        #expect(!model.hasChanges)
    }

    @Test func eachTryReplacesTheLastAndANewSelectionRemovesIt() async throws {
        _ = try store.save(Pipeline(name: "a", steps: [.optimise()]))
        _ = try store.save(Pipeline(name: "b", steps: [.stripExif]))
        let model = editor()
        model.request(.saved("a"))
        await model.tryIt(on: temp.file("one.png"))
        let first = try #require(model.tryFolder)
        await model.tryIt(on: temp.file("two.png"))
        let second = try #require(model.tryFolder)
        #expect(!FileManager.default.fileExists(atPath: first.path), "the previous try is gone")
        #expect(FileManager.default.fileExists(atPath: second.path))
        model.request(.saved("b"))
        #expect(!FileManager.default.fileExists(atPath: second.path), "a new selection removes it")
        #expect(model.tryFolder == nil)
    }

    @Test func leftoversAreClearedAtLaunch() throws {
        let root = temp.url.appendingPathComponent("tmp", isDirectory: true)
        for name in ["try-1", "try-2", "clipboard-keep"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        PipelineEditorModel.removeLeftovers(in: root)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["clipboard-keep"])
    }
}
