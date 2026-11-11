# Engines

`EsclopOptimisers` turns files into smaller files. Everything above it (the app, the CLI, the
MCP server, pipelines) uses `EsclopEngine`. GUI integration is planned; clipboard helpers and
automation settings below do not yet provide a working clipboard watcher.

For example:

```swift
import EsclopCore
import EsclopOptimisers

let engine = EsclopEngine()            // settings suite dev.esclop.app, bundled tools, shared backups
let request = OptimisationRequest(sources: [url], origin: .cli)
let result = try await engine.optimise(url, request: request) { progress in print(progress.fraction) }
print(result.output, result.bytesBefore, result.bytesAfter, result.steps)
```

## Public API

### `EsclopEngine` (EsclopOptimisers)

`OptimisationEngine` (Contracts.swift):

| Method | Does |
|---|---|
| `optimise(_:request:progress:)` | Everything the request asks for in one go: `format`, `crop`, `downscale`, `targetBytes` (switches to fit), `playbackSpeed`, `removeAudio`, `fpsCap`, `videoBitrateKbps`, `audioBitrateKbps`, `loudnessLUFS`, `pdfDPI`, `videoEncoder`, `keepHDR`, `quality`. |
| `convert(_:to:request:progress:)` | Same with `format` set. Larger results are accepted (the format is the intent). |
| `downscale(_:factor:request:progress:)` | `0 < factor <= 1`. A result that is not smaller throws `alreadySmaller`. |
| `crop(_:to:request:progress:)` | `CropSize`: width/height (crop to fill), `longEdge`, `aspectRatio` ("16:9", "1.5"), `smart` (Vision saliency picks the focus). PDFs crop their pages' crop box to the aspect ratio without recompressing. |
| `fit(_:underBytes:request:progress:)` | Lands at or under the size, or throws `.other("Could not fit ...")` with the smallest size reached. A file already under the target is returned untouched. |
| `stripMetadata(_:request:)` | Lossless where the format allows: images (engine or ImageIO), video/audio (`-c copy -map_metadata -1`), PDF (`pdf.optimise` at compression 0: no image touched, metadata stripped). |
| `supports(_:)` | Whether the extension is a kind and format the engines handle. |

Extra operations (pipelines reach them through `PipelineMediaOperations`, conformed in
`Sources/EsclopPipelines/EsclopEngine+PipelineMediaOperations.swift`):

| Method | Does |
|---|---|
| `removeAudio(_:request:progress:)` | Drops audio tracks without re-encoding the video. |
| `changeSpeed(_:factor:keepFrames:request:progress:)` | Video and audio. `keepFrames` nil follows `playbackSpeedFrameBehaviour`. |
| `capFrameRate(_:fps:request:progress:)` | Drops frames above `fps`. |
| `lowerBitrate(_:kbps:request:progress:)` | Video bitrate for videos, audio bitrate for audio files. |
| `normalizeLoudness(_:lufs:request:progress:)` | EBU R128 single pass, audio files and video soundtracks. |
| `watermark(_:image:position:opacity:scale:request:progress:)` | Images and videos. `scale` is the mark's width as a fraction of the picture's, 20 px from the edge. `WatermarkCorner`: bottomRight, bottomLeft, topRight, topLeft, center. |
| `cropPDF(_:aspectRatio:request:)`, `uncropPDF(_:request:)` | Crop box only, no recompression. |
| `extractPDFPages(_:format:dpi:to:)` | PNG or JPEG per page, returns the files in page order. |
| `imageEngineCapabilities()` | What `esclop-engine` reported in `hello`, nil when it is missing. |
| `EsclopEngine.pdfDPIStops` | `[300, 250, 200, 150, 100, 72, 48]`. |

`EsclopEngine(settings:tools:backups:imageEngine:workRoot:)` injects everything (tests, or an
app that wants one `EngineClient`).

### Request semantics

- **Quality.** `quality.tier == .custom` uses `quality.factor` (0...100, higher = smaller).
  `.normal` and `.aggressive` use the per-kind settings (`imageCompression`,
  `imageAggressiveCompression`, `videoCompression`, ...); the `useAggressiveOptimisation*`
  switches turn normal into aggressive per format.
- **Metadata** is stripped when `request.stripMetadata` or the `stripMetadata` setting is true
  (default true). Orientation and colour profile are always kept.
- **Automatic conversion** (`formatsToConvertToJPEG/PNG/MP4`) applies only to automatic origins:
  `.app`, `.clipboard`, `.dropZone`, `.watchedFolder`, `.hotkey`. CLI, MCP, Finder and Shortcuts
  keep the format unless asked. Audio's `formatsToConvertToAAC/MP3` apply to every origin.
