// SPDX-License-Identifier: GPL-3.0-or-later
//
// Writes pipelines back as text. Steps come out in the form Clop reads (named arguments, values
// quoted where Clop expects quotes, defaults left out), so a serialized section pastes into Clop.

import EsclopCore
import Foundation

public enum PipelineSerializer {
    /// The whole `.pipeline` file: front matter when there is metadata, the "any file" steps,
    /// then one section per kind.
    public static func serialize(_ pipeline: Pipeline) -> String {
        var out = ""
        var meta: [String] = []
        if let d = pipeline.description, !d.isEmpty { meta.append("description: \(singleLine(d))") }
        if let h = pipeline.hotkey, !h.isEmpty { meta.append("hotkey: \(singleLine(h))") }
        if let i = pipeline.icon, !i.isEmpty { meta.append("icon: \(singleLine(i))") }
        if !pipeline.triggers.isEmpty { meta.append("triggers: " + pipeline.triggers.map(\.description).joined(separator: ", ")) }
        if pipeline.optimiseFirst { meta.append("optimiseFirst: true") }
        if pipeline.hideResult { meta.append("hideResult: true") }
        if !meta.isEmpty {
            out += "---\n" + meta.joined(separator: "\n") + "\n---\n"
        }

        let any = pipeline[nil]
        var blocks: [String] = []
        if !any.isEmpty { blocks.append(serialize(any)) }
        for section in pipeline.sections where section.kind != nil && !section.steps.isEmpty {
            blocks.append("[\(section.kind!.rawValue)]\n" + serialize(section.steps))
        }
        out += blocks.joined(separator: "\n\n")
        return out + "\n"
    }

    /// Steps on one line joined by ` -> `.
    public static func serialize(_ steps: [PipelineStep]) -> String {
        steps.map(serialize).joined(separator: " -> ")
    }

    /// One step, e.g. `convert(to: webp)`. Steps with nothing but defaults are written bare.
    public static func serialize(_ step: PipelineStep) -> String {
        guard let spec = PipelineLanguage.spec(named: step.name) else { return step.name }
        let args = arguments(of: step).filter { name, value in spec.param(name)?.defaultValue != value }
        guard !args.isEmpty else { return step.name }
        return "\(step.name)(" + args.map { "\($0.0): \($0.1)" }.joined(separator: ", ") + ")"
    }

    /// Every argument the step sets, as text, in the catalog's order.
    static func arguments(of step: PipelineStep) -> [(String, String)] {
        var a: [(String, String)] = []
        func add(_ name: String, _ value: String?) { if let value { a.append((name, value)) } }
        func loc(_ l: OutputLocation?) -> String? {
            guard let l else { return nil }
            if case let .path(p) = l { return quote(p) }
            return l.pipelineText
        }
        switch step {
        case let .optimise(encoder, adaptive, dpi, location, compression):
            add("encoder", encoder.rawValue)
            add("compression", compression?.text)
            add("adaptive", String(adaptive))
            add("dpi", dpi.map(String.init))
            add("location", loc(location))
        case let .downscale(factor, location):
            add("factor", number(factor))
            add("location", loc(location))
        case let .lowerBitrate(kbps, location):
            add("kbps", String(kbps))
            add("location", loc(location))
        case let .convert(to, location):
            add("to", to)
            add("location", loc(location))
        case let .crop(width, height, longEdge, aspectRatio, smartCrop, location):
            add("width", width.map(String.init))
            add("height", height.map(String.init))
            add("longEdge", longEdge.map(String.init))
            add("aspectRatio", aspectRatio)
            add("smartCrop", String(smartCrop))
            add("location", loc(location))
        case let .extractPagesAsImages(format, quality, location):
            add("format", format.rawValue)
            add("quality", quality.rawValue)
            add("location", loc(location))
        case let .targetSize(bytes, location):
            add("size", ByteSize.format(bytes))
            add("location", loc(location))
        case .stripExif, .removeAudio:
            break
        case let .watermark(image, position, opacity, scale, location):
            add("image", quote(image))
            add("position", position.rawValue)
            add("opacity", number(opacity))
            add("scale", number(scale))
            add("location", loc(location))
        case let .copy(to), let .move(to), let .rename(to):
            add("to", quote(to))
        case let .delete(path):
            add("path", ["sourceFile", "currentFile"].contains(path) ? path : quote(path))
        case let .filterIf(c), let .filterIfNot(c):
            add("types", c.types?.joined(separator: " "))
            add("regex", c.regex.map(quote))
            add("nameContains", c.nameContains.map(quote))
            add("nameIs", c.nameIs.map(quote))
            // Clop reads these two as plain byte counts.
            add("fileSizeGreaterThan", c.fileSizeGreaterThan.map(String.init))
            add("fileSizeLowerThan", c.fileSizeLowerThan.map(String.init))
            add("minFileSize", c.minFileSize.map(ByteSize.format))
            add("widthGreaterThan", c.widthGreaterThan.map(String.init))
            add("widthLowerThan", c.widthLowerThan.map(String.init))
            add("heightGreaterThan", c.heightGreaterThan.map(String.init))
            add("heightLowerThan", c.heightLowerThan.map(String.init))
            add("minResolution", c.minResolution.map { "\($0)x\($0)" })
            add("dpiGreaterThan", c.dpiGreaterThan.map(String.init))
            add("dpiLowerThan", c.dpiLowerThan.map(String.init))
            add("durationGreaterThan", c.durationGreaterThan.map { number($0, keepPoint: false) })
            add("durationLowerThan", c.durationLowerThan.map { number($0, keepPoint: false) })
            add("copiedBy", c.copiedBy.map(quote))
        case let .changeSpeed(factor, frames):
            add("factor", number(factor))
            add("frames", frames?.rawValue)
        case let .capFps(fps):
            add("fps", String(fps))
        case let .normalize(lufs):
            add("lufs", number(lufs, keepPoint: false))
        case let .runScript(path, code):
            add("path", path.map(quote))
            add("code", code.map(quote))
        case let .runShortcut(name):
            add("name", quote(name))
        case let .copyToClipboard(format, relativeTo):
            add("format", format.rawValue)
            add("relativeTo", relativeTo.map(quote))
        case let .copyLinkForSending(expiration):
            add("expiration", expiration.map(Durations.format))
        case let .fork(location):
            add("location", loc(location))
        case let .shelveWith(app), let .uploadWith(app):
            add("app", app)
        case let .openWith(app):
            add("app", quote(app))
        }
        return a
    }

    /// Double quotes unless the text contains one; then single quotes (the language has no escapes).
    public static func quote(_ s: String) -> String {
        s.contains("\"") && !s.contains("'") ? "'\(s)'" : "\"\(s)\""
    }

    /// `0.5`, `2.0` (or `2` without `keepPoint`), `-16`.
    public static func number(_ d: Double, keepPoint: Bool = true) -> String {
        if d == d.rounded(), abs(d) < 1e15 {
            return keepPoint ? "\(Int(d)).0" : "\(Int(d))"
        }
        return "\(d)"
    }

    static func singleLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
    }
}
