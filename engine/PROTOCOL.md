# esclop-engine protocol (v1)

This is the authoritative contract between `esclop-engine` and its clients (the Swift
`EsclopEngine` in EsclopOptimisers, the CLI, scripts). `docs/engine-protocol.md` is the short
version; when they differ, this file wins. Machine-readable JSON Schemas live in
[`schema/`](schema/) and are generated from the Rust types (`esclop-engine schema schema`); a
test fails when they drift.

## Transport

`esclop-engine serve [--workers N]` reads one JSON object per line on stdin and writes one JSON
object per line on stdout. stderr carries logs only (`ESCLOP_ENGINE_LOG=debug` for more). Every
request gets exactly one response line (except `cancel`), preceded by zero or more progress
lines. Requests run concurrently on a fixed pool of `N` workers (default: half the cores,
1 to 4; `ESCLOP_ENGINE_WORKERS` also sets it); the rest wait in arrival order. Responses can
arrive out of order: match them by `id`. On end of input the engine finishes the requests it
has, answers them and exits with status 0.

One-shot form for scripts and debugging:

```
esclop-engine <op> --json '{"input":"/abs/in.png","output":"/abs/out.png","params":{...}}'
esclop-engine <op> --json '{"input":"in.png","output":"out.png","lossy":true}'   # params inline
esclop-engine <op> --json - < request.json                                         # from stdin
```

prints the response line and exits 0 on `ok`, 1 on error, 2 on usage errors. `--progress`
prints progress lines on stderr. The one-shot form resolves relative paths against the
working directory; `serve` requires absolute paths.

### Request

```json
{"id": "42", "op": "png.optimise", "input": "/abs/in.png", "output": "/abs/out.png", "params": {"compression": 30}}
```

| field | | |
|---|---|---|
| `id` | string (numbers are echoed back as given) | ties responses and progress to the request. Must be unique among requests in flight; a duplicate gets `invalid_params`. |
| `op` | string | one of the ops below |
| `input` | absolute path | not used by `hello`, `cancel`, `gif.from_frames` |
| `output` | absolute path | may equal `input` only with `params.in_place: true`, and may then be omitted. Not used by `probe`. |
| `params` | object | per op. Unknown keys are not an error: they are listed in `result.ignored_params`. |

### Responses

```json
{"id":"42","ok":true,"result":{"bytes_before":120400,"bytes_after":41230,"width":1200,"height":800,"format":"png","output":"/abs/out.png","quality":97,"lossy":true}}
{"id":"43","ok":false,"error":{"code":"unsupported","message":"not a PNG"}}
{"id":"42","event":"progress","fraction":0.4,"stage":"quantise"}
```

- Every success carries `bytes_before`, `bytes_after`, `width`, `height` (of the output, in
  stored pixels) and `format` (of the output). Ops that write also return `output` and `lossy`
  (whether any pixel changed). Optional fields: `quality`, `scale`, `fitted`, `backend`,
  `frames`, `ignored_params`, `probe`. Schema: `schema/result.schema.json`.
- Progress `fraction` is in 0..=1 and only increases for a given request; events are throttled
  (at most one per 100 ms unless the fraction moved 5 %). `stage` is a short machine name
  (`decode`, `quantise`, `compress`, `encode`, `transcode`, `search`, `gifsicle`, `write`).
- `hello` answers in the same envelope: `{"id":…,"ok":true,"result":{"version","protocol","ops","features"}}`.

### Errors

| code | meaning | anything written? |
|---|---|---|
| `unsupported` | format or op not handled (HEIC/AVIF/JXL input, `png.optimise` on a JPEG, unknown op, image over 256 MP) | no |
| `not_found` | input missing, or output folder missing | no |
| `decode` | corrupt or truncated input | no |
| `encode` | an encoder failed | no |
| `io` | reading or writing failed | no |
| `already_smaller` | the result would not be smaller than the input (optimise ops), or `fit`'s input already fits | no |
| `invalid_params` | malformed request, out-of-range params, `output == input` without `in_place` | no |
| `cancelled` | cancelled before it finished | no |
| `internal` | an engine bug (a caught panic); logged on stderr | no |