- **Already smaller.** A pure optimise or downscale whose output is not smaller throws
  `EsclopError.alreadySmaller` and leaves the file alone. Conversions, crops, speed changes,
  watermarks and loudness changes accept larger output.
- **Location.** `.inPlace` backs up the original first; with a new extension the converted file
  replaces the original (`photo.heic` becomes `photo.jpeg`). Same-format results keep the
  source's extension (`.jpg` stays `.jpg`). `.sameFolder` uses `sameFolderNameTemplate`
  (`%f-optimised`) and never overwrites. `.temporary` writes under `Paths.temporary/results`.
  `.path(template)` expands `%f` (name), `%e` (output extension), `%d` (source folder), `~`;
  a trailing `/` or an existing folder receives `<name>.<ext>`. A template that resolves to the
  source itself counts as in place (backup, agent permission). Any other existing file about to
  be overwritten, whatever the location, is backed up first; if that backup fails, nothing is
  written. Results are staged next to the destination so the final swap never crosses volumes.
- **Agents.** A request with `origin == .mcp` that would overwrite its source (`.inPlace`, or a
  template resolving to it) throws `notPermitted` unless `allowOverwriteOriginals` is on. The other agent switches (`allowDeleteBackups`,
  `allowRunScripts`, `allowSettingsChanges`) are for the MCP server and pipelines to enforce.
- **Results.** `output`, `backup` (the copy in `Paths.backups`), `kind` (of the output: a video
  turned GIF is an image), sizes, `width`/`height`/`duration` when known, and `steps`, a
  readable log ("Resized to 160x90", "Encoded JPEG at quality 85").
- **Progress.** 0 at the start, 1 at the end, fractions in between from ffmpeg's `-progress`
  and the engine's progress events.

### What runs where

| Input → output | Tool |
|---|---|
| PNG, JPEG, WebP, AVIF (optimise, convert, resize, crop, fit, strip) | `esclop-engine` |
| HEIC, JPEG XL, AVIF, TIFF, BMP inputs | decoded by ImageIO to PNG for the engine |
| HEIC, TIFF, BMP outputs | ImageIO |
| JPEG/HEIC with an HDR gain map (`keepHDR`) | ImageIO (same size), Core Image (resized, macOS 15+) |
| GIF to GIF | gifsicle |
| Video | ffmpeg: `h264_videotoolbox`/`hevc_videotoolbox` (q:v; with `-allow_sw` and a bitrate as fallback), `libsvtav1`, `libvpx-vp9` + `libopus` for WebM |
| Video to GIF | ffmpeg frames + `esclop-engine gif.from_frames` (gifski); ffmpeg palette + gifsicle when the engine cannot |
| Animated GIF to MP4/WebM/MOV | ffmpeg |
| Audio | ffmpeg: `aac_at` (falls back to `aac`), `libmp3lame` VBR, `libopus`, FLAC, PCM |
| PDF | esclop-engine `pdf.optimise` (30 min at most from when a worker starts it; signed, Reader-extended, password-protected and damaged files, encrypted ones over 64 MB, and ones that would need more than 256 MB besides their own size, are left as they are, with the reason as the message); PDFKit for crop/uncrop/pages; images become PDFs with PDFKit |

## Image engine client

`EngineClient` (actor) keeps one `esclop-engine serve` child per client (`EngineClient.shared`
by default) and implements `docs/engine-protocol.md`:

- Requests carry string ids `"1"`, `"2"`...; replies may come in any order.
- `capabilities()` sends `{"id":..,"op":"hello"}` and accepts the reply wrapped
  (`{"id","ok":true,"result":{version,ops,features}}`) or bare (`{version,ops,features}`).
  Formats the engine can write are read from `features.encode` (or `features.formats`), else
  inferred from the ops. Image work checks `canEncode(format)` and `supports(op)` first and
  throws `unsupportedFile("esclop-engine <version> cannot write WEBP yet")` instead of guessing.
- A bare hello reply (no id) answers only a pending hello, the oldest first. An engine that does
  not answer hello within 15 seconds fails the call instead of hanging it.
- Task cancellation resolves the call with `.cancelled` at once and sends `{"id","op":"cancel"}`.
- If the child exits, its requests in flight fail; the next call starts a new child and each
  failed request is retried once. Three crashes within 30 seconds stop restarts for that window
  (`shutdown()` does not count).
