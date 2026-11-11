// SPDX-License-Identifier: GPL-3.0-or-later
//
// The catalog of steps and their arguments. One table drives the parser's validation, editor
// completions, the generated reference for agents and the prose in `describe()`.

import EsclopCore
import Foundation

/// What an argument accepts.
public enum ParamType: Hashable, Codable, Sendable {
    case integer(min: Int?, max: Int?)
    /// `minExclusive` makes the lower bound strict (a factor must be above 0).
    case number(min: Double?, max: Double?, minExclusive: Bool)
    case boolean
    /// One of a fixed set of words, matched without regard to case.
    case choice([String])
    /// `500KB`, `10MB`, `1.5MiB` or a byte count.
    case byteSize
    /// `30s`, `15m`, `1h`, `3d` or `never`.
    case duration
    /// Free text: a path, template, regex, script or name. Quote it.
    case text
    /// `inPlace`, `sameFolder`, `temporaryFolder` or a path template.
    case location
    /// `16:9`, `4:3`, `1.91:1`.
    case aspectRatio
    /// Space-separated extensions or kinds: `jpeg png webp`.
    case typeList
    /// `640x480` (the first number is the minimum edge).
    case resolution
    /// `adaptive`, `auto` or 5...100.
    case compression

    /// A short description for signatures and error messages.
    public var summary: String { summaryText.english }

    /// The summary as a template, for messages an app shows in its own language.
    public var summaryText: DiagnosticText {
        switch self {
        case let .integer(min, max):
            switch (min, max) {
            case let (lo?, hi?): T("a whole number from %@ to %@", String(lo), String(hi))
            case let (lo?, nil): T("a whole number of at least %@", String(lo))
            default: T("a whole number")
            }
        case let .number(min, max, exclusive):
            switch (min, max, exclusive) {
            case let (lo?, hi?, true): T("a number above %@ up to %@", PipelineSerializer.number(lo), PipelineSerializer.number(hi))
            case let (lo?, hi?, false): T("a number from %@ to %@", PipelineSerializer.number(lo), PipelineSerializer.number(hi))
            case let (lo?, nil, true): T("a number above %@", PipelineSerializer.number(lo))
            case let (lo?, nil, false): T("a number of at least %@", PipelineSerializer.number(lo))
            default: T("a number")
            }
        case .boolean: T("`true` or `false`")
        case let .choice(values): T("one of %@", values.map { "`\($0)`" }.joined(separator: ", "))
        case .byteSize: T("a size such as `500KB`, `10MB` or `2MiB`")
        case .duration: T("a duration such as `15m`, `1h`, `3d` or `never`")
        case .text: T("quoted text")
        case .location: T("`inPlace`, `sameFolder`, `temporaryFolder` or a quoted path template")
        case .aspectRatio: T("a ratio such as `16:9`, `4:3` or `1.91:1`")
        case .typeList: T("space-separated types such as `jpeg png webp` or `image`")
        case .resolution: T("a size such as `640x480`")
        case .compression: T("`adaptive`, `auto` or a number from 5 (best quality) to 100 (smallest file)")
        }
    }


    /// Values an editor can offer.
    public var suggestions: [String] {
        switch self {
        case let .choice(values): values
        case .boolean: ["true", "false"]
        case .location: ["inPlace", "sameFolder", "temporaryFolder"]
        case .duration: ["1m", "15m", "1h", "6h", "1d", "3d", "never"]
        case .byteSize: ["500KB", "1MB", "10MB", "25MB"]
        case .aspectRatio: ["16:9", "4:3", "1:1", "4:5", "9:16", "1.91:1"]
        case .compression: ["adaptive", "auto", "30", "64", "90"]
        case .typeList: ["image", "video", "pdf", "audio", "jpeg png", "png", "heic"]
        case .resolution: ["640x480", "1280x720"]
        case .integer, .number, .text: []
        }
    }

    /// Whether the serializer writes the value in quotes.
    var isQuoted: Bool {
        switch self {
        case .text: true
        default: false
        }
    }
}

public struct ParamSpec: Hashable, Codable, Sendable {
    public var name: String
    public var type: ParamType
    public var required: Bool
    /// Written when the argument is left out. Nil when leaving it out means "not set".
    public var defaultValue: String?
    public var doc: String
    /// The kinds the argument means something for; nil means every kind the step applies to.
    public var kinds: Set<MediaKind>?

