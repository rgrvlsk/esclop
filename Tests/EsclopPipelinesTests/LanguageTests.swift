// SPDX-License-Identifier: GPL-3.0-or-later
import EsclopCore
import Foundation
import Testing
@testable import EsclopPipelines

// MARK: - Round trips

/// At least one instance of every step, with non-default arguments where the step has them.
let everyStep: [PipelineStep] = [
    .optimise(),
    .optimise(encoder: .aggressive, adaptive: true, dpi: 150, location: .sameFolder, compression: .factor(64)),
    .optimise(encoder: .slowHighQuality, compression: .adaptive),
    .optimise(compression: .auto),
    .downscale(factor: 0.5),
    .downscale(factor: 0.75, location: .path("~/Exports/%f-small")),
    .lowerBitrate(kbps: 128, location: .temporary),
    .convert(to: "webp"),
    .convert(to: "mp4", location: .inPlace),
    .crop(longEdge: 1600),
    .crop(width: 1920, height: 1080, smartCrop: true, location: .sameFolder),
    .crop(aspectRatio: "1.91:1"),
    .extractPagesAsImages(),
    .extractPagesAsImages(format: .png, quality: .high, location: .path("%P/%f pages/")),
    .targetSize(bytes: 10_000_000),
    .targetSize(bytes: 2 * 1_048_576, location: .sameFolder),
    .targetSize(bytes: 1_500_000),
    .stripExif,
    .watermark(image: "~/logo.png"),
    .watermark(image: "%P/watermark.png", position: .topLeft, opacity: 0.5, scale: 0.2, location: .sameFolder),
    .copy(to: "~/Sync/"),
    .move(to: "~/Pictures/Screenshots/%y/%m/"),
    .rename(to: "%y-%m-%d %f"),
    .delete(path: "sourceFile"),
    .delete(path: "~/Downloads/%f.tmp"),
    .filterIf(FilterCondition(types: ["jpeg", "png"], regex: "^(screen\\s?shot|cleanshot)")),
    .filterIf(FilterCondition(nameContains: "draft", nameIs: "a b.png", fileSizeGreaterThan: 1000, fileSizeLowerThan: 2_000_000)),
    .filterIf(FilterCondition(widthGreaterThan: 100, widthLowerThan: 4000, heightGreaterThan: 50, heightLowerThan: 3000)),
    .filterIfNot(FilterCondition(dpiGreaterThan: 72, dpiLowerThan: 600, minFileSize: 100_000, minResolution: 640)),
    .filterIfNot(FilterCondition(copiedBy: "safari", durationGreaterThan: 1.5, durationLowerThan: 60)),
    .removeAudio,
    .changeSpeed(factor: 2.0),
    .changeSpeed(factor: 0.5, frames: .drop),
    .capFps(fps: 30),
    .normalize(),
    .normalize(lufs: -14),
    .runScript(code: "sips -Z 800 $1"),
    .runScript(path: "~/bin/thing.sh"),
    .runScript(code: #"echo "quoted" $1"#),
    .runShortcut(name: "Resize for Web"),
    .copyToClipboard(),
    .copyToClipboard(format: .markdown, relativeTo: "~/Projects/blog"),
    .copyLinkForSending(),
    .copyLinkForSending(expiration: 86400),
    .copyLinkForSending(expiration: 0),
    .fork(),
    .fork(location: .sameFolder),
    .shelveWith(app: "yoink"),
    .uploadWith(app: "dropshare"),
    .openWith(app: "Pixelmator Pro"),
    .upload(target: "R2"),
    .upload(),
]

@Test(arguments: everyStep)
func stepRoundTrips(_ step: PipelineStep) throws {
    let text = PipelineSerializer.serialize(step)
    let parsed = try PipelineParser.parseStep(text)
    #expect(parsed == step, "\(text)")
}

@Test func catalogCoversEveryStepName() {
    let names = Set(everyStep.map(\.name))
    #expect(names == Set(PipelineLanguage.steps.map(\.name)))
}

@Test func wholeFileRoundTrips() throws {
    var p = Pipeline(name: "web", description: "Make it small for the web", hotkey: "ctrl+alt+cmd+w", icon: "globe",
                     triggers: [.clipboard, .folder("~/Downloads/In, Out"), .presetZone, .mcp], optimiseFirst: true, hideResult: true)
    p[nil] = [.optimise(), .stripExif]
    p[.image] = [.crop(longEdge: 1600), .convert(to: "webp"), .copyToClipboard(format: .markdown)]
    p[.video] = [.changeSpeed(factor: 2, frames: .drop), .removeAudio, .optimise(encoder: .fast)]
    p[.pdf] = [.optimise(dpi: 150)]
    let text = p.text
    let back = try PipelineParser.parse(text, name: "web")
    #expect(back == p, "\(text)")
    #expect(PipelineSerializer.serialize(back) == text)
}

@Test func defaultsAreLeftOut() {
    #expect(PipelineSerializer.serialize(.optimise()) == "optimise")
    #expect(PipelineSerializer.serialize(.convert(to: "webp")) == "convert(to: webp)")
    #expect(PipelineSerializer.serialize(.convert(to: "webp", location: .inPlace)) == "convert(to: webp, location: inPlace)")
    #expect(PipelineSerializer.serialize(.targetSize(bytes: 10_000_000)) == "targetSize(size: 10MB)")
    #expect(PipelineSerializer.serialize(.changeSpeed(factor: 2)) == "changeSpeed(factor: 2.0)")
    #expect(PipelineSerializer.serialize(.move(to: "~/A/")) == #"move(to: "~/A/")"#)
}

// MARK: - Clop compatibility

/// Pipelines as Clop ships or documents them. Each must parse without errors.
let clopSamples = [
    "convert(to: webp)",
    #"if(regex: "^(screen\s?shot|cleanshot)") -> optimise() -> move(to: "~/Pictures/Screenshots/%y/%m/")"#,
    "downscale(factor: 0.5)",
    #"watermark(image: "%P/watermark.png")"#,
    "crop(width: 1920) -> optimise(encoder: slowHighQuality)",
    "crop(longEdge: 800) -> convert(to: gif)",
    "changeSpeed(factor: 2.0) -> removeAudio -> optimise(encoder: fast)",
    "extractPagesAsImages(format: jpeg, quality: high)",
    "convert(to: mp3)",
    "optimise -> convert(to: webp)",
    "targetSize(size: 10MB)",
    "changeSpeed(factor: 2.0, frames: drop) -> removeAudio -> optimise(encoder: fast)",
    "convert(to: mp3) -> lowerBitrate(kbps: 128)",
    #"watermark(image: "%P/logo.png", position: bottomRight) -> optimise"#,
    #"crop(longEdge: 1600) -> convert(to: webp, location: "~/Sync/Optimised/") -> copyToClipboard(format: markdown)"#,
    "optimise -> if(types: image) -> convert(to: webp)",
    "if(types: jpeg png webp)",
    #"runScript(code: "$CLOP_BIN/gs -q -sDEVICE=txtwrite -o ${1:r}.txt $1")"#,
    "copyLinkForSending(expiration: 1d)",
    "optimise -> fork -> convert(to: webp)",
    "shelveWith(app: Yoink)",
    "if(minResolution: 640x480, minFileSize: 100kb) -> optimise(compression: 80)",
    "crop(aspectRatio: 16:9, smartCrop: true)",
    "optimise(compression: adaptive)",
    "delete(path: sourceFile)",
    "ifNot(copiedBy: \"safari\") -> optimise",
    "normalize",
    "stripExif\ncopyToClipboard\nremoveAudio",
    "optimise()->convert(to: avif)",
]

@Test(arguments: clopSamples)
func clopSampleParses(_ text: String) throws {
    let result = PipelineParser.check(text)
    #expect(result.errors.isEmpty, "\(result.errors)")
    let pipeline = try #require(result.pipeline)
    #expect(!pipeline.isEmpty)
    // The canonical text parses back to the same steps.
    #expect(try PipelineParser.parseSteps(PipelineSerializer.serialize(pipeline[nil])) == pipeline[nil])
}

@Test func clopSortScreenshotsParsesToExpectedSteps() throws {
    let steps = try PipelineParser.parseSteps(#"if(regex: "^(screen\s?shot|cleanshot)") -> optimise() -> move(to: "~/Pictures/Screenshots/%y/%m/")"#)
    #expect(steps == [
        .filterIf(FilterCondition(regex: #"^(screen\s?shot|cleanshot)"#)),
        .optimise(),
        .move(to: "~/Pictures/Screenshots/%y/%m/"),
    ])
}

@Test func caseInsensitiveChoicesAreCanonicalised() throws {
    #expect(try PipelineParser.parseStep("shelveWith(app: Yoink)") == .shelveWith(app: "yoink"))
    #expect(try PipelineParser.parseStep("convert(to: WEBP)") == .convert(to: "webp"))
    #expect(try PipelineParser.parseStep("changeSpeed(factor: 2, frames: dropFrames)") == .changeSpeed(factor: 2, frames: .drop))
}

@Test func positionalArgumentIsAccepted() throws {
    #expect(try PipelineParser.parseStep("convert(webp)") == .convert(to: "webp"))
    #expect(try PipelineParser.parseStep("downscale(0.5)") == .downscale(factor: 0.5))
    #expect(try PipelineParser.parseStep("targetSize(1MB)") == .targetSize(bytes: 1_000_000))
}

@Test func quotesProtectArrowsAndCommas() throws {
    let steps = try PipelineParser.parseSteps(#"runScript(code: "a -> b, c") -> rename(to: 'x, y')"#)
    #expect(steps == [.runScript(code: "a -> b, c"), .rename(to: "x, y")])
}

@Test func commentsAndBlankLinesAreIgnored() throws {
    let text = """
    # Shrink screenshots
    optimise   # compress first

    -> stripExif
    """
    #expect(try PipelineParser.parseSteps(text) == [.optimise(), .stripExif])
}

@Test func argumentsMaySpanLines() throws {
    let text = """
    crop(
        longEdge: 1600,
        smartCrop: true,
    )
    """
    #expect(try PipelineParser.parseSteps(text) == [.crop(longEdge: 1600, smartCrop: true)])
}

@Test func byteSizes() {
    #expect(ByteSize.parse("10MB") == 10_000_000)
    #expect(ByteSize.parse("1.5MiB") == 1_572_864)
    #expect(ByteSize.parse("100kb") == 100_000)
    #expect(ByteSize.parse("2048") == 2048)
    #expect(ByteSize.parse("big") == nil)
    #expect(ByteSize.format(1_048_576) == "1MiB")
    #expect(ByteSize.format(1_500_000) == "1.5MB")
    #expect(ByteSize.format(1234) == "1234")
}

// MARK: - Errors

func firstError(_ text: String) -> PipelineDiagnostic? {
    PipelineParser.check(text).errors.first
}

@Test func unknownStepSuggestsTheRightSpelling() throws {
    let e = try #require(firstError("stripExif -> optimize(encoder: aggressive)"))
    #expect(e.line == 1)
    #expect(e.column == 14)
    #expect(e.length == 8)
    #expect(e.message == "Unknown step `optimize`. Did you mean `optimise`?")
    #expect(e.replacement == "optimise")
}

@Test func typoInStepNameIsCaught() throws {
    let e = try #require(firstError("optimise\nconvrt(to: webp)"))
    #expect(e.line == 2)
    #expect(e.column == 1)
    #expect(e.message.contains("Did you mean `convert`?"))
}

@Test func filterIfIsSuggestedAsIf() throws {
    let e = try #require(firstError("filterIf(types: png)"))
    #expect(e.message.contains("Did you mean `if`?"))
}

@Test func unknownArgumentPointsAtTheKey() throws {
    let e = try #require(firstError("crop(widht: 100)"))
    #expect(e.column == 6)
    #expect(e.message == "`crop` has no argument `widht`. Did you mean `width`?")
}

@Test func badValuePointsAtTheValue() throws {
    let e = try #require(firstError("downscale(factor: 2)"))
    #expect(e.column == 19)
    #expect(e.message.contains("only scales down"))
    let pct = try #require(firstError("downscale(factor: 50%)"))
    #expect(pct.replacement == "0.5")
}

@Test func badChoiceSuggestsAValue() throws {
    let e = try #require(firstError("convert(to: wbep)"))
    #expect(e.message.contains("Did you mean `webp`?"))
}

@Test func missingRequiredArgument() throws {
    let e = try #require(firstError("  targetSize"))
    #expect(e.column == 3)
    #expect(e.message.contains("`targetSize` needs `size`"))
    #expect(e.message.contains("targetSize(size: 10MB)"))
}

@Test func cropNeedsASize() throws {
    #expect(try #require(firstError("crop(smartCrop: true)")).message.contains("needs a size"))
}

@Test func unclosedParenthesisAndQuote() throws {
    let paren = try #require(firstError("optimise -> crop(width: 10"))
    #expect(paren.column == 17)
    #expect(paren.message.contains("never closed"))
    let quote = try #require(firstError(#"move(to: "~/Pictures)"#))
    #expect(quote.column == 10)
    #expect(quote.message.contains("never closed"))
}

@Test func missingArrowBetweenSteps() throws {
    let e = try #require(firstError("optimise stripExif"))
    #expect(e.message.contains("Missing `->`"))
    #expect(e.column == 9)
}

@Test func danglingArrows() throws {
    #expect(try #require(firstError("optimise ->")).message.contains("ends with `->`"))
    #expect(try #require(firstError("-> optimise")).message.contains("cannot start with `->`"))
    #expect(try #require(firstError("optimise -> -> stripExif")).message.contains("Two `->`"))
}

@Test func errorsOnLaterLinesHaveTheRightPosition() throws {
    let text = """
    ---
    description: test
    triggers: clipboard, foldr("~/x")
    ---
    [image]
    optimise -> convert(to: webp, location: smeFolder)
    [videos]
    """
    let errors = PipelineParser.check(text).errors
    #expect(errors.count == 3)
    #expect(errors[0].line == 3 && errors[0].column == 22 && errors[0].message.contains("Did you mean `folder`?"))
    #expect(errors[1].line == 6 && errors[1].column == 41 && errors[1].message.contains("Did you mean `sameFolder`?"))
    #expect(errors[2].line == 7 && errors[2].column == 1 && errors[2].message.contains("Did you mean `[video]`?"))
}

@Test func unclosedFrontMatter() throws {
    let e = try #require(firstError("---\ndescription: x\noptimise"))
    #expect(e.message.contains("Front matter lines look like") || e.message.contains("never closed"))
}

@Test func clopVariablesWarn() {
    let r = PipelineParser.check(#"runScript(code: "$CLOP_BIN/gs $1")"#)
    #expect(r.errors.isEmpty)
    #expect(r.warnings.first?.message.contains("ESCLOP_BIN") == true)
    #expect(r.warnings.first?.replacement == #""$ESCLOP_BIN/gs $1""#)
}

@Test func syntaxErrorBridgesToEsclopError() {
    do {
        _ = try PipelineParser.parse("optimize")
        Issue.record("expected an error")
    } catch let error as PipelineSyntaxError {
        #expect(error.esclopError == .invalidPipeline("line 1, column 1: Unknown step `optimize`. Did you mean `optimise`?"))
    } catch {
        Issue.record("wrong error \(error)")
    }
}

// MARK: - Sections

@Test func sectionsSelectStepsByKind() throws {
    let p = try PipelineParser.parse("""
    optimise

    [video]
    removeAudio -> optimise(encoder: fast)
    """)
    #expect(p.steps(for: .image) == [.optimise()])
    #expect(p.steps(for: .video) == [.removeAudio, .optimise(encoder: .fast)])
    #expect(p.kinds == Set(MediaKind.allCases))
}

// MARK: - Completions

func labels(_ text: String, kind: MediaKind? = nil) -> [String] {
    PipelineLanguage.completions(in: text, at: text.utf16.count, kind: kind).map(\.label)
}

@Test func completesStepNames() throws {
    let c = PipelineLanguage.completions(in: "optimise -> conv", at: 16)
    let first = try #require(c.first)
    #expect(first.label == "convert(to, location?)")
    #expect(first.insertText == "convert(to: ")
    #expect(first.replaceStart == 12 && first.replaceLength == 4)
}

@Test func stepNamesFilterByKind() {
    #expect(!labels("remove", kind: .image).contains("removeAudio"))
    #expect(labels("remove", kind: .video) == ["removeAudio"])
    #expect(labels("optimize").first?.hasPrefix("optimise") == true)
}

@Test func completesParametersNotYetUsed() {
    let l = labels("crop(width: 100, ")
    #expect(!l.contains("width"))
    #expect(l.contains("height") && l.contains("smartCrop"))
}

@Test func completesValues() {
    #expect(labels("convert(to: w", kind: .image) == ["webp"])
    #expect(labels("convert(to: ", kind: .audio).contains("mp3"))
    #expect(labels("optimise(encoder: ", kind: .video) == ["fast", "slowHighQuality", "visuallyLossless"])
    #expect(labels("crop(longEdge: 10, location: s") == ["sameFolder"])
    #expect(labels("convert(").contains("webp"))
}

@Test func completesTemplateTokensInsideQuotes() throws {
    let c = PipelineLanguage.completions(in: #"move(to: "~/Pictures/%"#, at: 22)
    #expect(c.map(\.label).contains("%y"))
    #expect(c.first?.replaceStart == 21 && c.first?.replaceLength == 1)
}

@Test func completesSectionsAndFrontMatter() {
    #expect(labels("optimise\n[vi") == ["[video]"])
    #expect(labels("---\ntrig") == ["triggers"])
    #expect(labels("---\ntriggers: clipboard, fo") == ["folder"])
}

@Test func completionHandlesNonASCII() {
    // "é" is one UTF-16 unit, an emoji two: offsets must still line up.
    let text = "rename(to: \"🎉\") -> conv"
    let c = PipelineLanguage.completions(in: text, at: text.utf16.count)
    #expect(c.first?.replaceStart == text.utf16.count - 4)
}

// MARK: - Describe

@Test func describesInProse() throws {
    let p = try PipelineParser.parse(#"""
    ---
    triggers: clipboard, folder("~/Desktop")
    ---
    [image]
    if(regex: "^IMG_") -> crop(longEdge: 1600) -> convert(to: webp) -> move(to: "~/Pictures/%y/")
    """#, name: "photos")
    let prose = PipelineLanguage.describe(p)
    #expect(prose.contains("For images: continue only if its name matches `^IMG_` (other files stop here); then resize it so the longest side is 1600 px; then convert it to WebP, saving the result next to the original; then move it to ~/Pictures/<year>/."))
    #expect(prose.contains("It runs when you copy a file or image and when new files appear in ~/Desktop."))
}

@Test func everyStepHasADescription() {
    for step in everyStep {
        #expect(!PipelineLanguage.describe(step).isEmpty)
    }
}

@Test func referenceListsEveryStep() {
    let ref = PipelineLanguage.referenceMarkdown()
    for spec in PipelineLanguage.steps {
        #expect(ref.contains("`\(spec.signature)`"))
    }
}

@Test func docsListEveryStepAndToken() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let docs = try String(contentsOf: root.appendingPathComponent("docs/pipelines.md"), encoding: .utf8)
    for spec in PipelineLanguage.steps {
        #expect(docs.contains("`\(spec.name)"), "docs/pipelines.md does not document \(spec.name)")
        for p in spec.params { #expect(docs.contains("`\(p.name)`"), "docs/pipelines.md does not document \(spec.name).\(p.name)") }
    }
    for t in PipelineLanguage.templateTokens { #expect(docs.contains("`\(t.token)`")) }
}