- Error codes map to `EsclopError`: `unsupported` → `unsupportedFile`, `not_found` →
  `fileNotFound`, `already_smaller` → `alreadySmaller`, `invalid_params` → `invalidArgument`,
  `cancelled` → `cancelled`, anything else → `toolFailed(tool: "esclop-engine", ...)`.

Ops and parameters the Swift side sends:

| Op | Params sent | When |
|---|---|---|
| `png.optimise` | `lossy`, `quality` [0, max], `speed`, `strip` | PNG output |
| `jpeg.optimise` | `quality`, `progressive: true`, `strip` | JPEG to JPEG |
| `convert` | `format` (png, jpeg, gif, jxl), `quality`, `progressive`, `strip` | other inputs to PNG/JPEG/GIF/JXL |
| `webp.encode` | `quality`, `lossless: false`, `strip` | WebP output |
| `avif.encode` | `quality`, `speed` (6, or 4 at factor >= 60), `strip` | AVIF output |
| `crop` | `x`, `y`, `width`, `height` (displayed pixels, orientation applied), `format: "png"` | crops, before encoding |
| `resize` | `width`, `height`, `format: "png"` | scaling, before encoding |
| `fit` | `target_bytes`, `min_quality: 10`, `allow_resize: true`, `format`, `strip` | fit, when the engine lists it |
| `metadata.strip` | `keep: ["icc", "orientation"]` | strip PNG/JPEG/WebP |
| `gif.from_frames` | `fps`, `quality` (90, 60 when aggressive), `width`, `frames_dir` | video to GIF |

Geometry runs on lossless PNG intermediates so only the final encode is lossy. Files with an
EXIF orientation are decoded upright by ImageIO before a crop, so rectangles mean the same on
both sides.

## Fit under size

| Kind | Search |
|---|---|
| Image | The engine's `fit` op when it lists it. Otherwise `FitSearch`: the normal factor; if too big, factor 100; if that fits, binary search for the gentlest factor that fits; if not, keep factor 70 and binary search the scale from the estimate `sqrt(target / size)`. About ten encodes at most. |
| Video | Bitrate from the duration (92% of the budget, audio 12% capped at 96 kbit/s, audio dropped when under 80 kbit/s is left), frames scaled down when the budget falls under 0.04 bits per pixel, VideoToolbox with up to three bitrate corrections, then SVT-AV1 the same way. |
| Audio | The highest allowed bitrate under the budget, then each lower step. Lossless sources go to AAC. |
| PDF | `pdf.optimise` at each DPI stop from the resolved one down to 48. |

## Settings

Defined in `Sources/EsclopCore/SettingsCatalog.swift` (`EsclopSettings`), listed by
`SettingsRegistry.shared`, stored in the `dev.esclop.app` defaults suite as plist primitives
(enums as their raw string). The CLI and MCP use:

```swift
let registry = SettingsRegistry.shared
try registry.get("imageCompression")                 // JSONValue
try registry.set("imageCompression", to: .int(40))   // validated: type, minimum/maximum, enum
try registry.set("formatsToConvertToJPEG", text: "webp,avif")   // command-line text
registry.schema()                                    // JSON Schema 2020-12 object for every key
registry.search("strip")                             // the Settings window search
registry.register(Setting<Bool>(...))                // other modules add their own
```

Swift code reads typed values: `EsclopSettings.stripMetadata.value` (or `.value(in: store)`).

