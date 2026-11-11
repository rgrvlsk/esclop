// SPDX-License-Identifier: GPL-3.0-or-later
//
// Help for editors and agents: the step catalog (StepCatalog.swift), completions at a cursor,
// a prose explanation of a pipeline and a compact reference of the language.

import EsclopCore
import Foundation

public enum PipelineLanguage {
    public static let frontMatterKeys = ["description", "hotkey", "icon", "triggers", "optimiseFirst", "hideResult"]
    public static let sectionNames = ["any", "image", "video", "pdf", "audio"]

    /// The step a misspelling or a name from another tool most likely means.
    public static func alias(for name: String) -> String? {
        aliases[name] ?? aliases.first { $0.key.lowercased() == name.lowercased() }?.value
    }
}

// MARK: - Completions

public struct PipelineCompletion: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case step, parameter, value, templateToken, section, frontMatterKey, trigger
    }

    public var kind: Kind
    /// What to show in the list.
    public var label: String
    /// What to insert in place of the replaced range.
    public var insertText: String
    /// One line of help.
    public var detail: String
    /// Start of the text to replace, in UTF-16 code units (the unit of `NSRange`).
    public var replaceStart: Int
    public var replaceLength: Int
}

extension PipelineLanguage {
    /// Suggestions for the cursor at `offset` (UTF-16 code units into `text`). Pass the kind of
    /// file the pipeline is for to hide steps and arguments that do not apply to it.
    public static func completions(in text: String, at offset: Int, kind: MediaKind? = nil) -> [PipelineCompletion] {
        let clamped = max(0, min(offset, text.utf16.count))
        let end = String.Index(utf16Offset: clamped, in: text)
        let chars = Array(text[..<end])
        var utf16: [Int] = []
        var o = 0
        for c in chars {
            utf16.append(o)
            o += c.utf16.count
        }
        utf16.append(o)

        // Front matter: the text opens with `---` and has not closed it yet.
        let lines = String(chars).components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           !lines.dropFirst().dropLast().contains(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
           lines.count > 1
        {
            return frontMatterCompletions(line: lines.last ?? "", lineEndUTF16: o)
        }

        // One pass over the prefix to find where the cursor is.
        var quote: Character?
        var quoteStart = 0
        var depth = 0
        var inComment = false
        var segmentStart = 0
        var openParen: Int?
        var argStart = 0
        var prev: Character?
        for (i, c) in chars.enumerated() {
            defer { prev = c }
            if inComment {
                if c == "\n" {
                    inComment = false
                    segmentStart = i + 1
                }
                continue
            }
            if let q = quote {
                if q == c { quote = nil }
                continue
            }
            switch c {
            case "\"", "'":
                quote = c
                quoteStart = i
            case "#" where depth == 0:
                inComment = true
            case "(":
                if depth == 0 {
                    openParen = i
                    argStart = i + 1
                }
                depth += 1
            case ")":
                depth = max(0, depth - 1)
                if depth == 0 { openParen = nil }
            case "," where depth == 1:
                argStart = i + 1
            case "\n" where depth == 0:
                segmentStart = i + 1
            case ">" where depth == 0 && prev == "-":
                segmentStart = i + 1
            default: break
            }
        }
        if inComment { return [] }

        // Outside parentheses: a step name or a section header.
        guard let open = openParen, depth > 0 else {
            let segment = String(chars[segmentStart...])
            let trimmed = segment.drop { $0 == " " || $0 == "\t" }
            if trimmed.hasPrefix("[") {
                let typed = trimmed.dropFirst().prefix { $0 != "]" }
                let start = o - typed.utf16.count
                return sectionNames.filter { $0.hasPrefix(typed.lowercased()) }.map {
                    PipelineCompletion(kind: .section, label: "[\($0)]", insertText: "\($0)]", detail: $0 == "any" ? "steps for every kind of file" : "steps for \($0) files", replaceStart: start, replaceLength: typed.utf16.count)
                }
            }
            let typed = String(chars[segmentStart...].reversed().prefix { Parser.isIdentifier($0) }.reversed())
            // After a finished step with no `->`, nothing sensible to offer.
            if typed.isEmpty, trimmed.contains(where: { !Parser.isSpace($0) }) { return [] }
            return stepCompletions(typed: typed, replaceStart: o - typed.utf16.count, kind: kind)
        }

        // Inside `step(...)`.
        let name = String(chars[segmentStart ..< open].reversed().prefix { Parser.isIdentifier($0) }.reversed())
        guard let spec = spec(named: name) else { return [] }
        let usedKeys = Set(splitOutsideQuotes(String(chars[(open + 1) ..< argStart]), on: ",").compactMap { part -> String? in
            guard let colon = part.firstIndex(of: ":") else { return nil }
            return part[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        })
        let arg = String(chars[argStart...])
        let params = spec.params.filter { p in kind.map { k in p.kinds?.contains(k) ?? true } ?? true }

        if quote != nil {
            // Inside a quoted value: offer template tokens after `%` or at the start.
            let quoted = String(chars[(quoteStart + 1)...])
            if quoted.hasSuffix("%") || quoted.isEmpty {
                let replaceFrom = quoted.hasSuffix("%") ? o - 1 : o
                return templateTokens.filter { $0.token.hasPrefix("%") || quoted.isEmpty }.map {
                    PipelineCompletion(kind: .templateToken, label: $0.token, insertText: $0.token, detail: $0.meaning, replaceStart: replaceFrom, replaceLength: o - replaceFrom)
                }
            }
            return []
        }

        if let colon = arg.firstIndex(of: ":") {
            let key = arg[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let typed = arg[arg.index(after: colon)...].drop { $0 == " " || $0 == "\t" }
            guard let param = spec.param(key) else { return [] }
            return valueCompletions(param: param, step: spec, typed: String(typed), replaceStart: o - typed.utf16.count, kind: kind)
        }

        let typed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = o - typed.utf16.count
        var out = params.filter { !usedKeys.contains($0.name) && $0.name.lowercased().hasPrefix(typed.lowercased()) }.map {
            PipelineCompletion(kind: .parameter, label: $0.name, insertText: "\($0.name): ", detail: ($0.required ? "required. " : "") + $0.doc, replaceStart: start, replaceLength: typed.utf16.count)
        }
        // The positional argument can take a value straight away.
        if usedKeys.isEmpty, argStart == open + 1, let positional = spec.positional, let param = spec.param(positional) {
            out += valueCompletions(param: param, step: spec, typed: typed, replaceStart: start, kind: kind).filter { v in !out.contains { $0.label == v.label } }
        }
        return out
    }

    static func stepCompletions(typed: String, replaceStart: Int, kind: MediaKind?) -> [PipelineCompletion] {
        let lower = typed.lowercased()
        let candidates = steps.filter { s in kind.map { s.kinds.contains($0) } ?? true }
        let prefixed = candidates.filter { $0.name.lowercased().hasPrefix(lower) }
        let contained = candidates.filter { !$0.name.lowercased().hasPrefix(lower) && $0.name.lowercased().contains(lower) }
        var result = prefixed + contained
        if result.isEmpty, let target = alias(for: typed) ?? Parser.closest(typed, in: candidates.map(\.name)), let s = spec(named: target) {
            result = [s]
        }
        return result.map { s in
            let insert: String = if let first = s.requiredParams.first {
                "\(s.name)(\(first.name): "
            } else {
                s.name
            }
            return PipelineCompletion(kind: .step, label: s.signature, insertText: insert, detail: s.summary, replaceStart: replaceStart, replaceLength: typed.utf16.count)
        }
    }

    static func valueCompletions(param: ParamSpec, step: StepSpec, typed: String, replaceStart: Int, kind: MediaKind?) -> [PipelineCompletion] {
        var values: [(String, String)]
        switch (step.name, param.name) {
        case ("convert", "to"):
            values = convertTargets.filter { t in kind.map { t.kinds.contains($0) } ?? true }.map { ($0.name, $0.doc) }
        case ("optimise", "encoder"):
            values = EncoderPreset.allCases.filter { e in
                guard let kind else { return true }
                return kind == .video ? e.isVideo : !e.isVideo
            }.map { ($0.rawValue, $0.isVideo ? "video encoder preset" : "encoder quality") }
        default:
            values = param.type.suggestions.map { ($0, param.doc) }
        }
        if case .location = param.type {
            values.append(("\"%P/%f\"", "a path template; see the template tokens"))
        }
        let lower = typed.lowercased()
        return values.filter { $0.0.lowercased().hasPrefix(lower) }.map {
            PipelineCompletion(kind: .value, label: $0.0, insertText: $0.0, detail: $0.1, replaceStart: replaceStart, replaceLength: typed.utf16.count)
        }
    }

    static func frontMatterCompletions(line: String, lineEndUTF16: Int) -> [PipelineCompletion] {
        if let colon = line.firstIndex(of: ":") {
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...]
            switch key {
            case "triggers":
                let typed = String(value.split(separator: ",", omittingEmptySubsequences: false).last ?? "").trimmingCharacters(in: .whitespaces)
                return PipelineTrigger.allNames.filter { $0.lowercased().hasPrefix(typed.lowercased()) }.map {
                    PipelineCompletion(kind: .trigger, label: $0, insertText: $0 == "folder" ? "folder(\"" : $0, detail: triggerHelp[$0] ?? "", replaceStart: lineEndUTF16 - typed.utf16.count, replaceLength: typed.utf16.count)
                }
            case "optimiseFirst", "hideResult":
                let typed = value.trimmingCharacters(in: .whitespaces)
                return ["true", "false"].filter { $0.hasPrefix(typed) }.map {
                    PipelineCompletion(kind: .value, label: $0, insertText: $0, detail: "", replaceStart: lineEndUTF16 - typed.utf16.count, replaceLength: typed.utf16.count)
                }
            default:
                return []
            }
        }
        let typed = line.trimmingCharacters(in: .whitespaces)
        return frontMatterKeys.filter { $0.lowercased().hasPrefix(typed.lowercased()) }.map {
            PipelineCompletion(kind: .frontMatterKey, label: $0, insertText: "\($0): ", detail: frontMatterHelp[$0] ?? "", replaceStart: lineEndUTF16 - typed.utf16.count, replaceLength: typed.utf16.count)
        }
    }

    public static let frontMatterHelp: [String: String] = [
        "description": "one line saying what the pipeline is for",
        "hotkey": "global shortcut, e.g. ctrl+alt+cmd+w",
        "icon": "SF Symbol shown in preset zones and menus",
        "triggers": "what runs it automatically: clipboard, dropZone, presetZone, folder(\"~/path\"), rightClick, cli, mcp",
        "optimiseFirst": "optimise each file before the steps run (true or false)",
        "hideResult": "run without showing the floating result (true or false)",
    ]

    public static let triggerHelp: [String: String] = [
        "clipboard": "files and images you copy",
        "dropZone": "files dropped on the drop zone",
        "presetZone": "shown as a preset zone while dragging",
        "folder": "new files in a folder",
        "rightClick": "Finder's right-click menu",
        "cli": "a quick action of the command line",
        "mcp": "offered to AI agents",
    ]
}

// MARK: - Describe

extension PipelineLanguage {
    /// A plain-language explanation of the pipeline, for people reviewing what an agent wrote and
    /// for the settings window.
    public static func describe(_ pipeline: Pipeline) -> String {
        var paragraphs: [String] = []
        if let d = pipeline.description, !d.isEmpty { paragraphs.append(d.hasSuffix(".") ? d : d + ".") }

        let any = pipeline[nil]
        let kinded = pipeline.sections.filter { $0.kind != nil && !$0.steps.isEmpty }
        if pipeline.isEmpty {
            paragraphs.append("It has no steps, so it does nothing.")
        }
        if !any.isEmpty {
            let lead = kinded.isEmpty ? "For each file" : "For any other file"
            paragraphs.append(sentence(lead, steps: any, optimiseFirst: pipeline.optimiseFirst))
        }
        for section in kinded {
            let label = section.kind == .pdf ? "PDFs" : (section.kind == .audio ? "audio files" : "\(section.kind!.rawValue)s")
            paragraphs.append(sentence("For \(label)", steps: section.steps, optimiseFirst: pipeline.optimiseFirst))
        }

        if !pipeline.triggers.isEmpty {
            let parts = pipeline.triggers.map { t -> String in
                switch t {
                case .clipboard: "when you copy a file or image"
                case .dropZone: "when you drop files on the drop zone"
                case .presetZone: "as a preset zone while you drag files"
                case let .folder(path): "when new files appear in \(path)"
                case .rightClick: "from Finder's right-click menu"
                case .cli: "as a command line quick action"
                case .mcp: "when an AI agent asks for it"
                }
            }
            paragraphs.append("It runs " + list(parts) + ".")
        }
        if let hotkey = pipeline.hotkey, !hotkey.isEmpty { paragraphs.append("Shortcut: \(hotkey).") }
        if pipeline.hideResult { paragraphs.append("It runs quietly, without showing the result.") }
        return paragraphs.joined(separator: "\n\n")
    }

    /// Explains a list of steps on its own, e.g. for an inline pipeline.
    public static func describe(_ steps: [PipelineStep]) -> String {
        steps.isEmpty ? "No steps." : sentence("For each file", steps: steps, optimiseFirst: false)
    }

    static func sentence(_ lead: String, steps: [PipelineStep], optimiseFirst: Bool) -> String {
        var clauses = steps.map(describe)
        if optimiseFirst, let first = steps.first(where: { !$0.isFilter }) {
            switch first {
            case .convert, .crop, .downscale: break
            default: clauses.insert("optimise it first", at: 0)
            }
        }
        return "\(lead): " + clauses.joined(separator: "; then ") + "."
    }

    /// One step as a clause, e.g. "convert it to WebP, saved next to the original".
    public static func describe(_ step: PipelineStep) -> String {
        switch step {
        case let .optimise(encoder, adaptive, dpi, location, compression):
            var s = "optimise it"
            var how: [String] = []
            if encoder != .medium { how.append("the \(words(encoder.rawValue)) encoder") }
            switch compression {
            case let .factor(n)?: how.append("compression \(n) of 100")
            case .adaptive?: how.append("adaptive compression")
            case .auto?, nil: break
            }
            if !how.isEmpty { s += " with " + list(how) }
            if adaptive { s += ", letting the format change if that is smaller" }
            if let dpi { s += ", downsampling images to \(dpi) dpi" }
            return s + where_(location)
        case let .downscale(factor, location):
            return "scale it down to \(percent(factor)) of its size" + where_(location)
        case let .lowerBitrate(kbps, location):
            return "lower its bitrate to \(kbps) kbps" + where_(location)
        case let .convert(to, location):
            return "convert it to \(formatName(to))" + where_(location, convert: true)
        case let .crop(width, height, longEdge, aspectRatio, smartCrop, location):
            var s: String
            if let aspectRatio {
                s = "crop it to a \(aspectRatio) shape"
            } else if let longEdge {
                s = "resize it so the longest side is \(longEdge) px"
            } else if let width, let height {
                s = "resize it to \(width)×\(height) px"
            } else if let width {
                s = "resize it to \(width) px wide"
            } else {
                s = "resize it to \(height ?? 0) px tall"
            }
            if smartCrop { s += ", keeping the most interesting part" }
            return s + where_(location)
        case let .extractPagesAsImages(format, quality, location):
            return "save every page as a \(format == .png ? "PNG" : "JPEG") image at \(Int(quality.scale * 72)) dpi" + where_(location, convert: true)
        case let .targetSize(bytes, location):
            return "shrink it until it is under \(ByteSize.format(bytes))" + where_(location)
        case .stripExif:
            return "remove its EXIF and GPS metadata"
        case let .watermark(image, position, opacity, scale, location):
            var s = "place the watermark \(template(image)) at the \(words(position.rawValue)), \(percent(scale)) of the width"
            if opacity < 1 { s += ", \(percent(opacity)) opaque" }
            return s + where_(location)
        case let .copy(to):
            return "copy it to \(template(to)) and continue with the copy"
        case let .move(to):
            return "move it to \(template(to))"
        case let .rename(to):
            return "rename it to \(template(to))"
        case let .delete(path):
            switch path {
            case "sourceFile": return "move the original file to the Trash"
            case "currentFile": return "move the current file to the Trash"
            default: return "move \(template(path)) to the Trash"
            }
        case let .filterIf(c):
            return "continue only if " + describe(c) + " (other files stop here)"
        case let .filterIfNot(c):
            return "stop here if " + describe(c)
        case .removeAudio:
            return "remove its audio"
        case let .changeSpeed(factor, frames):
            var s = "play it at \(PipelineSerializer.number(factor, keepPoint: false))× speed"
            if frames == .keep { s += ", keeping every frame" }
            if frames == .drop { s += ", dropping frames to keep the frame rate" }
            return s
        case let .capFps(fps):
            return "cap it at \(fps) frames per second"
        case let .normalize(lufs):
            return "even out its loudness to \(PipelineSerializer.number(lufs, keepPoint: false)) LUFS"
        case let .runScript(path, code):
            if let code { return "run the shell command `\(code)` on it" }
            return "run the script \(template(path ?? "")) on it"
        case let .runShortcut(name):
            return "run the Shortcut “\(name)” on it"
        case let .copyToClipboard(format, relativeTo):
            var s = switch format {
            case .path: "copy its path"
            case .imageData: "copy the image"
            case .markdown: "copy a Markdown link to it"
            }
            if let relativeTo { s += " relative to \(template(relativeTo))" }
            return s
        case let .copyLinkForSending(expiration):
            guard let expiration else { return "share it through a link and copy the link" }
            return "share it through a link that " + (expiration <= 0 ? "never expires" : "expires after \(Durations.format(expiration))") + ", and copy the link"
        case let .fork(location):
            guard let location else { return "show the result so far as a second result" }
            return "save a copy of the result so far" + where_(location).replacingOccurrences(of: ", saving the result", with: "")
        case let .shelveWith(app):
            return "put it on the \(app.capitalized) shelf"
        case let .uploadWith(app):
            return "upload it with \(app.capitalized)"
        case let .upload(target):
            return "upload it to \(target.map { "“\($0)”" } ?? "the default upload target") and copy the link"
        case let .openWith(app):
            return "open it in \(app)"
        }
    }

    static func describe(_ c: FilterCondition) -> String {
        var parts: [String] = []
        if let t = c.types { parts.append("it is " + list(t, or: true)) }
        if let r = c.regex { parts.append("its name matches `\(r)`") }
        if let n = c.nameContains { parts.append("its name contains “\(n)”") }
        if let n = c.nameIs { parts.append("its name is “\(n)”") }
        if let b = c.fileSizeGreaterThan { parts.append("it is larger than \(ByteSize.format(b))") }
        if let b = c.fileSizeLowerThan { parts.append("it is smaller than \(ByteSize.format(b))") }
        if let b = c.minFileSize { parts.append("it is at least \(ByteSize.format(b))") }
        if let w = c.widthGreaterThan { parts.append("it is wider than \(w) px") }
        if let w = c.widthLowerThan { parts.append("it is narrower than \(w) px") }
        if let h = c.heightGreaterThan { parts.append("it is taller than \(h) px") }
        if let h = c.heightLowerThan { parts.append("it is shorter than \(h) px") }
        if let r = c.minResolution { parts.append("both sides are at least \(r) px") }
        if let d = c.dpiGreaterThan { parts.append("it is above \(d) dpi") }
        if let d = c.dpiLowerThan { parts.append("it is below \(d) dpi") }
        if let d = c.durationGreaterThan { parts.append("it lasts more than \(PipelineSerializer.number(d, keepPoint: false)) s") }
        if let d = c.durationLowerThan { parts.append("it lasts less than \(PipelineSerializer.number(d, keepPoint: false)) s") }
        if let a = c.copiedBy { parts.append("it was copied from \(a)") }
        return list(parts)
    }

    static func where_(_ location: OutputLocation, convert: Bool = false) -> String {
        switch location {
        case .inPlace: convert ? ", replacing the original (a backup is kept)" : ""
        case .sameFolder: ", saving the result next to the original"
        case .temporary: ", saving the result in a temporary folder"
        case let .path(t): ", saving the result to \(template(t))"
        }
    }

    /// A template with its tokens spelled out: `~/Pictures/<year>/<month>/`.
    public static func template(_ t: String) -> String {
        let names: [String: String] = [
            "%f": "<name>", "%e": "<extension>", "%P": "<folder>", "%F": "<path>", "%y": "<year>", "%m": "<month>",
            "%n": "<month name>", "%d": "<day>", "%w": "<weekday>", "%H": "<hour>", "%M": "<minute>", "%S": "<second>",
            "%p": "<AM/PM>", "%r": "<random>", "%i": "<number>",
        ]
        var s = t
        for (token, name) in names { s = s.replacingOccurrences(of: token, with: name) }
        return s
    }

    static func formatName(_ f: String) -> String {
        switch f {
        case "webp": "WebP"
        case "x265": "H.265 (software encoder)"
        case "hevc": "H.265"
        case "mp4": "MP4"
        case "jpg", "jpeg": "JPEG"
        case "jxl": "JPEG XL"
        default: f.uppercased()
        }
    }

    static func percent(_ f: Double) -> String { "\(PipelineSerializer.number(f * 100, keepPoint: false))%" }

    /// `slowHighQuality` -> "slow high quality".
    static func words(_ camel: String) -> String {
        var out = ""
        for c in camel {
            if c.isUppercase { out += " " + c.lowercased() } else { out.append(c) }
        }
        return out
    }

    static func list(_ items: [String], or: Bool = false) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + (or ? " or " : " and ") + items.last!
        }
    }
}

