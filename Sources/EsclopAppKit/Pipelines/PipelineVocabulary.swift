// SPDX-License-Identifier: GPL-3.0-or-later
//
// The pipeline editor's words for steps, their arguments, triggers and sections. The language
// keeps its own names (`convert`, `longEdge`); the editor shows these beside them.

import EsclopCore
import EsclopPipelines

enum PipelineVocabulary {
    static func stepTitle(_ name: String) -> String {
        switch name {
        case "optimise": Strings.text("Optimise")
        case "downscale": Strings.text("Downscale")
        case "lowerBitrate": Strings.text("Lower the bitrate")
        case "convert": Strings.text("Convert")
        case "crop": Strings.text("Crop")
        case "extractPagesAsImages": Strings.text("Pages as images")
        case "targetSize": Strings.text("Fit under a size")
        case "stripExif": Strings.text("Strip metadata")
        case "watermark": Strings.text("Watermark")
        case "copy": Strings.text("Copy the file")
        case "move": Strings.text("Move the file")
        case "rename": Strings.text("Rename")
        case "delete": Strings.text("Move to the Trash")
        case "if": Strings.text("Only if")
        case "ifNot": Strings.text("Skip if")
        case "removeAudio": Strings.text("Remove the sound")
        case "changeSpeed": Strings.text("Change the speed")
        case "capFps": Strings.text("Cap the frame rate")
        case "normalize": Strings.text("Even out the loudness")
        case "runScript": Strings.text("Run a script")
        case "runShortcut": Strings.text("Run a Shortcut")
        case "copyToClipboard": Strings.text("Copy to the clipboard")
        case "copyLinkForSending": Strings.text("Copy a link for sending")
        case "fork": Strings.text("Show the result so far")
        case "shelveWith": Strings.text("Put on a shelf")
        case "uploadWith": Strings.text("Upload")
        case "openWith": Strings.text("Open with")
        default: name
        }
    }

    /// The step's one-line help (the catalog's summary) in the app's language. The catalog stays
    /// English for the CLI and agents; its backticks are dropped for a tooltip.
    static func stepHelp(_ spec: StepSpec) -> String {
        SettingWords.lookup("step.\(spec.name).summary", english: spec.summary).replacingOccurrences(of: "`", with: "")
    }

    /// An argument's help; `ifNot` shares `if`'s conditions.
    static func paramHelp(step: String, param: ParamSpec) -> String {
        SettingWords.lookup(paramHelpKey(step: step, param: param.name), english: param.doc).replacingOccurrences(of: "`", with: "")
    }

    static func paramHelpKey(step: String, param: String) -> String { "step.\(step == "ifNot" ? "if" : step).\(param)" }

    static func paramTitle(_ name: String) -> String {
        switch name {
        case "adaptive": Strings.text("Change format when smaller")
        case "app": Strings.text("App")
        case "aspectRatio": Strings.text("Aspect ratio")
        case "code": Strings.text("Script")
        case "compression": Strings.text("Compression")
        case "copiedBy": Strings.text("Copied from the app")
        case "dpi": Strings.text("Image resolution (DPI)")
        case "dpiGreaterThan": Strings.text("DPI above")
        case "dpiLowerThan": Strings.text("DPI below")
        case "durationGreaterThan": Strings.text("Longer than (seconds)")
        case "durationLowerThan": Strings.text("Shorter than (seconds)")
        case "encoder": Strings.text("Encoder")
        case "expiration": Strings.text("Link expires after")
        case "factor": Strings.text("Factor")
        case "fileSizeGreaterThan": Strings.text("Larger than (bytes)")
        case "fileSizeLowerThan": Strings.text("Smaller than (bytes)")
        case "format": Strings.text("Format")
        case "fps": Strings.text("Frames per second")
        case "frames": Strings.text("Frames")
        case "height": Strings.text("Height")
        case "heightGreaterThan": Strings.text("Taller than (px)")
        case "heightLowerThan": Strings.text("Shorter than (px)")
        case "image": Strings.text("Watermark image")
        case "kbps": Strings.text("Bitrate (kbps)")
        case "location": Strings.text("Save to")
        case "longEdge": Strings.text("Long edge (px)")
        case "lufs": Strings.text("Loudness (LUFS)")
        case "minFileSize": Strings.text("At least this size")
        case "minResolution": Strings.text("At least this resolution")
        case "name": Strings.text("Name")
        case "nameContains": Strings.text("Name contains")
        case "nameIs": Strings.text("Name is")
        case "opacity": Strings.text("Opacity")
        case "path": Strings.text("Path")
        case "position": Strings.text("Position")
        case "quality": Strings.text("Quality")
        case "regex": Strings.text("Name matches (regular expression)")
        case "relativeTo": Strings.text("Relative to")
        case "scale": Strings.text("Scale")
        case "size": Strings.text("Size")
        case "smartCrop": Strings.text("Smart crop")
        case "to": Strings.text("To")
        case "types": Strings.text("File types")
        case "width": Strings.text("Width")
        case "widthGreaterThan": Strings.text("Wider than (px)")
        case "widthLowerThan": Strings.text("Narrower than (px)")
        default: name
        }
    }

    static func triggerTitle(_ name: String) -> String {
        switch name {
        case "clipboard": Strings.text("Copied files and images")
        case "dropZone": Strings.text("Files dropped on the drop zone")
        case "presetZone": Strings.text("A preset zone while dragging")
        case "rightClick": Strings.text("Finder’s right-click menu")
        case "cli": Strings.text("The command line")
        case "mcp": Strings.text("AI agents")
        default: name
        }
    }

    static func sectionTitle(_ kind: MediaKind?) -> String {
        switch kind {
        case nil: Strings.text("Any file")
        case .image: Strings.text("Images")
        case .video: Strings.text("Video")
        case .pdf: Strings.text("PDF")
        case .audio: Strings.text("Audio")
        }
    }

    static func categoryTitle(_ category: StepCategory) -> String {
        switch category {
        case .processing: Strings.text("Change the file")
        case .fileOperation: Strings.text("Move and rename")
        case .filter: Strings.text("Filters")
        case .mediaSpecific: Strings.text("Video and audio")
        case .action: Strings.text("Share and run")
        }
    }

    static func outcomeTitle(_ outcome: PipelineLogEntry.Outcome) -> String {
        switch outcome {
        case .done: Strings.text("Done")
        case .unchanged: Strings.text("Unchanged")
        case .skipped: Strings.text("Skipped")
        case .stopped: Strings.text("Stopped by the filter")
        case .failed: Strings.text("Failed")
        }
    }
}