    public init(_ name: String, _ type: ParamType, required: Bool = false, default defaultValue: String? = nil, kinds: Set<MediaKind>? = nil, _ doc: String) {
        self.name = name
        self.type = type
        self.required = required
        self.defaultValue = defaultValue
        self.doc = doc
        self.kinds = kinds
    }
}

public struct StepSpec: Hashable, Codable, Sendable {
    public var name: String
    public var summary: String
    public var category: StepCategory
    public var kinds: Set<MediaKind>
    public var params: [ParamSpec]
    /// The argument that may be written without its name: `convert(webp)` means `convert(to: webp)`.
    public var positional: String?
    public var example: String
    /// Rules and caveats worth knowing before using the step.
    public var notes: [String]
    /// Esclop-only step or arguments that Clop does not understand.
    public var esclopExtension: Bool

    public init(
        _ name: String, _ category: StepCategory, kinds: Set<MediaKind>, summary: String, params: [ParamSpec] = [],
        positional: String? = nil, example: String, notes: [String] = [], esclopExtension: Bool = false
    ) {
        self.name = name
        self.summary = summary
        self.category = category
        self.kinds = kinds
        self.params = params
        self.positional = positional
        self.example = example
        self.notes = notes
        self.esclopExtension = esclopExtension
    }

    public func param(_ name: String) -> ParamSpec? { params.first { $0.name == name } }

    public var requiredParams: [ParamSpec] { params.filter(\.required) }

    /// `crop(width?, height?, longEdge?, aspectRatio?, smartCrop?, location?)`
    public var signature: String {
        guard !params.isEmpty else { return name }
        return "\(name)(" + params.map { $0.required ? $0.name : "\($0.name)?" }.joined(separator: ", ") + ")"
    }

    /// The kinds as words, in a stable order.
    public var kindList: String {
        kinds.count == MediaKind.allCases.count ? "any file" : MediaKind.allCases.filter(kinds.contains).map(\.rawValue).joined(separator: ", ")
    }
}

private let allKinds = Set(MediaKind.allCases)
private let locationDoc = "where the result goes: `inPlace` replaces the file (a backup is kept), `sameFolder` writes next to the original, `temporaryFolder`, or a path template such as `\"~/Exports/%f\"`"

/// Formats `convert(to:)` accepts. Clop's names first, then extra esclop formats.
public let convertTargets: [(name: String, kinds: Set<MediaKind>, doc: String)] = [
    ("webp", [.image], "WebP image"),
    ("avif", [.image], "AVIF image (the AV1 video codec is `av1`)"),
    ("heic", [.image], "HEIC image"),
    ("jxl", [.image], "JPEG XL image"),
    ("jpeg", [.image], "JPEG image"),
    ("jpg", [.image], "JPEG image (same as `jpeg`)"),
    ("png", [.image], "PNG image"),
    ("gif", [.image, .video], "GIF; from a video, an animated GIF"),
    ("tiff", [.image], "TIFF image"),
    ("bmp", [.image], "BMP image"),
    ("mp4", [.video], "H.264 MP4 video"),
    ("hevc", [.video], "H.265 video with the hardware encoder"),
    ("x265", [.video], "H.265 video with the software encoder (slower, smaller)"),
    ("av1", [.video], "AV1 video"),
    ("webm", [.video], "WebM video"),
    ("mov", [.video], "QuickTime video"),
    ("mkv", [.video], "Matroska video"),
    ("m4a", [.audio], "AAC audio in an M4A file"),
    ("aac", [.audio], "AAC audio"),
    ("mp3", [.audio], "MP3 audio"),
    ("ogg", [.audio], "Ogg audio"),
    ("opus", [.audio], "Opus audio"),
    ("flac", [.audio], "FLAC lossless audio"),
    ("wav", [.audio], "WAV audio"),
    ("aiff", [.audio], "AIFF audio"),
]