`message` is for people and agents, never parsed.

### Cancel

`{"id":"42","op":"cancel"}` asks the engine to stop request `42`. It has **no response of its
own**: request `42` then answers `cancelled` (or its normal result if it finished first). A
queued request is dropped before it starts. Cancellation is checked between stages, between
quantisation steps, between `fit` probes, between GIF frames, and kills a running gifsicle;
a single libaom (AVIF) or mozjpeg encode runs to its end before the check.

### Files

- Outputs are written to a temporary file in the output folder (`.<name>.<random>.esclop-tmp`)
  and renamed into place: readers never see a partial file, and failures leave nothing behind.
- New files get the input's permissions. In-place writes also keep the input's creation date
  and extended attributes (Finder tags, "where from"), and write through symlinks to their
  target.
- The engine never opens a network connection and never runs anything except gifsicle.
- Output is deterministic: the same input and params give the same bytes.

## Compression factor and quality mapping

Every lossy op takes `compression`, 0..=100, higher is smaller (the slider in the app, the
`CompressionQuality.factor` in `EsclopCore`). **30 is "normal"** (visually lossless for the usual
screenshot or photo) and **64 is "aggressive"**: the same anchors Clop 3.5 uses, with the same
curves, so the same factor gives comparable files. Explicit encoder params (`quality`, `lossy`,
`colors`, `speed`) always win over the factor. Default: 30.

| factor | JPEG ceiling | PNG quality (imagequant) | PNG speed | PNG colours | GIF (gifsicle) | WebP q | AVIF q |
|--:|--:|---|--:|--:|---|--:|--:|
| 0 | 95 | 0-100 | 4 | 256 | -O1 --lossy=0 | 75 | 75 |
| 30 | **85** | 0-100 | 4 | 256 | -O2 --lossy=30 | **60** | **60** |
| 50 | 69 | 0-79 | 3 | 256 | -O3 --lossy=59 --colors=256 | 50 | 50 |
| 64 | **58** | 0-64 | 2 | 256 | -O3 --lossy=80 --colors=202 | **43** | **43** |
| 80 | 42 | 0-46 | 2 | 224 | -O3 --lossy=251 --colors=141 | 32 | 32 |
| 100 | 18 | 0-25 | 1 | 64 | -O3 --lossy=2000 --colors=64 | 15 | 15 |

