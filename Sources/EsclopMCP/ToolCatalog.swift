// SPDX-License-Identifier: GPL-3.0-or-later
//
// The tools `esclop mcp serve` offers. Descriptions are written for the agent that reads them
// before choosing a tool: what it does, when to use it, what comes back and how it fails.
// Tool names mirror the CLI subcommands.

import EsclopCore
import EsclopIPC
import EsclopPipelines
import Foundation
import MCP

public struct ToolCall: Sendable {
    public let name: String
    public let arguments: ToolArguments
    public let service: EsclopService
    public let elicitor: Elicitor
    public let client: ClientState.Snapshot
}

public struct ToolSpec: Sendable {
    public let tool: MCP.Tool
    public let run: @Sendable (ToolCall) async throws -> ToolOutput
}

public enum ToolCatalog {
    public static let all: [ToolSpec] = fileTools + pipelineTools + settingsTools + appTools
    public static let byName: [String: ToolSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.tool.name, $0) })

    // MARK: Shared copy

    static let placement = "Where results go: by default the original is replaced in place with a backup kept only if the person allowed agents to overwrite originals; otherwise a new file is written next to it. Pass location or output to choose. The result lists every output path."
    static let returns = "Returns one line per file (bytes before → after, saving %, output path) and JSON with results[] (source, output, backup, bytesBefore, bytesAfter, savedPercent, width, height) and failures[] (source, error, code). Files that fail do not stop the others; isError is set only when every file failed."
    static let runsVia = "Runs through the L'Esclop app when it is open (the result card shows on screen) and in this process otherwise."

    static let fileProperties: [String: Value] = [
        "paths": Schema.strings("Files or folders: absolute paths, ~/..., or file:// URLs. Relative paths resolve against the server's working directory. A single string is accepted."),
        "recursive": Schema.bool("Also take files from subfolders of the folders given."),
        "types": Schema.strings("Only take these extensions from folders, e.g. [\"png\", \"jpg\"]. Files named directly are always taken."),
        "location": Schema.string("inPlace replaces the original and keeps a backup (needs the person's permission); sameFolder writes a new file next to it; temporary writes to L'Esclop's temporary folder.", enum: ["inPlace", "sameFolder", "temporary"]),
        "output": Schema.string("Instead of location: a folder ending in /, or a file path. Templates: %f file name without extension, %e extension, %d source folder."),
        "showResult": Schema.bool("When the L'Esclop app is open, show the result card on screen. Default true."),
    ]

    static let qualityProperties: [String: Value] = [
        "aggressive": Schema.bool("Trade visible quality for a smaller file."),
        "compression": Schema.integer("0 to 100, higher is smaller and lossier; overrides aggressive. Normal is 30, aggressive 64.", minimum: 0, maximum: 100),
        "stripMetadata": Schema.bool("true removes EXIF, GPS and other metadata, false keeps it; omitted follows the stripMetadata setting."),
    ]

    static func fileSchema(_ extra: [String: Value], required: [String] = ["paths"], quality: Bool = true) -> Value {
        var properties = fileProperties
        if quality { properties.merge(qualityProperties) { $1 } }
        properties.merge(extra) { $1 }
        return Schema.object(properties, required: required)
    }

    static let fileAnnotations = MCP.Tool.Annotations(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
    static let readAnnotations = MCP.Tool.Annotations(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    static let writeAnnotations = MCP.Tool.Annotations(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)

    // MARK: File tools

    static let fileTools: [ToolSpec] = [
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_optimise",
                title: "Optimise files",
                description: """
                Make images, videos, PDFs and audio files smaller while keeping them visually the same (PNG, JPEG, \
                GIF, WebP, AVIF, HEIC, MP4, MOV, PDF, MP3, ...). Use it for "make this smaller", "compress", or before \
                sending or committing media. Optional downscale, speed change, audio removal and metadata stripping \
                happen in the same pass. \(placement) \(runsVia) \(returns) Fails per file with fileNotFound, \
                unsupportedFile, unreadable (a damaged or mislabelled file), alreadySmaller (nothing to gain) or \
                toolMissing; refuses the call with notPermitted \
                when it would overwrite originals without permission.
                """,
                inputSchema: fileSchema([
                    "downscale": Schema.number("Also scale down: 0.5 is half the width and height.", minimum: 0.05, maximum: 1),
                    "removeAudio": Schema.bool("Videos: drop the audio track."),
                    "playbackSpeed": Schema.number("Videos: speed factor, 2 is twice as fast.", minimum: 0.1, maximum: 16),
                    "pdfDPI": Schema.integer("PDFs: resolution for images inside, e.g. 150. Lower is smaller.", minimum: 36, maximum: 600),
                ]),
                annotations: fileAnnotations
            ),
            run: { call in
                var request = try makeRequest(call)
                request.downscale = try call.arguments.double("downscale")
                if let factor = request.downscale, !(0.05 ... 1).contains(factor) {
                    throw ToolFailure("downscale is between 0.05 and 1; 0.5 is half the width and height", code: "invalidArgument")
                }
                request.removeAudio = call.arguments.bool("removeAudio") ?? false
                request.playbackSpeed = try call.arguments.double("playbackSpeed")
                request.pdfDPI = try call.arguments.int("pdfDPI")
                return try await runJob(call, .optimise, request)
            }
        ),
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_convert",
                title: "Convert format",
                description: """
                Convert files to another format: images to webp, avif, jpeg, png, heic, jxl, gif, tiff; videos to mp4, \
                mov, webm, mkv, hevc, av1 or gif-video (an animated GIF from a video); audio to mp3, aac, m4a, opus, \
                flac, wav. Use it when a format is named ("as WebP", "turn this into an MP4"). The converted file gets \
                the new extension; the original stays unless location is inPlace. When format is missing, L'Esclop asks \
                the person through the client; if the client cannot ask, the call fails with the options to ask about \
                in chat. \(runsVia) \(returns)
                """,
                inputSchema: fileSchema([
                    "format": Schema.string("Target format.", enum: OutputFormat.allCases.map(\.rawValue)),
                ]),
                annotations: fileAnnotations
            ),
            run: { call in
                let files = try call.arguments.files()
                let format: OutputFormat
                if let raw = call.arguments.string("format") {
                    format = try parseFormat(raw)
                } else {
                    let kind = files.lazy.compactMap(MediaKind.of).first ?? .image
                    let options = OutputFormat.allCases.filter { $0.kind == kind && $0 != .pdf }.map(\.rawValue)
                    let answer = try await call.elicitor.ask(
                        "Which format should \(describe(files)) become?",
                        schema: Elicitation.RequestSchema(
                            title: "Convert to", properties: ["format": ["type": "string", "title": "Format", "enum": .array(options.map(Value.string))]],
                            required: ["format"]
                        ),
                        missing: "format", options: options.joined(separator: ", ")
                    )
                    guard let raw = answer["format"]?.stringValue else { throw ToolFailure("No format was chosen. Nothing was changed.", code: "declined") }
                    format = try parseFormat(raw)
                }
                var request = try makeRequest(call, files: files)
                request.format = format
                return try await runJob(call, .convert(format), request)
            }
        ),
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_downscale",
                title: "Downscale",
                description: """
                Scale images and videos down by a factor and optimise them (for audio the factor lowers the bitrate). \
                Use it for "make it smaller in pixels", "half the size", "too big for the screen". factor 0.5 halves \
                width and height. When factor is missing, L'Esclop asks the person; if the client cannot ask, the call \
                fails with the choices. \(placement) \(runsVia) \(returns)
                """,
                inputSchema: fileSchema([
                    "factor": Schema.number("0.05 to 1: 0.75 is three quarters, 0.5 half, 0.25 a quarter of the width and height.", minimum: 0.05, maximum: 1),
                ]),
                annotations: fileAnnotations
            ),
            run: { call in
                let files = try call.arguments.files()
                var factor = try call.arguments.double("factor")
                if factor == nil {
                    let answer = try await call.elicitor.ask(
                        "How much should \(describe(files)) be scaled down? 0.5 is half the width and height.",
                        schema: Elicitation.RequestSchema(
                            title: "Downscale",
                            properties: ["factor": ["type": "number", "title": "Factor", "minimum": 0.05, "maximum": 1, "default": 0.5]],
                            required: ["factor"]
                        ),
                        missing: "factor", options: "0.75, 0.5, 0.25, or any number from 0.05 to 1"
                    )
                    factor = answer["factor"].flatMap { JSONValue($0).doubleValue ?? Double(JSONValue($0).plain) }
                }
                guard let factor, (0.05 ... 1).contains(factor) else {
                    throw ToolFailure("factor is between 0.05 and 1; 0.5 is half the width and height", code: "invalidArgument")
                }
                var request = try makeRequest(call, files: files)
                request.downscale = factor
                return try await runJob(call, .downscale(factor), request)
            }
        ),
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_crop",
                title: "Crop to size",
                description: """
                Crop (and scale) images and videos to an exact size or aspect ratio, then optimise. Give width and \
                height for an exact size (1200x630 for a link preview), one of them to keep the ratio, longEdge to cap \
                the longer side, or aspectRatio (16:9, 1:1, 4:5) to cut to a shape at the current scale. smart keeps \
                the most interesting region (faces, subjects) instead of the centre. When nothing says the size, \
                L'Esclop asks the person; if the client cannot ask, the call fails with what to ask. For PDFs use \
                esclop_crop_pdf. \(placement) \(runsVia) \(returns)
                """,
                inputSchema: fileSchema([
                    "width": Schema.integer("Target width in pixels.", minimum: 1),
                    "height": Schema.integer("Target height in pixels.", minimum: 1),
                    "longEdge": Schema.integer("Cap the longer side at this many pixels.", minimum: 1),
                    "aspectRatio": Schema.string("Shape to cut to, e.g. 16:9, 1:1, 4:5."),
                    "smart": Schema.bool("Centre the crop on the subject instead of the middle."),
                ]),
                annotations: fileAnnotations
            ),
            run: { call in
                let files = try call.arguments.files()
                var size = CropSize(
                    width: try call.arguments.int("width"), height: try call.arguments.int("height"),
                    longEdge: try call.arguments.int("longEdge"), aspectRatio: call.arguments.string("aspectRatio"),
                    smart: call.arguments.bool("smart") ?? false
                )
                if size.width == nil, size.height == nil, size.longEdge == nil, size.aspectRatio == nil {
                    let answer = try await call.elicitor.ask(
                        "What size should \(describe(files)) be cropped to? Give a width and height, or an aspect ratio.",
                        schema: Elicitation.RequestSchema(
                            title: "Crop",
                            properties: [
                                "width": ["type": "integer", "title": "Width (px)", "minimum": 1],
                                "height": ["type": "integer", "title": "Height (px)", "minimum": 1],
                                "aspectRatio": ["type": "string", "title": "Or an aspect ratio", "description": "16:9, 1:1, 4:5"],
                            ]
                        ),
                        missing: "width and height, longEdge or aspectRatio", options: "e.g. width 1200 and height 630, or aspectRatio 1:1"
                    )
                    let reply = ToolArguments(answer)
                    size.width = try reply.int("width")
                    size.height = try reply.int("height")
                    size.aspectRatio = reply.string("aspectRatio")
                    guard size.width != nil || size.height != nil || size.aspectRatio != nil else {
                        throw ToolFailure("No size was given. Nothing was changed.", code: "declined")
                    }
                }
                if let ratio = size.aspectRatio {
                    do { _ = try AspectRatio.parse(ratio) } catch { throw ToolFailure("\(error)", code: "invalidArgument") }
                }
                var request = try makeRequest(call, files: files)
                request.crop = size
                return try await runJob(call, .crop(size), request)
            }
        ),
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_fit_under_size",
                title: "Fit under a size",
                description: """
                Shrink files until each is under a byte limit, lowering quality and then resolution as needed. Use it \
                for upload limits: "under 2 MB for the form", "small enough for email". maxSize takes 2MB, 500KB, \
                1.5MiB or a number of bytes. When it is missing, L'Esclop asks the person; if the client cannot ask, \
                the call fails with the choices. A file that cannot get under the limit fails with its best size in \
                the error. \(placement) \(runsVia) \(returns)
                """,
                inputSchema: fileSchema([
                    "maxSize": Schema.string("The limit: 2MB, 500KB, 1.5MiB, or bytes as a number."),
                ]),
                annotations: fileAnnotations
            ),
            run: { call in
                let files = try call.arguments.files()
                var text = call.arguments.string("maxSize") ?? call.arguments.string("maxBytes")
                if text == nil {
                    let options = ["500KB", "1MB", "2MB", "5MB", "10MB", "25MB"]
                    let answer = try await call.elicitor.ask(
                        "What size must \(describe(files)) fit under?",
                        schema: Elicitation.RequestSchema(
                            title: "Fit under", properties: ["maxSize": ["type": "string", "title": "Size limit", "enum": .array(options.map(Value.string))]],
                            required: ["maxSize"]
                        ),
                        missing: "maxSize", options: options.joined(separator: ", ")
                    )
                    text = answer["maxSize"].map { JSONValue($0).plain }
                }
                guard let text else { throw ToolFailure("No size limit was chosen. Nothing was changed.", code: "declined") }
                let bytes: Int
                do { bytes = try ByteSize.parse(text) } catch { throw ToolFailure("\(error)", code: "invalidArgument") }
                var request = try makeRequest(call, files: files)
                request.targetBytes = bytes
                return try await runJob(call, .fit(underBytes: bytes), request)
            }
        ),
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_strip_metadata",
                title: "Strip metadata",
                description: """
                Remove EXIF, GPS location, camera and editing metadata from images and videos without re-encoding them. \
                Use it before sharing photos publicly or committing them. \(placement) \(runsVia) \(returns)
                """,
                inputSchema: fileSchema([:], quality: false),
                annotations: fileAnnotations
            ),
            run: { call in
                var request = try makeRequest(call)
                request.stripMetadata = true
                return try await runJob(call, .stripMetadata, request)
            }
        ),
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_upload",
                title: "Upload files",
                description: """
                Upload files to one of the person's upload targets (S3-compatible storage they set up in L'Esclop \
                Settings › Uploads) and return each file's public link; the last link also goes on the clipboard. \
                target names the upload target; left out, the default one. Only the L'Esclop app holds the keys, \
                so the upload runs there (the app is started if needed); this tool never sees them. Allowed only \
                when the person turned on "Agents may upload files" (setting allowUploads), and only for images, \
                videos, PDFs and audio files (followed through links); anything else is refused. A link may be \
                public: anyone who has it can open the file if the bucket is public. Nothing is optimised \
                or changed on disk. Returns one line per file with its link, and JSON with results[] (source, link) \
                and failures[] (source, error, code).
                """,
                inputSchema: Schema.object([
                    "paths": fileProperties["paths"]!,
                    "target": Schema.string("The upload target's name, as Settings › Uploads lists it. Left out: the default one."),
                ], required: ["paths"]),
                annotations: MCP.Tool.Annotations(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)
            ),
            run: { call in
                let request = try makeRequest(call)
                return try await runJob(call, .upload(target: call.arguments.string("target")), request)
            }
        ),
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_crop_pdf",
                title: "Crop PDF pages",
                description: """
                Crop every page of PDFs to an aspect ratio by setting the crop box, so they fill an e-reader or tablet \
                screen. Nothing is re-encoded and esclop_uncrop_pdf reverses it. aspectRatio takes 3:4 or 0.75, or a \
                paper size or device: \(AspectRatio.presetNames.joined(separator: ", ")). The ratio turns with each \
                page's orientation. extend pads with blank margins instead of cutting. When aspectRatio is missing, \
                L'Esclop asks the person. \(placement) \(runsVia) \(returns)
                """,
                inputSchema: fileSchema([
                    "aspectRatio": Schema.string("3:4, 0.75, or a name such as A4 or Kindle Paperwhite."),
                    "extend": Schema.bool("Pad with blank paper instead of cutting content."),
                ], quality: false),
                annotations: fileAnnotations
            ),
            run: { call in
                let files = try call.arguments.files()
                var ratioText = call.arguments.string("aspectRatio") ?? call.arguments.string("device") ?? call.arguments.string("paperSize")
                if ratioText == nil {
                    let answer = try await call.elicitor.ask(
                        "Which screen or paper should \(describe(files)) be cropped for?",
                        schema: Elicitation.RequestSchema(
                            title: "Crop PDF for",
                            properties: ["aspectRatio": ["type": "string", "title": "Screen or paper", "enum": .array(AspectRatio.presetNames.map(Value.string))]],
                            required: ["aspectRatio"]
                        ),
                        missing: "aspectRatio", options: "a ratio like 3:4 or one of \(AspectRatio.presetNames.joined(separator: ", "))"
                    )
                    ratioText = answer["aspectRatio"]?.stringValue
                }
                guard let ratioText else { throw ToolFailure("No ratio was chosen. Nothing was changed.", code: "declined") }
                let ratio: Double
                do { ratio = try AspectRatio.parse(ratioText) } catch { throw ToolFailure("\(error)", code: "invalidArgument") }
                let request = try makeRequest(call, files: files)
                return try await runJob(call, .cropPDF(PDFCropSpec(aspectRatio: ratio, extend: call.arguments.bool("extend") ?? false)), request)
            }
        ),
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_uncrop_pdf",
                title: "Uncrop PDF pages",
                description: """
                Undo esclop_crop_pdf (or any crop box) by resetting every page to its full size. Content outside the \
                crop was never removed, so it comes back exactly. \(placement) \(runsVia) \(returns)
                """,
                inputSchema: fileSchema([:], quality: false),
                annotations: fileAnnotations
            ),
            run: { call in try await runJob(call, .uncropPDF, try makeRequest(call)) }
        ),
    ]

    // MARK: Pipeline tools

    static let dslHint = "Steps are joined with -> or written one per line, for example: crop(longEdge: 1600) -> convert(to: webp) -> optimise. The write_pipeline prompt has the full step reference; mistakes come back with a line, a column and the fix."
    static let triggerHint = "Triggers: clipboard (everything copied), dropZone, presetZone (a target shown while dragging), rightClick (Finder menu), cli, mcp, or a folder path (every new file there)."

    static let pipelineTools: [ToolSpec] = [
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_pipeline_list",
                title: "List pipelines",
                description: "List saved pipelines (name, what they do in words, triggers, kinds, whether they run scripts, problems if a file does not parse) and the built-in presets. Read-only. Use it before running, attaching or replacing a pipeline.",
                inputSchema: Schema.object([:]),
                annotations: readAnnotations
            ),
            run: { call in
                let saved = try call.service.context.pipelines.entries().map(PipelineInfo.init(entry:))
                let presets = PresetInfo.all(in: call.service.context.pipelines)
                var lines = saved.isEmpty ? ["No saved pipelines. esclop_pipeline_write saves one."] : saved.map(\.line)
                lines.append("Built-in presets (run by name, or install with esclop_pipeline_preset): " + presets.map(\.name).joined(separator: ", "))
                return ToolOutput(lines.joined(separator: "\n"), structured: ["pipelines": try JSONValue.encode(saved), "presets": try JSONValue.encode(presets)])
            }
        ),
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_pipeline_show",
                title: "Show a pipeline",
                description: "Show one pipeline: its text (front matter, sections, steps), what it does in words, triggers and file path. Takes a saved name or a built-in preset name. Read-only. Fails with invalidArgument when the name is unknown.",
                inputSchema: Schema.object(["name": Schema.string("A saved pipeline or built-in preset.")], required: ["name"]),
                annotations: readAnnotations
            ),
            run: { call in
                let name = try call.arguments.requiredString("name")
                let store = call.service.context.pipelines
                let info: PipelineInfo
                if let entry = try store.entries().first(where: { $0.name.lowercased() == name.lowercased() }) {
                    info = PipelineInfo(entry: entry)
                } else if let preset = PipelineStore.preset(named: name) {
                    info = PipelineInfo(preset)
                } else {
                    let names = try store.entries().map(\.name) + PipelineStore.presets.map(\.name)
                    throw ToolFailure("No pipeline named \(name). Known: \(names.joined(separator: ", "))", code: "invalidArgument")
                }
                return ToolOutput("\(info.summary)\n\n\(info.text)", encoding: info)
            }
        ),
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_pipeline_write",
                title: "Save a pipeline",
                description: """
                Save a pipeline so it can be run by name, attached to a trigger or used as a preset zone. steps is \
                the pipeline text in one string: steps alone, or a full .pipeline file with front matter and \
                [image]/[video]/[pdf]/[audio] sections. \(dslHint) An existing name is refused unless replace is \
                true; replacing needs the person's permission to change settings (the old file goes to the Trash). \
                runScript and runShortcut steps need the person's permission for scripts; front-matter triggers \
                other than cli and mcp need permission to change settings. Returns the saved pipeline.
                """,
                inputSchema: Schema.object([
                    "name": Schema.string("The pipeline's name; it becomes the file name. No / or :."),
                    "steps": Schema.string("The pipeline text."),
                    "replace": Schema.bool("Replace a pipeline with the same name."),
                ], required: ["name", "steps"]),
                annotations: writeAnnotations
            ),
            run: { call in
                let name = try call.arguments.requiredString("name")
                let pipeline = try call.service.writePipeline(
                    name: name, source: try call.arguments.requiredString("steps"), replace: call.arguments.bool("replace") ?? false
                )
                let info = PipelineInfo(pipeline, path: call.service.context.pipelines.fileURL(for: pipeline.name))
                return ToolOutput("Saved pipeline \(name): \(info.summary)", encoding: info)
            }
        ),
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_pipeline_delete",
                title: "Delete a pipeline",
                description: "Delete a saved pipeline by name. The file goes to the Trash, so the person can bring it back. Deleting a pipeline with triggers (one that runs on its own) needs the person's permission to change settings.",
                inputSchema: Schema.object(["name": Schema.string("The pipeline's name.")], required: ["name"]),
                annotations: MCP.Tool.Annotations(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
            ),
            run: { call in
                let name = try call.arguments.requiredString("name")
                try call.service.deletePipeline(name)
                return ToolOutput("Deleted pipeline \(name)\(call.service.context.pipelines.useTrash ? " (moved to the Trash)" : "")", structured: ["deleted": .string(name)])
            }
        ),
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_pipeline_run",
                title: "Run a pipeline",
                description: """
                Run a pipeline on files: a saved name, a built-in preset name, or inline steps for a one-off. \
                \(dslHint) Pipeline steps choose where they write (optimise works in place, convert writes next to \
                the file); when the person has not allowed agents to overwrite originals, the pipeline runs on copies \
                placed where location says (next to the originals by default). Pipelines with script steps need the \
                person's permission. \(runsVia) \(returns) Each result's steps list the run log.
                """,
                inputSchema: fileSchema(["pipeline": Schema.string("A saved name, a built-in preset or inline steps.")], required: ["pipeline", "paths"], quality: false),
                annotations: fileAnnotations
            ),
            run: { call in
                let pipeline = try call.arguments.requiredString("pipeline")
                var request = try makeRequest(call)
                request.pipeline = pipeline
                return try await runJob(call, .pipeline(pipeline), request)
            }
        ),
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_pipeline_attach",
                title: "Attach a trigger",
                description: """
                Make a saved pipeline (or a built-in preset, which is installed first) run on its own by adding a \
                trigger. \(triggerHint) A folder trigger processes every matching file that lands there from then \
                on, and clipboard everything copied: tell the person before attaching. Which kinds of file it \
                touches follows the pipeline's sections. Needs the person's permission to change settings. \
                Returns the pipeline with its triggers.
                """,
                inputSchema: Schema.object([
                    "pipeline": Schema.string("A saved pipeline or built-in preset name."),
                    "trigger": Schema.string("clipboard, dropZone, presetZone, rightClick, cli, mcp, or a folder path."),
                ], required: ["pipeline", "trigger"]),
                annotations: writeAnnotations
            ),
            run: { call in
                let trigger = try PipelineTriggers.parse(try call.arguments.string("trigger") ?? call.arguments.requiredString("source"))
                let pipeline = try call.service.attach(trigger, to: try call.arguments.requiredString("pipeline"))
                let info = PipelineInfo(pipeline, path: call.service.context.pipelines.fileURL(for: pipeline.name))
                return ToolOutput("\(pipeline.name) now runs on \(trigger.description). Triggers: \(info.triggers.joined(separator: ", "))", encoding: info)
            }
        ),
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_pipeline_detach",
                title: "Detach a trigger",
                description: "Remove a trigger from one pipeline, or from every pipeline that has it when pipeline is left out (for example stop everything that runs on the clipboard). \(triggerHint) Needs the person's permission to change settings. Returns the pipelines that changed.",
                inputSchema: Schema.object([
                    "trigger": Schema.string("clipboard, dropZone, presetZone, rightClick, cli, mcp, or a folder path."),
                    "pipeline": Schema.string("Only this pipeline."),
                ], required: ["trigger"]),
                annotations: MCP.Tool.Annotations(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)
            ),
            run: { call in
                let trigger = try PipelineTriggers.parse(try call.arguments.string("trigger") ?? call.arguments.requiredString("source"))
                let changed = try call.service.detach(trigger, from: call.arguments.string("pipeline"))
                let text = changed.isEmpty ? "No pipeline had \(trigger.description)" : "Removed \(trigger.description) from \(changed.joined(separator: ", "))"
                return ToolOutput(text, structured: ["trigger": .string(trigger.description), "pipelines": .array(changed.map(JSONValue.string))])
            }
        ),
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_pipeline_preset",
                title: "Presets and preset zones",
                description: """
                Built-in presets and drop-zone preset zones. action list shows the built-in presets; install copies \
                one into the pipelines folder to edit or attach; add shows a saved pipeline (or a preset, installed \
                first) as a preset zone, a target the person drops files on while dragging; remove takes it off. \
                install with replace, add and remove need the person's permission to change settings.
                """,
                inputSchema: Schema.object([
                    "action": Schema.string("list (default), install, add or remove.", enum: ["list", "install", "add", "remove"]),
                    "name": Schema.string("The preset or pipeline name."),
                    "replace": Schema.bool("install: overwrite a saved pipeline with the same name."),
                ]),
                annotations: writeAnnotations
            ),
            run: { call in
                let service = call.service
                switch (call.arguments.string("action") ?? "list").lowercased() {
                case "list":
                    let presets = PresetInfo.all(in: service.context.pipelines)
                    return ToolOutput(presets.map { "\($0.name): \($0.summary)" }.joined(separator: "\n"), structured: ["presets": try JSONValue.encode(presets)])
                case "install":
                    let pipeline = try service.installPreset(try call.arguments.requiredString("name"), replace: call.arguments.bool("replace") ?? false)
                    return ToolOutput("Installed \(pipeline.name)", encoding: PipelineInfo(pipeline, path: service.context.pipelines.fileURL(for: pipeline.name)))
                case "add":
                    let pipeline = try service.attach(.presetZone, to: try call.arguments.requiredString("name"))
                    return ToolOutput("\(pipeline.name) is now a preset zone", encoding: PipelineInfo(pipeline, path: service.context.pipelines.fileURL(for: pipeline.name)))
                case "remove":
                    let name = try call.arguments.requiredString("name")
                    let changed = try service.detach(.presetZone, from: name)
                    return ToolOutput(changed.isEmpty ? "\(name) was not a preset zone" : "\(name) is no longer a preset zone", structured: ["pipelines": .array(changed.map(JSONValue.string))])
                default:
                    throw ToolFailure("action is list, install, add or remove", code: "invalidArgument")
                }
            }
        ),
    ]

    // MARK: Settings tools

    static let settingsTools: [ToolSpec] = [
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_settings_schema",
                title: "Settings schema",
                description: "Every esclop setting: key, current value, type, allowed values, default, title and description, plus whether agents may change it. Pass query (plain words such as \"overwrite original\" or \"agent permission\") to narrow it. Read-only. Call it before esclop_settings_set: set takes the string form of a value from here.",
                inputSchema: Schema.object(["query": Schema.string("Words to filter by, e.g. \"backup\" or \"pdf quality\".")]),
                annotations: readAnnotations
            ),
            run: { call in
                let list = try await call.service.settingsSchema(query: call.arguments.string("query"))
                let text = list.isEmpty ? "No setting matches." : list.map { "\($0.key) = \($0.value?.plain ?? $0.defaultValue.plain): \($0.title)" }.joined(separator: "\n")
                return ToolOutput(text, structured: ["settings": .array(list.map(settingJSON))])
            }
        ),
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_settings_get",
                title: "Read a setting",
                description: "Read one setting by key (keys come from esclop_settings_schema). Returns its value, type, default and description. Fails with invalidArgument and close matches when the key is unknown.",
                inputSchema: Schema.object(["key": Schema.string("The setting's key.")], required: ["key"]),
                annotations: readAnnotations
            ),
            run: { call in
                let descriptor = try await call.service.setting(try call.arguments.requiredString("key"))
                return ToolOutput("\(descriptor.key) = \(descriptor.value?.plain ?? descriptor.defaultValue.plain)", structured: settingJSON(descriptor))
            }
        ),
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_settings_set",
                title: "Change a setting",
                description: "Change one setting. value is the string form: true or false, a number, or one of the allowed values from esclop_settings_schema. Takes effect immediately and returns the stored value. Needs the person's permission to change settings; the agent permissions themselves (allow...) can only be changed by the person and are always refused.",
                inputSchema: Schema.object([
                    "key": Schema.string("The setting's key."),
                    "value": Schema.string("The new value as text."),
                ], required: ["key", "value"]),
                annotations: writeAnnotations
            ),
            run: { call in
                let key = try call.arguments.requiredString("key")
                let value = try await call.service.setSetting(key, to: try call.arguments.requiredString("value"))
                return ToolOutput("\(key) = \(value.plain)", structured: ["key": .string(key), "value": value])
            }
        ),
    ]

    // MARK: App, results, logs

    static let appTools: [ToolSpec] = [
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_status",
                title: "Status",
                description: "L'Esclop's version, whether the app is running and used for jobs, which engine runs in-process, what the person allows agents to do (overwrite originals, delete backups, run scripts, change settings), where files and pipelines live, and whether this client can answer L'Esclop's questions. Read it first when a tool is refused or fails unexpectedly.",
                inputSchema: Schema.object([:]),
                annotations: readAnnotations
            ),
            run: { call in
                let status = await call.service.status()
                var json = try JSONValue.encode(status).objectValue ?? [:]
                json["mcpClient"] = ["name": .string(call.client.name), "version": .string(call.client.version), "elicitation": .bool(call.client.elicitation)]
                let allowed = status.permissions.filter(\.value).keys.sorted()
                let text = """
                L'Esclop \(status.version); app \(status.app.running ? "running" : "not running"), jobs run \(status.route) (engine: \(status.app.used ? "app" : status.engine)).
                Agents may: \(allowed.isEmpty ? "nothing beyond writing new files and pipelines" : allowed.joined(separator: ", ")).
                Pipelines: \(status.pipelines) in \(status.paths["pipelines"] ?? "?").
                """
                return ToolOutput(text, structured: .object(json))
            }
        ),
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_start_app",
                title: "Start the app",
                description: "Open the L'Esclop menu bar app in the background, so jobs show result cards on screen and use the app's settings. Waits until it is ready and returns the status. Fails when esclop.app is not installed; the other tools keep working in-process without it.",
                inputSchema: Schema.object([:]),
                annotations: MCP.Tool.Annotations(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            run: { call in
                let status = try await call.service.startApp()
                return ToolOutput("The L'Esclop app is running\(status.app.pid.map { " (pid \($0))" } ?? "")", encoding: status)
            }
        ),
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_stop_app",
                title: "Quit the app",
                description: "Quit the L'Esclop menu bar app. Jobs it is running are cancelled. Only do this when the person asks; the clipboard and folder automations stop with it. Fails with appNotRunning when it is not open.",
                inputSchema: Schema.object([:]),
                annotations: MCP.Tool.Annotations(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)
            ),
            run: { call in
                try await call.service.stopApp()
                return ToolOutput("The L'Esclop app has quit", structured: ["running": false])
            }
        ),
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_recent_results",
                title: "Recent results",
                description: "The most recent optimisation results, newest first: source, output, backup, sizes and saving. Use it to find what was just done, an output path, or a file to restore with esclop_restore_backup. Read-only.",
                inputSchema: Schema.object(["limit": Schema.integer("How many, default 20, at most 200.", minimum: 1, maximum: 200)]),
                annotations: readAnnotations
            ),
            run: { call in
                let limit = min(200, max(1, try call.arguments.int("limit") ?? 20))
                let results = await call.service.recentResults(limit: limit).map(ResultSummary.init)
                let text = results.isEmpty ? "No results yet." : results.map(\.line).joined(separator: "\n")
                return ToolOutput(text, structured: ["results": try JSONValue.encode(results)])
            }
        ),
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_restore_backup",
                title: "Restore a backup",
                description: "Put the original back from L'Esclop's backup for a file that was optimised in place. path is the file's current path (the source or the output of a recent result). Overwrites the current file, so it needs the person's permission to overwrite originals; deleteBackup also needs permission to delete backups. Fails with fileNotFound when no backup was kept (the file was not changed in place).",
                inputSchema: Schema.object([
                    "path": Schema.string("The optimised file, absolute or ~/..."),
                    "deleteBackup": Schema.bool("Delete the backup after restoring."),
                ], required: ["path"]),
                annotations: MCP.Tool.Annotations(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
            ),
            run: { call in
                let outcome = try await call.service.restoreBackup(
                    for: try PathInput.url(try call.arguments.requiredString("path")),
                    deleteBackup: call.arguments.bool("deleteBackup") ?? false
                )
                var text = "Restored \(PathInput.abbreviate(outcome.restored)) from its backup"
                if let left = outcome.leftInPlace { text += "; the converted copy \(PathInput.abbreviate(left)) is still there" }
                return ToolOutput(text, encoding: outcome)
            }
        ),
        ToolSpec(
            tool: MCP.Tool(
                name: "esclop_logs",
                title: "Logs",
                description: "L'Esclop's recent log messages (from the app, the CLI and engines) and the tail of its log files. Use it to explain a failure. window is how far back: 30s, 10m, 1h, 2d (default 10m). Read-only; can take a few seconds.",
                inputSchema: Schema.object([
                    "window": Schema.string("How far back: 30s, 10m, 1h, 2d."),
                    "limit": Schema.integer("At most this many lines per source, default 200.", minimum: 1, maximum: 5000),
                ]),
                annotations: readAnnotations
            ),
            run: { call in
                let excerpt = try call.service.logs(window: call.arguments.string("window") ?? "10m", limit: try call.arguments.int("limit") ?? 200)
                var lines = excerpt.system
                for (file, tail) in excerpt.files.sorted(by: { $0.key < $1.key }) { lines.append("== \(file)"); lines += tail }
                if let note = excerpt.note { lines.append(note) }
                return ToolOutput(lines.joined(separator: "\n"), encoding: excerpt)
            }
        ),
    ]

    // MARK: Helpers

    static func makeRequest(_ call: ToolCall, files: [URL]? = nil) throws -> OptimisationRequest {
        let sources = try files ?? call.arguments.files()
        var quality = (call.arguments.bool("aggressive") ?? false) ? CompressionQuality.aggressive : .normal
        if let compression = try call.arguments.int("compression") {
            guard (0 ... 100).contains(compression) else { throw ToolFailure("compression is 0 to 100", code: "invalidArgument") }
            quality = CompressionQuality(tier: .custom, factor: compression)
        }
        return OptimisationRequest(
            sources: sources, origin: .mcp, quality: quality,
            stripMetadata: call.arguments.bool("stripMetadata"),
            location: try location(call),
            showResultUI: call.arguments.bool("showResult") ?? true
        )
    }

    static func location(_ call: ToolCall) throws -> OutputLocation {
        if let output = call.arguments.string("output") {
            return .path(output.hasPrefix("file:") ? (try PathInput.url(output)).path : output)
        }
        guard let raw = call.arguments.string("location") else { return call.service.policy.defaultLocation }
        switch raw.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "") {
        case "inplace", "overwrite": return .inPlace
        case "samefolder", "copy", "nexttooriginal": return .sameFolder
        case "temporary", "temp": return .temporary
        default: throw ToolFailure("location is inPlace, sameFolder or temporary (or pass output with a path)", code: "invalidArgument")
        }
    }

    static func runJob(_ call: ToolCall, _ operation: JobOperation, _ request: OptimisationRequest) async throws -> ToolOutput {
        let report = try await call.service.perform(OptimisationJob(request: request, operation: operation))
        let summary = JobSummary(operation: operation.name, report: report)
        var text = summary.text
        if report.failures.contains(where: { $0.error.code == "toolMissing" }) {
            text += "\nA bundled tool is missing in this process. If L'Esclop is installed, start the app (esclop_start_app) so it does the work; otherwise tell the person which tool is missing."
        }
        return ToolOutput(text, encoding: summary, isError: report.results.isEmpty && !report.failures.isEmpty)
    }

    static func parseFormat(_ raw: String) throws -> OutputFormat {
        let normalised = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let aliases: [String: OutputFormat] = ["jpg": .jpeg, "tif": .tiff, "h265": .hevc, "x265": .hevc, "gifvideo": .gifVideo, "m4v": .mp4]
        if let format = OutputFormat(rawValue: normalised) ?? aliases[normalised] { return format }
        throw ToolFailure("Unknown format \(raw). Formats: \(OutputFormat.allCases.map(\.rawValue).joined(separator: ", "))", code: "invalidArgument")
    }

    static func parseKind(_ raw: String) throws -> MediaKind {
        guard let kind = MediaKind(rawValue: raw.lowercased()) else {
            throw ToolFailure("type is image, video, pdf or audio, not \(raw)", code: "invalidArgument")
        }
        return kind
    }

    static func describe(_ files: [URL]) -> String {
        files.count == 1 ? files[0].lastPathComponent : "these \(files.count) files"
    }

    static func settingJSON(_ descriptor: SettingDescriptor) -> JSONValue {
        var json = (try? JSONValue.encode(descriptor).objectValue) ?? [:]
        json["schema"] = descriptor.schema
        return .object(json)
    }
}