| Key | Type | Default | Section | Title |
|---|---|---|---|---|
| `stripMetadata` | Bool | `true` | general | Strip metadata |
| `preserveDates` | Bool | `true` | general | Keep file dates |
| `keepHDR` | Bool | `true` | general | Keep HDR |
| `presetZones` | [String] | `[]` | interface | Preset zones |
| `imageCompression` | Int | `30` | images | Image compression |
| `imageAggressiveCompression` | Int | `64` | images | Aggressive image compression |
| `useAggressiveOptimisationJPEG` | Bool | `false` | images | Always optimise JPEG aggressively |
| `useAggressiveOptimisationPNG` | Bool | `false` | images | Always optimise PNG aggressively |
| `useAggressiveOptimisationGIF` | Bool | `false` | images | Always optimise GIF aggressively |
| `adaptiveImageSize` | Bool | `false` | images | Adaptive image format |
| `formatsToConvertToJPEG` | [String] | `[webp, avif, heic, bmp]` | images | Convert to JPEG |
| `formatsToConvertToPNG` | [String] | `[tiff]` | images | Convert to PNG |
| `downscaleFactor` | Double | `0.5` | images | Default downscale factor |
| `downscaleRetinaImages` | Bool | `false` | images | Downscale Retina screenshots |
| `maxImageSizeMB` | Int | `50` | images | Largest image to optimise automatically |
| `minImageSizeKB` | Int | `50` | images | Smallest image to optimise automatically |
| `videoCompression` | Int | `50` | video | Video compression |
| `videoAggressiveCompression` | Int | `70` | video | Aggressive video compression |
| `videoEncoder` | VideoEncoder | `h264_videotoolbox` | video | Video encoder |
| `useAggressiveOptimisationMP4` | Bool | `false` | video | Always optimise video aggressively |
| `formatsToConvertToMP4` | [String] | `[mov, mpeg, mpg, webm, avi]` | video | Convert to MP4 |
| `capVideoFPS` | Bool | `true` | video | Cap frame rate |
| `targetVideoFPS` | Double | `60` | video | Target frame rate |
| `minVideoFPS` | Double | `30` | video | Minimum frame rate |
| `removeAudioFromVideos` | Bool | `false` | video | Remove audio from videos |
| `convertAudioToAAC` | Bool | `false` | video | Re-encode soundtracks to AAC |
| `playbackSpeedFrameBehaviour` | PlaybackSpeedFrames | `.keepFrames` | video | Speed change frames |
| `maxVideoSizeMB` | Int | `500` | video | Largest video to optimise automatically |
| `minVideoSizeKB` | Int | `200` | video | Smallest video to optimise automatically |
| `gifMaxWidth` | Int | `720` | video | GIF width |
| `gifFPS` | Int | `15` | video | GIF frame rate |
| `pdfDPI` | Int | `0` | pdf | PDF image resolution |
| `useAggressiveOptimisationPDF` | Bool | `false` | pdf | Always optimise PDF aggressively |
| `maxPDFSizeMB` | Int | `100` | pdf | Largest PDF to optimise automatically |
| `audioCompression` | Int | `35` | audio | Audio compression |
| `audioAggressiveCompression` | Int | `65` | audio | Aggressive audio compression |
| `formatsToConvertToAAC` | [String] | `[aiff, aif, flac]` | audio | Convert to AAC |
| `formatsToConvertToMP3` | [String] | `[wav]` | audio | Convert to MP3 |
| `audioCoverArt` | AudioCoverArt | `.optimise` | audio | Cover art |
| `normalizeLoudness` | Bool | `false` | audio | Normalise loudness |
| `loudnessTarget` | Double | `-16` | audio | Loudness target |
| `maxAudioSizeMB` | Int | `100` | audio | Largest audio file to optimise automatically |
| `optimisedImageBehaviour` | FileBehaviour | `.inPlace` | output | Optimised images go |
| `optimisedVideoBehaviour` | FileBehaviour | `.inPlace` | output | Optimised videos go |
| `optimisedPDFBehaviour` | FileBehaviour | `.inPlace` | output | Optimised PDFs go |
| `optimisedAudioBehaviour` | FileBehaviour | `.inPlace` | output | Optimised audio goes |
| `convertedImageBehaviour` | FileBehaviour | `.sameFolder` | output | Converted images go |
| `convertedVideoBehaviour` | FileBehaviour | `.inPlace` | output | Converted videos go |
| `convertedAudioBehaviour` | FileBehaviour | `.inPlace` | output | Converted audio goes |
| `sameFolderNameTemplate` | String | `%f-optimised` | output | Same folder name |
| `specificFolderTemplate` | String | `%d/optimised/%f` | output | Specific folder path |
| `backupRetentionDays` | Int | `7` | backups | Keep backups for |
| `enableClipboardOptimiser` | Bool | `true` | clipboard | Optimise copied images |
| `optimiseVideoClipboard` | Bool | `false` | clipboard | Optimise copied videos |
| `optimisePDFClipboard` | Bool | `false` | clipboard | Optimise copied PDFs |
| `optimiseAudioClipboard` | Bool | `false` | clipboard | Optimise copied audio |
| `optimiseImagePathClipboard` | Bool | `false` | clipboard | Optimise copied image paths |
| `clipboardIgnoredAppBundleIds` | [String] | `[]` | clipboard | Ignored apps |
| `clipboardRules` | [String] | `[]` | clipboard | Clipboard rules |
| `autoCopyToClipboard` | Bool | `true` | clipboard | Copy results to the clipboard |
| `pauseAutomaticOptimisations` | Bool | `false` | automation | Pause automatic optimisation |
| `enableAutomaticImageOptimisations` | Bool | `true` | images | Watch folders for images |
| `enableAutomaticVideoOptimisations` | Bool | `true` | video | Watch folders for videos |
| `enableAutomaticPDFOptimisations` | Bool | `true` | pdf | Watch folders for PDFs |
| `enableAutomaticAudioOptimisations` | Bool | `false` | audio | Watch folders for audio |
| `imageDirs` | [String] | `[~/Desktop]` | images | Screenshot folders |
| `videoDirs` | [String] | `[~/Desktop]` | video | Recording folders |
| `pdfDirs` | [String] | `[]` | pdf | PDF folders |
| `audioDirs` | [String] | `[]` | audio | Audio folders |
| `maxImageFileCount` | Int | `4` | images | Most new images at once |
| `maxVideoFileCount` | Int | `1` | video | Most new videos at once |
| `maxPDFFileCount` | Int | `2` | pdf | Most new PDFs at once |
| `maxAudioFileCount` | Int | `2` | audio | Most new audio files at once |
| `allowOverwriteOriginals` | Bool | `false` | agents | Agents may overwrite originals |
| `allowDeleteBackups` | Bool | `false` | agents | Agents may delete backups |
| `allowRunScripts` | Bool | `false` | agents | Agents may run scripts |
| `allowSettingsChanges` | Bool | `false` | agents | Agents may change settings |
| `checkForUpdatesAutomatically` | Bool | `true` | updates | Check for updates automatically |
| `installUpdatesAutomatically` | Bool | `false` | updates | Download and install updates automatically |