// MARK: - Reference

extension PipelineLanguage {
    /// A compact reference of every step, argument and template token, generated from the
    /// catalog so it never drifts. The MCP server can hand it to agents as a prompt.
    public static func referenceMarkdown() -> String {
        var out = """
        # esclop pipeline language

        Steps run left to right, joined by `->` or one per line: `crop(longEdge: 1600) -> convert(to: webp)`.
        Arguments are `name: value`; quote paths, templates and regexes (`"~/Pictures/%y/"`). A step with
        no arguments can be written bare (`stripExif`). A step that does not apply to the file's kind is skipped.
        Filters (`if`, `ifNot`) stop the file quietly when they fail; there is no `else`.
        A `.pipeline` file may start with front matter (`---` lines with \(frontMatterKeys.map { "`\($0)`" }.joined(separator: ", "))) and
        split steps into `[image]`, `[video]`, `[pdf]`, `[audio]` sections; steps before any section apply to every kind
        without its own section.

        ## Steps

        """
        for category in StepCategory.allCases {
            out += "\n### \(categoryTitle(category))\n\n"
            for s in steps where s.category == category {
                out += "- `\(s.signature)` [\(s.kindList)]: \(s.summary) Example: `\(s.example)`\n"
                for p in s.params {
                    out += "  - `\(p.name)`\(p.required ? " (required)" : "")\(p.defaultValue.map { ", default `\($0)`" } ?? ""): \(p.doc)\n"
                }
                for n in s.notes { out += "  - \(n)\n" }
            }
        }
        out += "\n## Template tokens\n\n"
        for t in templateTokens { out += "- `\(t.token)`: \(t.meaning)\n" }
        return out
    }

    static func categoryTitle(_ c: StepCategory) -> String {
        switch c {
        case .processing: "Processing"
        case .fileOperation: "File operations"
        case .filter: "Filters"
        case .mediaSpecific: "Video and audio"
        case .action: "Actions"
        }
    }
}