extension PipelineLanguage {
    /// Every step the language knows, in the order the reference lists them.
    public static let steps: [StepSpec] = [
        // MARK: Processing
        StepSpec(
            "optimise", .processing, kinds: allKinds,
            summary: "Compress the file, keeping its format and size in pixels.",
            params: [
                ParamSpec("encoder", .choice(EncoderPreset.allCases.map(\.rawValue)), default: "medium",
                          "images, PDFs and audio: `medium`, `aggressive` or `lossless`; video: `fast` (hardware), `slowHighQuality` (software, smaller) or `visuallyLossless`"),
                ParamSpec("compression", .compression, kinds: [.image, .video, .audio],
                          "how hard to compress, 5 (best quality) to 100 (smallest file), `adaptive` to pick per file or `auto` to follow the app's setting"),
                ParamSpec("adaptive", .boolean, default: "false", kinds: [.image],
                          "let the format change when it makes the file smaller (PNG to JPEG and back)"),
                ParamSpec("dpi", .integer(min: 24, max: 1200), kinds: [.pdf],
                          "PDF only: downsample images to this resolution. 300 keeps print quality, 150 is for reading on screen, 72 is smallest"),
                ParamSpec("location", .location, default: "inPlace", locationDoc),
            ],
            example: "optimise(encoder: aggressive)",
            notes: ["Never put `optimise` right after `targetSize`: it would compress twice."]
        ),
        StepSpec(
            "downscale", .processing, kinds: [.image, .video, .audio],
            summary: "Scale the file down by a factor, keeping its proportions. For audio, lowers the bitrate.",
            params: [
                ParamSpec("factor", .number(min: 0, max: 1, minExclusive: true), required: true, "0.5 is half the width and height"),
                ParamSpec("location", .location, default: "inPlace", locationDoc),
            ],
            positional: "factor", example: "downscale(factor: 0.5)"
        ),
        StepSpec(
            "lowerBitrate", .processing, kinds: [.audio],
            summary: "Lower the audio bitrate. Never raises it.",
            params: [
                ParamSpec("kbps", .integer(min: 8, max: 1024), required: true, "target bitrate, e.g. 192, 128, 96, 64"),
                ParamSpec("location", .location, default: "inPlace", locationDoc),
            ],
            positional: "kbps", example: "lowerBitrate(kbps: 128)"
        ),
        StepSpec(
            "convert", .processing, kinds: [.image, .video, .audio],
            summary: "Change the format and compress in the same pass. Converting to the format the file already has does nothing.",
            params: [
                ParamSpec("to", .choice(convertTargets.map(\.name)), required: true,
                          "images: webp, avif, heic, jxl, jpeg, png, gif; video: mp4, hevc, x265, av1, webm, gif; audio: m4a, mp3, ogg, flac, wav, aiff"),
                ParamSpec("location", .location, default: "sameFolder", locationDoc + ". Defaults to `sameFolder`, so the original stays"),
            ],
            positional: "to", example: "convert(to: webp)"
        ),
        StepSpec(
            "crop", .processing, kinds: [.image, .video],
            summary: "Resize to exact pixels or crop to a shape. Give at least one of width, height, longEdge or aspectRatio.",
            params: [
                ParamSpec("width", .integer(min: 1, max: nil), "width in pixels; the height follows the proportions when it is left out"),
                ParamSpec("height", .integer(min: 1, max: nil), "height in pixels"),
                ParamSpec("longEdge", .integer(min: 1, max: nil), "length of the longest side in pixels, instead of width and height"),
                ParamSpec("aspectRatio", .aspectRatio, "crop to a shape at the file's own resolution, e.g. `16:9`; wins over width, height and longEdge"),
                ParamSpec("smartCrop", .boolean, default: "false", "keep the most interesting region instead of the centre"),
                ParamSpec("location", .location, default: "inPlace", locationDoc),
            ],
            example: "crop(longEdge: 1600)"
        ),
        StepSpec(
            "extractPagesAsImages", .processing, kinds: [.pdf],
            summary: "Render every page of a PDF as an image. With a single page, later steps continue on that image.",
            params: [
                ParamSpec("format", .choice(PageImageFormat.allCases.map(\.rawValue)), default: "jpeg", "image format of the pages"),
                ParamSpec("quality", .choice(PageImageQuality.allCases.map(\.rawValue)), default: "medium", "`low` (72 dpi), `medium` (144 dpi) or `high` (216 dpi)"),
                ParamSpec("location", .location, default: "sameFolder", "where the page images go; defaults to next to the PDF"),
            ],
            example: "extractPagesAsImages(format: png, quality: high)"
        ),
        StepSpec(
            "targetSize", .processing, kinds: allKinds,
            summary: "Compress, then shrink, until the file fits under a size.",
            params: [
                ParamSpec("size", .byteSize, required: true, "the limit: Discord and GitHub 10MB, WhatsApp 16MB, Gmail 25MB"),
                ParamSpec("location", .location, default: "inPlace", locationDoc),
            ],
            positional: "size", example: "targetSize(size: 10MB)",
            notes: ["It already compresses: a following `optimise` only costs quality."]
        ),
        StepSpec("stripExif", .processing, kinds: [.image, .video], summary: "Remove EXIF and GPS metadata.", example: "stripExif"),
        StepSpec(
            "watermark", .processing, kinds: [.image, .video],
            summary: "Overlay an image, such as a logo, on the file.",
            params: [
                ParamSpec("image", .text, required: true, "path to the watermark (a PNG with transparency works best); templates allowed"),
                ParamSpec("position", .choice(WatermarkPosition.allCases.map(\.rawValue)), default: "bottomRight", "corner or centre"),
                ParamSpec("opacity", .number(min: 0, max: 1, minExclusive: false), default: "1.0", "0 is invisible, 1 is opaque"),
                ParamSpec("scale", .number(min: 0, max: 1, minExclusive: true), default: "0.15", "watermark width as a fraction of the file's width"),
                ParamSpec("location", .location, default: "inPlace", locationDoc),
            ],
            positional: "image", example: "watermark(image: \"~/logo.png\", position: bottomRight)"
        ),

        // MARK: File operations
        StepSpec(
            "copy", .fileOperation, kinds: allKinds,
            summary: "Copy the file and continue with the copy.",
            params: [ParamSpec("to", .text, required: true, "folder (ending in `/`) or path template; relative paths start in the file's folder")],
            positional: "to", example: "copy(to: \"~/Sync/\")"
        ),
        StepSpec(
            "move", .fileOperation, kinds: allKinds,
            summary: "Move the file and continue from its new place.",
            params: [ParamSpec("to", .text, required: true, "folder (ending in `/`) or path template")],
            positional: "to", example: "move(to: \"~/Pictures/Screenshots/%y/%m/\")"
        ),
        StepSpec(
            "rename", .fileOperation, kinds: allKinds,
            summary: "Rename the file in its folder. The extension is kept when the new name has none.",
            params: [ParamSpec("to", .text, required: true, "new name or template, e.g. `\"%y-%m-%d %f\"`")],
            positional: "to", example: "rename(to: \"%f-small\")"
        ),
        StepSpec(
            "delete", .fileOperation, kinds: allKinds,
            summary: "Move a file to the Trash. `sourceFile` is the file the pipeline started with, `currentFile` the one it carries now.",
            params: [ParamSpec("path", .text, required: true, "`sourceFile`, `currentFile` or a path template")],
            positional: "path", example: "delete(path: sourceFile)",
            notes: ["Folders are never deleted."]
        ),

        // MARK: Filters
        StepSpec(
            "if", .filter, kinds: allKinds,
            summary: "Continue only when every condition holds; otherwise the file quietly stops here. There is no `else`.",
            params: conditionParams, example: "if(regex: \"^IMG_\")",
            notes: ["Several conditions in one `if` must all hold.", "Capture groups of `regex` are available as `$1`, `$2` in later templates."]
        ),
        StepSpec(
            "ifNot", .filter, kinds: allKinds,
            summary: "Stop the file when the conditions hold; continue otherwise.",
            params: conditionParams, example: "ifNot(nameContains: \"draft\")"
        ),

        // MARK: Media-specific
        StepSpec("removeAudio", .mediaSpecific, kinds: [.video], summary: "Remove the audio track.", example: "removeAudio"),
        StepSpec(
            "changeSpeed", .mediaSpecific, kinds: [.video, .audio],
            summary: "Change the playback speed.",
            params: [
                ParamSpec("factor", .number(min: 0, max: 100, minExclusive: true), required: true, "2.0 plays twice as fast, 0.5 at half speed"),
                ParamSpec("frames", .choice(FrameBehaviour.allCases.map(\.rawValue)), kinds: [.video],
                          "`keep` keeps every frame (the frame rate rises), `drop` keeps the source frame rate for a smaller file; left out, the app's setting decides"),
            ],
            positional: "factor", example: "changeSpeed(factor: 2.0, frames: drop)"
        ),
        StepSpec(
            "capFps", .mediaSpecific, kinds: [.video],
            summary: "Cap the frame rate.",
            params: [ParamSpec("fps", .integer(min: 1, max: 240), required: true, "e.g. 60, 30, 24")],
            positional: "fps", example: "capFps(fps: 30)"
        ),
        StepSpec(
            "normalize", .mediaSpecific, kinds: [.audio],
            summary: "Even out loudness.",
            params: [ParamSpec("lufs", .number(min: -70, max: 0, minExclusive: false), default: "-16", "target loudness: -14 streaming, -16 podcasts, -23 broadcast")],
            positional: "lufs", example: "normalize(lufs: -14)"
        ),

        // MARK: Actions
        StepSpec(
            "runScript", .action, kinds: allKinds,
            summary: "Run a shell script with the file as `$1`. If it prints the path of a file of the same kind, the pipeline continues with that file.",
            params: [
                ParamSpec("path", .text, "script file to run (executable files run directly, others through zsh)"),
                ParamSpec("code", .text, "one line of zsh, e.g. `\"sips -Z 800 $1\"`; must not contain `->`"),
            ],
            example: "runScript(code: \"sips -Z 800 $1\")",
            notes: ["Give `path` or `code`.", "Bundled tools (ffmpeg, gifsicle, esclop-engine) are in `$ESCLOP_BIN`; the file is also in `$ESCLOP_INPUT_FILE`.", "Scripts only run where the setting that allows them is on."]
        ),
        StepSpec(
            "runShortcut", .action, kinds: [.image, .video, .pdf, .audio],
            summary: "Run a macOS Shortcut with the file as input. A file it returns replaces the current one.",
            params: [ParamSpec("name", .text, required: true, "the Shortcut's name")],
            positional: "name", example: "runShortcut(name: \"Resize for Web\")"
        ),
        StepSpec(
            "copyToClipboard", .action, kinds: allKinds,
            summary: "Copy the file to the clipboard.",
            params: [
                ParamSpec("format", .choice(ClipboardFormat.allCases.map(\.rawValue)), default: "path", "`path`, `imageData` (images) or `markdown` (a Markdown link or image)"),
                ParamSpec("relativeTo", .text, "make the path or link relative to this folder, e.g. `\"~/Projects/blog\"`"),
            ],
            positional: "format", example: "copyToClipboard(format: markdown)"
        ),
        StepSpec(
            "copyLinkForSending", .action, kinds: allKinds,
            summary: "Share the file through a link and copy the link.",
            params: [ParamSpec("expiration", .duration, "stop sharing after this long, or `never`; left out, the app's setting decides")],
            positional: "expiration", example: "copyLinkForSending(expiration: 1d)"
        ),
        StepSpec(
            "fork", .action, kinds: allKinds,
            summary: "Also show the result so far as a second result, then keep going with the same file.",
            params: [ParamSpec("location", .location, "save the forked copy here; left out, it stays in a temporary folder")],
            positional: "location", example: "optimise -> fork -> convert(to: webp)"
        ),
        StepSpec(
            "shelveWith", .action, kinds: allKinds,
            summary: "Put the file on a shelf app.",
            params: [ParamSpec("app", .choice(shelfApps), required: true, "the shelf app")],
            positional: "app", example: "shelveWith(app: yoink)"
        ),
        StepSpec(
            "uploadWith", .action, kinds: allKinds,
            summary: "Upload the file with an upload app.",
            params: [ParamSpec("app", .choice(uploadApps), required: true, "the upload app")],
            positional: "app", example: "uploadWith(app: dropshare)"
        ),
        StepSpec(
            "openWith", .action, kinds: allKinds,
            summary: "Open the file in an app.",
            params: [ParamSpec("app", .text, required: true, "application name, e.g. `Preview`")],
            positional: "app", example: "openWith(app: Preview)"
        ),
    ]