Formulas (Swift's `.rounded()`, half away from zero):

- JPEG ceiling: `f ≤ 70 ? 85 − (f−30)·55/70 : 54 − (f−70)·36/30`, clamped 18..95.
- PNG target quality: `100 − (f−30)·75/70`, clamped 25..100, minimum 0. Colours: 256 below 80,
  then `224 − (f−80)·8` clamped 64..256. Speed: 4 below 40, 3 below 60, 2 below 85, else 1.
- GIF: level `f ≥ 50 ? 3 : f ≥ 20 ? 2 : 1`; lossy `f ≤ 70 ? 30 + (f−30)·50/34 : 89·(2000/89)^((f−70)/30)`;
  colours from 50 up: `256 − (f−50)·192/50` clamped 32..256.
- WebP: `f ≤ 70 ? 75 − f/2 : 40 − (f−70)·25/30`, clamped 15..90.
- AVIF: the WebP value, on **heif-enc's scale** (Clop runs `heif-enc --avif -q` with it). The
  libaom codec translates it to the libavif quality that gives libaom the same quantizer as
  libheif does (60 → 52, 43 → 33; table in `codec/avif_aom.rs`; the two encoders' files then
  match within 0.1 %). The rav1e codec maps it through its own calibration
  (`bench/calibrate_avif.py`).

JPEG qualities (the ceiling here, `quality` params, `fit`'s range, `probe`'s estimate) are on the
**libjpeg/jpegoptim scale** Clop's curves were tuned on. mozjpeg's trellis quantisation needs a
higher internal number to look the same, so the codec translates (85 → 90, 58 → 68; table in
`codec/jpeg.rs`, made by `bench/calibrate_jpeg.py`): at equal SSIMULACRA2 the files come out
smaller than jpegoptim's.

The JPEG value is a **ceiling**, like jpegoptim `--max`: the engine estimates the input's
quality from its luminance quantisation table (against both the IJG and mozjpeg base tables)
and re-encodes only when it is above the ceiling; otherwise it recompresses losslessly. A file
the engine wrote at 85 estimates as 85, so optimising twice never degrades a photo.

## Metadata

`strip: true` removes EXIF, XMP, IPTC, comments, text chunks, GIF comments/application blocks
and C2PA, and keeps what `keep` lists: default `["icc", "orientation"]` (what Clop keeps),
`[]` keeps nothing. Orientation is kept as a minimal EXIF block holding only that tag. PNG
`pHYs` (density) and decoding-critical data (JFIF, Adobe APP14, `tRNS`, APNG chunks) always stay.
Without `strip`, metadata is carried across re-encodes: JPEG markers to JPEG, ICC and EXIF to
PNG (`iCCP`, `eXIf`), WebP (`ICCP`, `EXIF`) and AVIF (ICC and EXIF; EXIF only with rav1e). Two things are always dropped
on a rewrite: JPEG MPF indexes with their secondary images (HDR gain maps, depth maps: route
those to ImageIO, `probe` reports `multi_picture`), and Apple's PNG `iDOT`, whose offsets a
rewrite invalidates.

Geometry ops (`resize`, `crop`, `fit`) and conversions to non-JPEG formats apply the EXIF
orientation to the pixels and write orientation 1, so every viewer shows the same thing.
`jpeg.optimise`, `metadata.strip` and JPEG-to-JPEG `convert` keep the stored orientation.

## Shared params

Output params, accepted by every op that writes:

| param | type | default | |
|---|---|---|---|
| `in_place` | bool | false | allow `output == input` (see Files) |
| `strip` | bool | false | see Metadata |
| `keep` | `["icc","orientation"]` subset | both | what `strip` keeps |
| `allow_larger` | bool | false for `*.optimise`, true otherwise | write even when not smaller |

Encode params, accepted by `convert`, `resize`, `crop` (the knobs that do not apply to the
target format are ignored):

| param | formats | |
|---|---|---|
| `compression` | all | factor 0..=100 (default 30) |
| `quality` | all | encoder quality 0..=100; png: imagequant target; gif: palette quality |
| `lossy` | png | quantise (default true) |
| `lossless` | webp | (default false) |
| `progressive` | jpeg | (default true) |
| `speed` | png 1..=10, avif 1..=10 (default 6) | |
| `colors` | png, gif | palette cap 2..=256 |
| `method` | webp | libwebp method 0..=6 (default 4) |

## Ops

### `hello`
No params. Result: `version` (semver), `protocol` (1), `ops` (this list), `features`:
`decode` (`png, jpeg, gif, webp, tiff, bmp`), `encode` (`png, jpeg, webp, avif, gif`),
`jpeg_codec` (`mozjpeg`), `avif_encoder` (e.g. `"libaom 3.15.3 (tune=iq)"`, or null when the
build has no AVIF encoder: then `encode` omits `avif` and the client encodes AVIF itself),
`gifsicle` (path or null), `workers`, `compression_normal` (30),
`compression_aggressive` (64), `capabilities` (`cancel`, `progress`, `in_place`,
`ignored_params`). Swift should read this instead of assuming.

### `probe`
No params, no output. Result adds `probe`: `decodable`, `color_space` (`rgb`, `gray`,
`indexed`, `cmyk`, `ycck`), `bit_depth`, `has_alpha`, `has_exif`, `has_icc`, `has_xmp`,
`orientation` (1..=8), `display_width`/`display_height` (after orientation), `frames`,
`animated`, and for JPEG `jpeg_quality` (estimate), `progressive`, `multi_picture`. HEIC, AVIF
and JPEG XL are recognised (`format`) with `decodable: false` and zero dimensions; decode them
with ImageIO.

### `png.optimise`
| param | | |
|---|---|---|
| `lossy` | bool, default true | imagequant palette, then oxipng |
| `quality` | `[min, max]` 0..=100 | default `[0, factor curve]` |
| `speed` | 1..=10 | imagequant speed |
| `colors` | 2..=256 | |
| `dither` | 0..=1, default 1 | Floyd–Steinberg level |
| `level` | 0..=6 | oxipng effort; default from `compression`: 0 below 50, 1 below 85, else 2 |
| `compression` + output params | | |

Falls back to lossless oxipng when the palette misses `quality[0]` or comes out bigger than
the lossless result. Animated PNGs are always optimised losslessly. `result.quality` is the
quality imagequant reached; `lossy: false` means the lossless path won.

### `jpeg.optimise`
| param | | |
|---|---|---|
| `quality` | 0..=100 or `null` | ceiling (see mapping); `null` = lossless only. Absent: from `compression`. |
| `progressive` | bool, default true | |
| `compression` + output params | | |

mozjpeg (trellis quantisation, optimised progressive scans) for re-encodes; coefficient-level
transcoding (pixels untouched) otherwise. CMYK/YCCK files are only transcoded. Whichever
candidate is smaller wins.

### `webp.encode`
`quality`, `lossless`, `method`, `compression` + output params. From any decodable input;
animated GIF/WebP/APNG input stays animated. libwebp with `sharp_yuv` (as cwebp `-sharp_yuv`)
up to 16 megapixels; above that sharp YUV's buffers alone would exceed the memory budget.

### `avif.encode`
`quality` (heif-enc's scale), `speed` (1..=10, default 6, as heif-enc), `compression` + output
params. From any decodable still input; animations use the first frame.

The default build uses libaom through libavif, set up as Clop's heif-enc runs the same libaom:
4:2:0, 8 bit, sRGB signalling (CICP 1/13/6, full range), no AV1 tiles, and `tune=iq` (libaom's
still-image tuning, 3.12+; without it the same libaom needs ~1.5x the bytes for the same
SSIMULACRA2). Alpha, ICC profiles and EXIF are written. Images above 12 megapixels with even
sides are written as an AVIF grid of independently coded cells of about 6 MP (MIAF grid, read by
every AVIF decoder): peak memory on 24 MP falls from ~420 MB to ~225 MB for ~0.3 % in size.
Release builds link libaom 3.15.3 (`Scripts/build-libaom.sh`); a plain `cargo build` links the
older libaom the libaom-sys crate bundles, without `tune=iq`, and says so in
`hello.features.avif_encoder`. `--no-default-features --features avif-rav1e` builds the
pure-Rust rav1e codec instead (4:4:4, EXIF only, ~1.5-2x larger files). A build with neither
answers `unsupported`.

### `gif.optimise`
| param | | |
|---|---|---|
| `lossy` | 0..=200 | gifsicle `--lossy` |
| `colors` | 2..=256 | |
| `level` | 1..=3 | gifsicle `-O` |
| `backend` | `auto` (default), `gifsicle`, `builtin` | |
| `compression` + output params | | |

`auto` runs gifsicle when it finds it (`$ESCLOP_BIN/gifsicle`, next to the engine executable,
then `PATH`; `ESCLOP_NO_GIFSICLE=1` hides it) with Clop's arguments, else the built-in
optimiser: frames stored as the changed rectangle only, unchanged pixels transparent,
identical frames merged, exact palettes when they fit and imagequant (no dithering) when not;
`lossy` becomes a colour tolerance of `lossy/10` per channel against what is on screen.
gifsicle is GPL-2.0-only and only ever runs as a separate process. `result.backend` says
which ran.

### `gif.from_frames`
| param | | |
|---|---|---|
| `frames_dir` | absolute path (or `input`) | PNG frames, taken in file-name order |
| `fps` | (0, 100], default 10 | |
| `quality` | 1..=100, default 90 | gifski quality |
| `width`, `height` | | maximum size; height follows the aspect ratio when only width is given |
| `repeat` | 0 = forever | |
| `fast` | bool | |
| output params | | `bytes_before` is the total size of the frames |

gifski; frames are decoded and fed one at a time.

### `resize`
Exactly one of `scale` (0 < s ≤ 4), `long_edge`, or `width`/`height` (both: fit inside the
box). `only_shrink` (default true) never enlarges. `filter`: `nearest`, `box`, `bilinear`,
`hamming`, `catmull_rom`, `mitchell`, `lanczos3` (default). `format` (default: the input's;
TIFF/BMP become PNG), plus encode and output params. Sizes are in displayed pixels. Animated
GIF/WebP stay animated when the output format can hold them. `result.scale` is the factor
applied.

### `crop`
1. `x`, `y`, `width`, `height`: that rectangle (must lie inside the image).
2. `aspect` (`"16:9"`, `"4/3"`, or a number) with `gravity` (`center` default, `top`,
   `bottom`, `left`, `right`, `top_left`, `top_right`, `bottom_left`, `bottom_right`) or `smart`:
   the largest rectangle of that aspect. With `width` and/or `height` too, scaled to that size.
3. `width` and `height` alone: crop to their aspect, then scale to exactly that size ("crop to
   size").

`smart` is a rectangle `{x, y, width, height}` (Vision saliency from the Swift side): the crop
is centred on it as far as the image allows, and `gravity` is ignored. Coordinates are in
displayed pixels. `format` plus encode and output params as for `resize`.

### `metadata.strip`
`keep` (default `["icc", "orientation"]`), `in_place`, `allow_larger` (default true). JPEG,
PNG, WebP and GIF; pixels and compressed data are copied byte for byte.

### `convert`
`format` (required: `png`, `jpeg`, `webp`, `avif`, `gif`) plus encode and output params.
Decodes PNG, JPEG, GIF, WebP, TIFF, BMP. Transparency becomes white in JPEG. Animated input
to WebP or GIF stays animated; to the other formats the first frame is used.

### `fit`
| param | | |
|---|---|---|
| `target_bytes` | > 0, required | |
| `min_quality` | default 10 | lowest encoder quality tried |
| `max_quality` | default 95 | for JPEG input to JPEG, at most the input's own quality |
| `allow_resize` | default true | downscale when `min_quality` is not enough |
| `min_scale` | (0, 1], default 0.1 | |
| `format` | default: the input's | |
| `lossy`, `speed` + output params | | |

Binary search over quality at full size; when even `min_quality` is too big, the largest scale
that fits at `min_quality` (area estimate, then bisection), then the best quality at that scale.
Every probe encodes from the decoded original. Result: `quality` and `scale` chosen, `fitted`
(false: nothing fit, the output is the smallest reached), `width`/`height`. When the input is
already within the target in the same format: `already_smaller`.

## Limits

Inputs over 2 GiB or 256 megapixels: `unsupported`. JPEG ≤ 65500 px per side, WebP ≤ 16383,
GIF ≤ 65535. Peak memory on a 24-megapixel JPEG stays under 300 MB for every op (AVIF ~225 MB
through grids; Clop's heif-enc needs ~520 MB on the same image); see `bench/README.md`. On macOS the engine re-executes itself once at start with
`MallocLargeCache=0`, because the allocator's cache of freed large blocks otherwise grows with
every differently sized image a long-running `serve` handles.

## Versioning

`protocol` changes only for incompatible changes; additions (params, result fields, ops) keep
it and show up in `hello`. Clients must ignore result fields they do not know.