## Tools

`Tool` lists the four executables: `esclop-engine`, `ffmpeg`, `ffprobe`, `gifsicle`.
`ToolLocator` searches `$ESCLOP_BIN`, `<app>/Contents/Resources/bin`, a checkout's `Binaries/`
(from `Scripts/build-tools.sh`) and `engine/target/release/`, then PATH plus `/opt/homebrew/bin`
and `/usr/local/bin`. A missing tool throws `EsclopError.toolMissing("<name>")`.
`ProcessRunner.run(.ffmpeg, args, options:)` runs one; children get `ESCLOP_BIN`.
A timeout counts from the start of the call and a cancellation kills the child (SIGTERM, SIGKILL
two seconds later); neither waits for anything else in the process. The call ends when the child
has exited and its pipes are drained, or `drainGrace` (2 s) after it exited when a descendant
keeps them open. Timers and completion run on a private serial queue per child, never on
`DispatchQueue.global()`, which CPU-bound Swift tasks can starve. `acceptsAnyExitCode` returns every status instead of throwing.

ffmpeg must provide: `h264_videotoolbox`, `hevc_videotoolbox`, `libsvtav1`, `libvpx-vp9`,
`libopus`, `libmp3lame`, `aac`/`aac_at`, `flac`, `pcm_*`, `adpcm_ima_wav`, `mjpeg` (cover art),
`png`, `gif`; filters `scale`, `crop`, `fps`, `setpts`, `atempo`, `loudnorm`, `aresample`,
`palettegen`, `paletteuse`, `split`, `overlay`, `colorchannelmixer`, `format`; and `lavfi` with
`testsrc2`/`sine` for the test fixtures. No x264 or x265 is needed.

## Backups and markers

`BackupStore.shared` (`~/Library/Application Support/esclop/backups/<id>/`) holds a copy of
every original overwritten in place, with `manifest.json` (original, backup, output, request id,
date, bytes). `restore(_:)` puts the original back (and trashes a converted output with a
different name); `prune(olderThan:)` applies `backupRetentionDays`. Outputs carry the
`dev.esclop.optimised` extended attribute (`OptimisedMark`), and pasteboard writes carry the
`dev.esclop.optimised` type (`Clipboard.isOwnWrite`).

## Clipboard

`Clipboard.read(_:)` returns `.files`, `.image(data, type)` (GIF first, then PNG, JPEG, HEIC,
WebP, TIFF), `.base64Image` (`data:image/...;base64,` text), `.path` (text naming an existing
file) or `.empty`. `materialise(_:)` saves image data to files; `write(files:)`,
`write(image:type:)` and `write(_ result:)` put results back.

## Tests

`Scripts/test.sh`. Fixtures are generated at test time (ImageIO, Core Graphics, ffmpeg
`lavfi`). Image tests run against `Tests/FakeEngine/fake-esclop-engine.swift`, compiled once per
run with `swiftc`: an ImageIO stand-in that speaks the protocol (it writes PNG, JPEG, GIF and
AVIF, not WebP, which exercises the capability checks). `RealEngineTests` runs when a real
`esclop-engine` is found. Video and audio suites are skipped when ffmpeg is missing, and the PDF suite when
`esclop-engine` is.