    /// The keys of `if(...)` and `ifNot(...)`.
    public static let conditionParams: [ParamSpec] = [
        ParamSpec("types", .typeList, "extensions or kinds, space separated: `jpeg png webp`, `image`, `video`"),
        ParamSpec("regex", .text, "regular expression matched against the file name; all lower case ignores case. Capture groups become `$1`, `$2`"),
        ParamSpec("nameContains", .text, "the file name contains this text (any case)"),
        ParamSpec("nameIs", .text, "the file name is exactly this"),
        ParamSpec("fileSizeGreaterThan", .byteSize, "the file is larger than this many bytes"),
        ParamSpec("fileSizeLowerThan", .byteSize, "the file is smaller than this many bytes"),
        ParamSpec("minFileSize", .byteSize, "the file is at least this size, e.g. `100kb`"),
        ParamSpec("widthGreaterThan", .integer(min: 0, max: nil), kinds: [.image, .video], "wider than this many pixels"),
        ParamSpec("widthLowerThan", .integer(min: 0, max: nil), kinds: [.image, .video], "narrower than this many pixels"),
        ParamSpec("heightGreaterThan", .integer(min: 0, max: nil), kinds: [.image, .video], "taller than this many pixels"),
        ParamSpec("heightLowerThan", .integer(min: 0, max: nil), kinds: [.image, .video], "shorter than this many pixels"),
        ParamSpec("minResolution", .resolution, kinds: [.image, .video], "both sides are at least this long, e.g. `640x480` (the first number counts)"),
        ParamSpec("dpiGreaterThan", .integer(min: 0, max: nil), kinds: [.image, .pdf], "resolution above this DPI"),
        ParamSpec("dpiLowerThan", .integer(min: 0, max: nil), kinds: [.image, .pdf], "resolution below this DPI"),
        ParamSpec("durationGreaterThan", .number(min: 0, max: nil, minExclusive: false), kinds: [.video, .audio], "longer than this many seconds (esclop)"),
        ParamSpec("durationLowerThan", .number(min: 0, max: nil, minExclusive: false), kinds: [.video, .audio], "shorter than this many seconds (esclop)"),
        ParamSpec("copiedBy", .text, "the clipboard content came from this app (name or bundle id, any part of it)"),
    ]

