# esclop-engine protocol

`esclop-engine` is a Rust executable shipped in `Contents/Resources/bin` next to ffmpeg and
gifsicle. It does the image and PDF work (PNG, JPEG, WebP, AVIF, GIF frames, PDF, resize, crop, metadata,
probe). It uses Rust libraries and vendored C codecs in a separate process, isolating decoder
crashes from the Swift caller.

The Swift `EsclopEngine` (EsclopOptimisers) talks to it through `ProcessRunner`. This page is
the summary; **`engine/PROTOCOL.md` is authoritative** (full params, results, error semantics,
quality mapping) and `engine/schema/` holds the generated JSON Schemas.

## Transport

`esclop-engine serve` reads one JSON object per line on stdin and writes one JSON object per
line on stdout. stderr is for logs only. Requests are independent and may be answered out of
order; `id` ties them together. One-shot form for scripts and debugging:
`esclop-engine <op> --json '<params>'` prints the response and exits.

```
→ {"id":"1","op":"png.optimise","input":"/path/in.png","output":"/path/out.png","params":{"lossy":true,"quality":[65,90],"speed":3}}
← {"id":"1","event":"progress","fraction":0.4}
← {"id":"1","ok":true,"result":{"bytes_before":120400,"bytes_after":41230,"width":1200,"height":800}}
← {"id":"2","ok":false,"error":{"code":"unsupported","message":"not a PNG"}}
```

- `input`, `output`: absolute paths. `output` may equal `input` only when `params.in_place` is
  true; the engine then writes to a temp file in the same folder and renames atomically.
- Every success returns `bytes_before`, `bytes_after`, `width`, `height` and `format`.
- Error codes: `unsupported`, `not_found`, `decode`, `encode`, `io`, `already_smaller`,
  `invalid_params`, `cancelled`, `internal`. `message` is for people and agents.
- `{"id":"1","op":"cancel"}` cancels request `1` (best effort). `cancel` has no response of its
  own; request `1` answers `cancelled`, or its result if it finished first. A request still
  queued behind the worker pool answers `cancelled` at once; a running one when it stops.
- `serve` sends `{"id":"1","event":"started","fraction":0}` when a worker takes request `1`: time
  spent queued ends there (the app's time limit for a PDF counts from it).
- With `unsupported`, `error.reason` may say why the file is left as it is, in one sentence for
  people (`pdf.optimise`: signed, password, encryption, memory, size); the app shows it as the
  message.
- `{"op":"hello"}` answers in the usual envelope, `{"id":null,"ok":true,"result":{"version",
  "protocol","ops":[...],"features":{...}}}`, so Swift can detect the engine's capabilities
  instead of assuming.
- Every lossy op takes `compression` 0..100 (higher is smaller; **30 normal, 64 aggressive**,
  the factor of `CompressionQuality`), mapped per encoder as Clop 3.5 does. Explicit encoder
  params (`quality`, `lossy`, `colors`, `speed`) win over it.
- Every writing op takes `in_place`, `strip`, `keep` (default `["icc","orientation"]`) and
  `allow_larger` (default false for `*.optimise`, which answer `already_smaller` instead of
  writing a bigger file; true for the others). Unknown params come back in
  `result.ignored_params`.

## Ops (first version)

| op | params | notes |
|---|---|---|
| `probe` | | format, dimensions, colour space, has_alpha, exif/icc presence, frame count |
| `png.optimise` | `lossy` (bool), `quality` [min,max] 0..100, `speed` 1..10, `strip` | imagequant when lossy, then oxipng; falls back to oxipng only |
| `jpeg.optimise` | `quality` 0..100 (a ceiling, like jpegoptim `--max`) or null for lossless recompress, `progressive`, `strip` | mozjpeg |
| `webp.encode` | `quality`, `lossless`, `strip` | from any decodable input |
| `avif.encode` | `quality` (heif-enc's scale), `speed`, `strip` | libaom via libavif, `tune=iq`, grids above 12 MP |
| `gif.optimise` | `lossy` 0..200, `colors`, `level`, `backend` (auto/gifsicle/builtin) | delegates to gifsicle when present, or own re-encode; `result.backend` says which |
| `gif.from_frames` | `fps`, `quality`, `width`, `frames_dir` | gifski over PNG frames ffmpeg extracted |
| `resize` | `scale` or `width`/`height`/`long_edge`, `filter` | keeps format unless `format` given |
| `crop` | `x`,`y`,`width`,`height` or `aspect`, `gravity`, `smart` (saliency hint rect optional) | |
| `metadata.strip` | `keep` list (icc, orientation) | |
| `convert` | `format`, plus that format's params | decode anything, encode to png/jpeg/webp/avif/gif |
| `fit` | `target_bytes`, `min_quality`, `max_quality`, `allow_resize`, `min_scale`, `format` | binary search inside the engine, returns the chosen `quality`/`scale` and `fitted` |
| `pdf.optimise` | `dpi` 48..300 (0 or 300: keep resolution, JPEGs passed through), `compression` 0..100 (0: images untouched), `strip` | streams recompressed, images re-encoded and downsampled under a fidelity check, fonts subset, unused objects dropped; encrypted files re-encrypted with the same keys or refused, damaged files refused |

HEIC, JPEG XL decode, HDR gain maps and anything Apple-only stay in Swift (ImageIO).

### AVIF routing (Swift side)

`hello.features.avif_encoder` names the engine's AVIF encoder (`"libaom 3.15.3 (tune=iq)"` in
release builds) or is null/absent when the build has none (or the engine predates the field);
then `features.encode` omits `avif` and `avif.encode` answers `unsupported`.
The current Swift client checks encoding capabilities and rejects an unsupported output
format. It does not automatically fall back to ImageIO for AVIF encoding.

ImageIO was evaluated as an alternative on macOS 26. On the synthetic benchmark corpus it
needed about 1.5 times the bytes at normal quality for the reference SSIMULACRA2 score and
wrote unspecified colour primaries and transfer. See the
[benchmark report](../engine/bench/README.md). Video and audio use ffmpeg and system encoders.

## Rules
- Pure Rust where it exists; C codecs include mozjpeg, libwebp, libavif and libaom.
  Crates vendor codec sources; release builds use the pinned libaom build script.
  No network. No dynamic libraries outside the system.
- Licences checked in CI with `cargo-deny` against the allowlist in `engine/deny.toml`
  (GPL-3.0-or-later compatible). gifsicle (GPL-2.0-only) is never linked, only executed.
- Deterministic output for the same input and params, so tests can use byte-size goldens.
