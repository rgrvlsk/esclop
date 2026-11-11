# Pipelines

A pipeline is a list of steps esclop runs on a file: optimise it, resize it, convert it, move
it somewhere or copy a path. Pipelines run through `esclop pipeline run` and MCP.
The app runs a pipeline with a `folder(...)` trigger on new files in that folder (see
[Triggers](#triggers)). Clipboard and drop-zone triggers are planned; their configuration can
already be saved.

The language follows Clop's step names and syntax. Supported operations depend on the
engine and host; see [Coming from Clop](#coming-from-clop) for differences.
esclop adds a file format around it (front matter, sections per kind of file, comments).

In the app, the pipeline editor (menu → Pipelines…, or `esclop://pipelines`) makes and changes
pipelines without the text: it saves the same files, written the way `esclop pipeline show`
prints them.

This page is the reference for people and for agents. The same catalog is available in code as
`PipelineLanguage.steps`, and `PipelineLanguage.referenceMarkdown()` prints a compact version.

## A first pipeline

```
crop(longEdge: 1600) -> convert(to: webp) -> copyToClipboard(format: markdown)
```

Each image is resized so its longest side is 1600 px, converted to WebP next to the original,
and the CLI copies a Markdown link to it. MCP runs skip clipboard steps.

## Syntax

- Steps run left to right, joined by `->` or written one per line. Both styles can be mixed.
- A step is `name(key: value, key: value)`. A step with nothing to set can be written bare:
  `optimise`, `stripExif`, `removeAudio`. `optimise()` works too.
- Quote paths, templates, regexes, scripts and names: `move(to: "~/Pictures/%y/")`,
  `if(regex: "^IMG_")`. Words and numbers need no quotes: `convert(to: webp)`, `downscale(factor: 0.5)`.
- Double or single quotes, with no escapes: a backslash is just a backslash, so regexes read as
  written (`"\d+"`). To put a `"` in a value, use single quotes around it, and the other way round.
  Inside quotes, `->`, `,` and `)` are plain text.
- Arguments may span lines inside the parentheses, and a trailing comma is fine.
- `#` starts a comment that runs to the end of the line (outside quotes).
- Choices such as `webp` or `bottomRight` ignore case.
- esclop also accepts the main argument without its name: `convert(webp)`, `downscale(0.5)`,
  `targetSize(10MB)`. It always writes the named form, which Clop also reads.

Mistakes come back with a line, a column and the fix:

```
line 2, column 1: Unknown step `optimize`. Did you mean `optimise`?
line 1, column 19: `factor` must be above 0 and at most 1: esclop only scales down. `0.5` is half size.
line 1, column 6: `crop` has no argument `widht`. Did you mean `width`?
```

## The `.pipeline` file

Saved pipelines are text files in `~/Library/Application Support/esclop/pipelines/`, one per
pipeline, named `<name>.pipeline`. The file name is the pipeline's name. Edit them in any editor;
esclop reads them as they are.

```
---
description: Images for the blog, videos for the team chat
hotkey: ctrl+alt+cmd+b
icon: globe
triggers: dropZone, folder("~/Desktop/To blog")
optimiseFirst: false
hideResult: false
---
# Steps before any section run for every kind of file without a section of its own.
optimise

[image]
crop(longEdge: 1600) -> convert(to: webp) -> copyToClipboard(format: markdown)

[video]
crop(width: 1280) -> changeSpeed(factor: 1.5, frames: drop) -> targetSize(size: 10MB)
```

### Front matter

UI metadata and automatic triggers are stored for the planned app; they are not active yet.

Optional, between two `---` lines at the very top. Every key is optional.

| Key | Meaning |
|---|---|
| `description` | One line saying what the pipeline is for. Shown in menus and to agents. |
| `hotkey` | A global shortcut, for example `ctrl+alt+cmd+w`. |
| `icon` | An SF Symbol name for preset zones and menus. |
| `triggers` | What runs the pipeline on its own, comma separated (see below). |
| `optimiseFirst` | `true` optimises each file before the steps (after any leading `if`). Skipped when the first step already re-encodes (`convert`, `crop`, `downscale`). Default `false`. |
| `hideResult` | `true` runs without showing the floating result. Default `false`. |

### Sections

`[image]`, `[video]`, `[pdf]` and `[audio]` start the steps for that kind of file. `[any]` (or
no header at all) holds the steps for every kind that has no section of its own. A file of a kind
with neither runs nothing and is reported as unsupported.

A plain Clop pipeline is just an `[any]` section, so Clop text is a valid `.pipeline` file.

### Triggers

| Trigger | Runs the pipeline |
|---|---|
| `clipboard` | on files and images you copy |
| `dropZone` | on files dropped on the drop zone |
| `presetZone` | from a preset zone beside the drop zone while you drag (order and built-in templates: Settings › Floating results › Preset zones) |
| `folder("~/path")` | on new files directly in that folder, instead of the plain optimisation, for the kinds it has steps for; the folder is watched even when no Settings list names it |
| `rightClick` | from Finder's right-click menu: Quick Actions › Run a Pipeline with L’Esclop… lists every pipeline with this trigger (one runs straight away) |
| `cli` | as a quick action offered by the command line |
| `mcp` | when an AI agent asks for it; listed as a tool hint |

A `folder(...)` pipeline sees the same new files as the Settings folder lists: hidden,
temporary and already optimised files are skipped, a file still being written waits, and more
files of one kind at once than its count (`maxImageFileCount` and the like) are left alone. The
size limits do not apply; the pipeline can filter with `if(...)`. When two pipelines name the
same folder, the first by name runs.

## Steps

Each step lists the kinds of file it applies to. A step that does not apply to the current file
is skipped and the pipeline carries on, so `removeAudio` in a pipeline that also gets images is
harmless.

### Processing

These re-encode the file. Each takes `location` (see [Where results go](#where-results-go)).

`optimise(encoder?, compression?, adaptive?, dpi?, location?)` applies to any file. Compress, keeping the
format and the pixel size.
- `encoder`: `medium` (default), `aggressive`, `lossless` for images, PDFs and audio; `fast`
  (hardware), `slowHighQuality` (software, smaller) or `visuallyLossless` for video.
- `compression`: 5 (best quality) to 100 (smallest file), `adaptive` to pick per file, or `auto`
  to follow the app's setting. Overrides `encoder` for how hard to compress.
- `adaptive`: `true` lets the format change when that is smaller (PNG to JPEG and back). Images only.
- `dpi`: PDFs only. Downsample images inside the PDF: 300 keeps print quality, 150 is for screens, 72 is smallest.

`downscale(factor, location?)` applies to images, video and audio. Scale down keeping the proportions.
- `factor`: above 0 and at most 1; `0.5` is half the width and height. For audio it lowers the bitrate.

`lowerBitrate(kbps, location?)` applies to audio. Lower the bitrate (`kbps`: 192, 128, 96...). Never raises it.

`convert(to, location?)` applies to images, video and audio. Change the format and compress in the same pass.
`location` defaults to `sameFolder`, so the original stays. Converting to the format the file
already has does nothing.
- `to`: images `webp`, `avif`, `heic`, `jxl`, `jpeg` (or `jpg`), `png`, `gif`, `tiff`, `bmp`;
  video `mp4`, `hevc` (hardware H.265), `x265` (software H.265, smaller), `av1`, `webm`, `mov`,
  `mkv`, `gif` (animated); audio `m4a`, `aac`, `mp3`, `ogg`, `opus`, `flac`, `wav`, `aiff`.
  `avif` is the image format; the AV1 video codec is `av1`.

`crop(width?, height?, longEdge?, aspectRatio?, smartCrop?, location?)` applies to images and video. Resize to
exact pixels or crop to a shape. Give at least one size.
- `width`, `height`: pixels. With only one, the other follows the proportions.
- `longEdge`: length of the longest side, instead of width and height.
- `aspectRatio`: crop to a shape at the file's own resolution, such as `16:9`, `4:3`, `1:1` or
  `1.91:1`. Wins over the pixel sizes.
- `smartCrop`: `true` keeps the most interesting region instead of the centre.

`extractPagesAsImages(format?, quality?, location?)` applies to PDFs. Save each page as an image; by default
next to the PDF. With a single page, the following steps continue on that image; otherwise they
continue on the PDF.
- `format`: `jpeg` (default) or `png`.
- `quality`: `low` (72 dpi), `medium` (144 dpi, default) or `high` (216 dpi).

`targetSize(size, location?)` applies to any file. Compress, then shrink, until the file is under `size`:
`500KB`, `10MB`, `2MiB` or a byte count. KB, MB and GB are powers of 1000; KiB, MiB and GiB of
1024. Check the destination's current upload limit. Do not follow it with
`optimise`: that would compress twice.

`stripExif` applies to images and video. Remove EXIF and GPS metadata.

`watermark(image, position?, opacity?, scale?, location?)` applies to images and video. Overlay an image.
- `image`: path to the watermark, templates allowed (`"%P/logo.png"`). A PNG with transparency works best.
- `position`: `bottomRight` (default), `bottomLeft`, `topRight`, `topLeft`, `center`.
- `opacity`: 0 to 1, default 1. `scale`: watermark width as a fraction of the file's width, default 0.15.

### File operations

Templates work in every path (see [Templates](#templates)). Relative paths start in the current
file's folder. A path ending in `/`, or naming a folder that exists, means "into that folder"
under the file's own name. When the name has no extension, the file's extension is added. An
existing file at the destination is replaced.

`copy(to)` copies the file and continues with the copy.

`move(to)` moves the file and continues from its new place.

`rename(to)` renames the file in its folder: `rename(to: "%y-%m-%d %f")`.

`delete(path)` moves a file to the Trash. `path` is `sourceFile` (the file the pipeline started
with), `currentFile`, or a template. Folders are never deleted. Agents and other callers may be
denied deletion, and the step then fails.

### Filters

`if(...)` continues only when every condition holds. When one fails, the file quietly stops at
that step: no error, nothing after it runs. `ifNot(...)` is the opposite: it stops the file when
the conditions hold. There is no `else`; to treat kinds of file differently, use sections.

Conditions (several in one filter must all hold):

| Key | Holds when |
|---|---|
| `types` | the file is one of these, space separated: kinds (`image`, `video`, `pdf`, `audio`), extensions (`jpeg png webp`) or UTType identifiers (`public.jpeg`) |
| `regex` | the file name matches. All lower case ignores case; any capital makes it case sensitive. Capture groups become `$1`, `$2`... in later templates |
| `nameContains` | the file name contains the text, any case |
| `nameIs` | the file name is exactly this |
| `fileSizeGreaterThan` / `fileSizeLowerThan` | the file is larger / smaller than this many bytes (sizes like `2MB` also work) |
| `minFileSize` | the file is at least this size: `100kb` |
| `widthGreaterThan` / `widthLowerThan` | wider / narrower than this many pixels |
| `heightGreaterThan` / `heightLowerThan` | taller / shorter than this many pixels |
| `minResolution` | both sides are at least this long: `640x480` (the first number counts) |
| `dpiGreaterThan` / `dpiLowerThan` | the image's resolution is above / below this DPI |
| `durationGreaterThan` / `durationLowerThan` | video or audio lasting more / less than this many seconds (esclop only) |
| `copiedBy` | the clipboard content came from this app: any part of its name or bundle id, any case |

A file that has no such property (the width of an audio file) does not meet the condition.

### Video and audio

`removeAudio` applies to video. Remove the audio track.

`changeSpeed(factor, frames?)` applies to video and audio. Play at `factor` times the speed (2.0 is twice as
fast, 0.5 half). `frames` (video): `keep` keeps every frame so the frame rate rises; `drop` keeps
the source frame rate for a smaller file; left out, the app's setting decides.

`capFps(fps)` applies to video. Cap the frame rate; `fps` is 60, 30, 24...

`normalize(lufs?)` applies to audio. Even out loudness to `lufs`, default -16 (podcasts). -14 suits
streaming services, -23 broadcast.

### Actions

`runScript(path?, code?)` runs a shell script with the file as `$1` (also in
`$ESCLOP_INPUT_FILE`). `code` is one line of zsh; `path` is a script file (run directly when
executable, through zsh otherwise). The bundled tools (ffmpeg, gifsicle, esclop-engine) are in
`$ESCLOP_BIN`. When the script prints the path of an existing file of the same kind, the pipeline
continues with that file. A non-zero exit fails the file and the log shows its error output.
Scripts only run where the setting that allows them is on; agents cannot run them unless you
allow it. Inline code must not contain new lines; inside quotes `->` is fine in esclop, but Clop
splits on it, so avoid it in pipelines you share with Clop.

```
runScript(code: "sips -Z 800 $1")
runScript(code: "$ESCLOP_BIN/gs -q -sDEVICE=txtwrite -o ${1:r}.txt $1")
```

`runShortcut(name)` runs the macOS Shortcut called `name` with the file as input. If the Shortcut returns a file
of the same kind, the pipeline continues with it.

`copyToClipboard(format?, relativeTo?)` copies the file: `path` (default), `imageData` (images) or
`markdown` (an image or link). `relativeTo` makes the path or link relative to a folder, such as
`"~/Projects/blog"`.

`copyLinkForSending(expiration?)` shares the file through a link and copies the link. `expiration`
stops sharing after `15m`, `1h`, `1d`, `3d`... or `never`; left out, the app's setting decides.

`fork(location?)` saves the result so far as a second result, then continues with the same
file: `optimise -> fork -> convert(to: webp)` gives the optimised original and a WebP. Without a
`location` the forked file stays where it is, or goes to a temporary folder when a later step
would overwrite it. With a `location` a copy is saved there.

`shelveWith(app)` puts the file on a shelf app; `app` is `yoink`, `dockside`, `dropover` or `atoll`.

`uploadWith(app)` uploads with an upload app; `app` is `dropshare`.

`openWith(app)`. open the file in the app named by `app`: `openWith(app: Preview)`.

The CLI supports opening files and copying paths or Markdown with `pbcopy`. Image-data
clipboard, sharing, shelf and upload actions require the planned app integration and are
currently skipped with a run-log message. MCP uses a host that skips these host actions.

## Where results go

Processing steps take `location`:

| Value | Result |
|---|---|
| `inPlace` | replaces the current file; the original goes to esclop's backups first. The default for most steps. |
| `sameFolder` | a new file next to the original; the default for `convert` and `extractPagesAsImages` |
| `temporaryFolder` | a new file in esclop's temporary folder |
| `"template"` | a path template, such as `"~/Exports/%f-small"` or `"%P/web/"` |

A template that is only a name lands next to the original. A template ending in `/` (or naming an
existing folder) is a folder, and the file keeps its name. When the template has no extension,
the result's own extension is added, so `"%P/out/%f"` works whatever `convert` produced.

The steps after a processing step continue with its result, wherever it went.

## Templates

Paths and names may use these tokens. They describe the file the pipeline started with.

| Token | Becomes |
|---|---|
| `%f` | file name without extension |
| `%e` | extension, without the dot |
| `%P` | folder the file is in |
| `%F` | full path of the file |
| `%y` | year, e.g. 2026 |
| `%m` | month, 01 to 12 |
| `%n` | month name, e.g. March |
| `%d` | day of the month, 01 to 31 |
| `%w` | weekday number, 1 (Sunday) to 7 |
| `%H` | hour, 00 to 23 |
| `%M` | minutes, 00 to 59 |
| `%S` | seconds, 00 to 59 |
| `%p` | AM or PM |
| `%r` | five random letters |
| `%i` | a number that goes up by one for each file in the run |
| `$1` | first capture group of the last `if(regex:)`; `$2`, `$3` and so on for the next ones |
| `~` | your home folder, at the start of a path (`$HOME` works too) |

`%d` is the day, as in Clop; the folder is `%P`.

## Running

- The steps run in order on a "current file". Processing steps replace it with their result,
  `copy`, `move` and `rename` move it, `fork` branches a copy off without changing it.
- A failing step stops that file and the run log says why; the other files carry on.
  "Already as small as it gets" is not a failure: the step is logged as unchanged.
- Filters stop a file without an error; the report marks it `filtered`.
- Every step leaves an entry in the run log: the step as text, what happened (`done`,
  `unchanged`, `skipped`, `stopped`, `failed`), a message and the file afterwards.
- An inline pipeline runs exactly the steps written. A saved one does too, unless its front
  matter says `optimiseFirst: true`.

## Built-in presets

| Name | Steps |
|---|---|
| to WebP | `[image]` `convert(to: webp)` |
| sort screenshots | `[image]` `if(regex: "^(screen\s?shot\|cleanshot)") -> optimise -> move(to: "~/Pictures/Screenshots/%y/%m/")` |
| fit under 1 MB | `targetSize(size: 1MB)` |
| video to GIF | `[video]` `crop(longEdge: 800) -> convert(to: gif)` |
| pdf for sending | `[pdf]` `optimise(dpi: 150) -> targetSize(size: 10MB)` |

A preset can be run by name, or installed into the pipelines folder to edit and attach.

## Examples

| Goal | Pipeline |
|---|---|
| Images for the web | `optimise -> convert(to: webp)` |
| Fit under 10 MB | `targetSize(size: 10MB)` |
| 1080p video | `crop(width: 1920) -> optimise(encoder: slowHighQuality)` |
| Silent 2× screencast | `changeSpeed(factor: 2.0, frames: drop) -> removeAudio -> optimise(encoder: fast)` |
| 128k MP3 | `convert(to: mp3) -> lowerBitrate(kbps: 128)` |
| PDF pages as PNG | `extractPagesAsImages(format: png, quality: high)` |
| Watermark, then compress | `watermark(image: "%P/logo.png", position: bottomRight) -> optimise` |
| Only big photos | `if(types: jpeg heic, minFileSize: 2MB) -> crop(longEdge: 2048) -> optimise` |
| Keep originals, ship copies | `copy(to: "~/Outbox/") -> optimise(compression: 70)` |
| Rename by date | `rename(to: "%y-%m-%d %H.%M.%S")` |
| Social card | `crop(aspectRatio: 1.91:1, smartCrop: true) -> crop(width: 1200) -> convert(to: jpeg)` |
| Optimised original and a WebP | `optimise -> fork -> convert(to: webp)` |

## Coming from Clop

- The parser accepts Clop-style pipelines. Review unsupported formats and host actions
  before relying on identical behavior. The bundled tools do not include x265.
- esclop writes pipelines back in the form Clop reads, so a section copied out of a
  `.pipeline` file pastes into Clop (front matter, sections and comments are esclop's).
- Scripts get `$ESCLOP_BIN` and `$ESCLOP_INPUT_FILE`. A script using Clop's variable names parses
  with a warning that offers the rename.
- esclop additions: front matter, sections, comments, unnamed main arguments, `->` inside quotes,
  `durationGreaterThan` / `durationLowerThan`, `sourceFile` / `currentFile` in `delete`, and more
  `convert` formats (`tiff`, `bmp`, `mov`, `mkv`, `aac`, `opus`).
- Clop skips an argument it does not know; esclop reports it, with the closest known name.

## For developers and agents

The module is `EsclopPipelines`.

- `PipelineParser.parse(_:name:)`, `parseSteps(_:)`, `parseStep(_:)` and `check(_:)` (all
  diagnostics without throwing). Errors are `PipelineSyntaxError` with `PipelineDiagnostic`s
  (line, column, length, message, replacement); `.esclopError` bridges to the contract.
- `PipelineSerializer.serialize(_:)` for a pipeline, a step list or a step; `Pipeline.text`.
- `PipelineLanguage.steps` (each `StepSpec` has its signature, kinds, arguments with types,
  defaults and docs), `completions(in:at:kind:)` (UTF-16 offsets, the unit of `NSRange`),
  `describe(_:)` for prose, `referenceMarkdown()` for agents, `templateTokens`.
- `PipelineRunner(engine:host:inspector:commands:)` and `run(_:on:options:progress:)`, which
  returns a `PipelineRunReport` (Codable). `PipelineRunOptions` carries the origin and the
  permissions (`allowRunScripts`, `allowDelete`).
- `PipelineHost` is how the app performs clipboard, sharing, shelf, upload and fork steps.
  `NoopPipelineHost` skips them; `CommandLinePipelineHost` opens files and copies paths.
- Engines adopt `PipelineMediaOperations` for `lowerBitrate`, `capFps`, `normalize`,
  `watermark`, `extractPagesAsImages` and `changeSpeed(frames:)`. Without it, `removeAudio` and
  `changeSpeed` fall back to `optimise` with the matching request fields, and the others fail
  with a clear message.
- `PipelineStore` lists, loads, saves, renames, deletes, attaches and detaches; `resolve(_:)`
  reads a name or inline steps the way the CLI and MCP take them; `presets` and
  `preset(named:)` hold the built-ins.