    private static let specsByName: [String: StepSpec] = Dictionary(uniqueKeysWithValues: steps.map { ($0.name, $0) })

    public static func spec(named name: String) -> StepSpec? { specsByName[name] }

    /// Common misspellings and names from other tools, mapped to the step meant.
    static let aliases: [String: String] = [
        "optimize": "optimise", "compress": "optimise", "optimisation": "optimise", "optimization": "optimise",
        "resize": "downscale", "scale": "downscale", "shrink": "downscale",
        "filterIf": "if", "filter": "if", "when": "if", "filterIfNot": "ifNot", "unless": "ifNot", "ifnot": "ifNot",
        "normalise": "normalize", "loudness": "normalize",
        "strip": "stripExif", "stripMetadata": "stripExif", "removeMetadata": "stripExif", "stripexif": "stripExif",
        "mute": "removeAudio", "speed": "changeSpeed", "fps": "capFps",
        "fitUnder": "targetSize", "fit": "targetSize", "maxSize": "targetSize",
        "open": "openWith", "upload": "uploadWith", "shelve": "shelveWith", "shortcut": "runShortcut", "script": "runScript",
        "clipboard": "copyToClipboard", "duplicate": "copy", "trash": "delete", "remove": "delete",
    ]
}

/// The tokens path templates understand. Clop's set, so templates written for Clop resolve the same.
public struct TemplateToken: Hashable, Codable, Sendable {
    public var token: String
    public var meaning: String
}

