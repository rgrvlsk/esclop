// SPDX-License-Identifier: GPL-3.0-or-later
import EsclopCore
import Foundation
import Testing
@testable import EsclopPipelines

func store(_ tmp: TempDir) -> PipelineStore {
    PipelineStore(directory: tmp.url.appendingPathComponent("pipelines"), useTrash: false)
}

@Test func storeRoundTrips() throws {
    let tmp = try TempDir()
    let s = store(tmp)
    var p = Pipeline(name: "Web ready", description: "small for the web", triggers: [.dropZone])
    p[.image] = [.crop(longEdge: 1600), .convert(to: "webp")]
    let url = try s.save(p)
    #expect(url.lastPathComponent == "Web ready.pipeline")
    #expect(try s.load("Web ready") == p)
    #expect(try s.load("web READY") == p)
    #expect(try s.list() == [p])
    #expect(try String(contentsOf: url, encoding: .utf8) == p.text)
}

@Test func saveTextKeepsCommentsAndRejectsErrors() throws {
    let tmp = try TempDir()
    let s = store(tmp)
    let text = "# my notes\noptimise -> convert(to: webp)\n"
    try s.save(text: text, name: "notes")
    #expect(try s.text(of: "notes") == text)
    #expect(throws: PipelineSyntaxError.self) { try s.save(text: "optimize", name: "bad") }
    #expect(!s.contains("bad"))
}

@Test func listShowsBrokenFilesWithDiagnostics() throws {
    let tmp = try TempDir()
    let s = store(tmp)
    try s.save(Pipeline(name: "b", steps: [.optimise()]))
    try "convrt(to: webp)\n".write(to: s.fileURL(for: "a"), atomically: true, encoding: .utf8)
    try "ignored".write(to: s.directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    let entries = try s.entries()
    #expect(entries.map(\.name) == ["a", "b"])
    #expect(entries[0].pipeline == nil)
    #expect(entries[0].diagnostics.first?.message.contains("Did you mean `convert`?") == true)
    #expect(try s.list().map(\.name) == ["b"])
}

@Test func renameAndDelete() throws {
    let tmp = try TempDir()
    let s = store(tmp)
    try s.save(Pipeline(name: "one", steps: [.optimise()]))
    try s.save(Pipeline(name: "two", steps: [.stripExif]))
    #expect(throws: EsclopError.self) { try s.rename("one", to: "two") }
    try s.rename("one", to: "uno")
    #expect(try s.load("uno").name == "uno")
    #expect(!s.contains("one"))
    try s.rename("uno", to: "Uno") // case-only rename
    #expect(try s.entries().map(\.name).contains("Uno"))
    try s.delete("Uno")
    #expect(try s.list().map(\.name) == ["two"])
    #expect(throws: EsclopError.self) { try s.delete("nothing") }
    #expect(throws: EsclopError.self) { try s.save(Pipeline(name: "two"), overwrite: false) }
}

@Test func namesMustBeFileNames() {
    for bad in ["", " x", "a/b", "a:b", ".hidden", "two\nlines"] {
        #expect(throws: EsclopError.self, "\(bad)") { try PipelineStore.validate(name: bad) }
    }
    #expect(throws: Never.self) { try PipelineStore.validate(name: "0.5× café") }
}

@Test func attachAndDetachTriggers() throws {
    let tmp = try TempDir()
    let s = store(tmp)
    try s.save(Pipeline(name: "p", steps: [.optimise()]))
    try s.attach(.clipboard, to: "p")
    try s.attach(.folder("~/Downloads"), to: "p")
    try s.attach(.folder("~/Downloads/"), to: "p") // same folder
    #expect(try s.load("p").triggers == [.clipboard, .folder("~/Downloads")])
    #expect(try s.pipelines(triggeredBy: .clipboard).map(\.name) == ["p"])
    #expect(try s.pipelines(triggeredBy: .folder(FileManager.default.homeDirectoryForCurrentUser.path + "/Downloads")).count == 1)
    #expect(try s.detach(.folder("~/Downloads"), from: "p"))
    #expect(try !s.detach(.mcp, from: "p"))
    #expect(try s.load("p").triggers == [.clipboard])
}

@Test func presetsParseAndInstall() throws {
    #expect(PipelineStore.presets.map(\.name) == ["to WebP", "sort screenshots", "fit under 1 MB", "video to GIF", "pdf for sending"])
    #expect(PipelineStore.preset(named: "TO WEBP")?.steps(for: .image) == [.convert(to: "webp")])
    #expect(PipelineStore.preset(named: "fit under 1 MB")?.steps(for: .video) == [.targetSize(bytes: 1_000_000)])
    #expect(PipelineStore.presets.allSatisfy { $0.description != nil && $0.icon != nil })
    let tmp = try TempDir()
    let s = store(tmp)
    try s.install(preset: "sort screenshots")
    #expect(try s.load("sort screenshots") == PipelineStore.preset(named: "sort screenshots"))
    #expect(throws: EsclopError.self) { try s.install(preset: "sort screenshots") }
    #expect(throws: EsclopError.self) { try s.install(preset: "nope") }
}

@Test func resolveTriesSavedThenPresetThenInline() throws {
    let tmp = try TempDir()
    let s = store(tmp)
    try s.save(Pipeline(name: "to WebP", steps: [.stripExif]))
    #expect(try s.resolve("to WebP")[nil] == [.stripExif])
    #expect(try s.resolve("video to GIF").name == "video to GIF")
    #expect(try s.resolve("optimise -> stripExif")[nil] == [.optimise(), .stripExif])
    #expect(throws: PipelineSyntaxError.self) { try s.resolve("not a pipeline") }
}

@Test func missingDirectoryListsNothing() throws {
    let tmp = try TempDir()
    #expect(try store(tmp).list().isEmpty)
}