extension PipelineLanguage {
    public static let templateTokens: [TemplateToken] = [
        TemplateToken(token: "%f", meaning: "file name without extension"),
        TemplateToken(token: "%e", meaning: "extension, without the dot"),
        TemplateToken(token: "%P", meaning: "folder the file is in"),
        TemplateToken(token: "%F", meaning: "full path of the file"),
        TemplateToken(token: "%y", meaning: "year, e.g. 2026"),
        TemplateToken(token: "%m", meaning: "month, 01 to 12"),
        TemplateToken(token: "%n", meaning: "month name, e.g. March"),
        TemplateToken(token: "%d", meaning: "day of the month, 01 to 31"),
        TemplateToken(token: "%w", meaning: "weekday number, 1 (Sunday) to 7"),
        TemplateToken(token: "%H", meaning: "hour, 00 to 23"),
        TemplateToken(token: "%M", meaning: "minutes, 00 to 59"),
        TemplateToken(token: "%S", meaning: "seconds, 00 to 59"),
        TemplateToken(token: "%p", meaning: "AM or PM"),
        TemplateToken(token: "%r", meaning: "five random letters"),
        TemplateToken(token: "%i", meaning: "a number that goes up by one for each file in the run"),
        TemplateToken(token: "$1", meaning: "first capture group of the last `if(regex:)`; `$2`, `$3` and so on for the next ones"),
        TemplateToken(token: "~", meaning: "your home folder, at the start of a path"),
    ]
}
