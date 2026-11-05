# esclop-engine

L'Esclop's image engine: one Rust executable that does the PNG, JPEG, WebP, AVIF and GIF work
behind a JSON-lines protocol on stdio ([`PROTOCOL.md`](PROTOCOL.md)). The Swift media layer runs it as a
separate process, so a file that crashes a decoder never takes the app down. It ships in
`Contents/Resources/bin` next to ffmpeg, Ghostscript and gifsicle.

| Work | Library | Licence |
|---|---|---|
| decode PNG, JPEG, GIF, WebP, TIFF, BMP | `image` (pure-Rust decoders, `zune-jpeg` for JPEG) | MIT/Apache-2.0 |
| PNG palettes | `imagequant` (libimagequant, Rust) | GPL-3.0-or-later |
| PNG lossless | `oxipng` (libdeflate) | MIT |
| JPEG encode and lossless transcode | `mozjpeg-sys` (mozjpeg 4.1, vendored C) | IJG/BSD-3/Zlib |
| WebP | `webp` / `libwebp-sys` (vendored C) | MIT/Apache-2.0, libwebp BSD-3 |
| AVIF | libaom 3.15 through `libavif-sys` (libavif 1.0, vendored C) and `libaom-sys`; `tune=iq`, grids above 12 MP | BSD-2 + AOM patent licence |
| AVIF, optional (`avif-rav1e`) | `ravif` / `rav1e` (Rust) | BSD-3/BSD-2 |
| resize | `fast_image_resize` (SIMD) | MIT/Apache-2.0 |
| GIF frames to GIF | `gifski` | AGPL-3.0-or-later |
| GIF optimise | gifsicle, run as a separate process when present; otherwise built in | gifsicle GPL-2.0-only (never linked) |

Metadata (JPEG segments, PNG chunks, WebP RIFF, GIF blocks, EXIF orientation) is handled by
the engine's own code in `src/meta.rs`, without exiftool.

## Build

```
Scripts/build-engine.sh          # from the repo root: libaom, then the release build, universal
                                 # when possible, strip, ad-hoc sign, size and linkage checks,
                                 # Binaries/esclop-engine
Scripts/build-engine.sh --notices  # also regenerates THIRD_PARTY-engine.md

eval "$(Scripts/build-libaom.sh --env)"   # for development: link the same libaom...
(cd engine && cargo build --release && cargo test)   # ...in cargo builds and tests
```

Requirements: Rust with edition 2024 (tested with 1.99), the Command Line Tools (clang, lipo,
codesign), CMake (libaom, libavif), and `nasm` for the x86_64 SIMD code of mozjpeg and libaom.
macOS deployment target 14.0.

**libaom.** The AVIF encoder needs libaom 3.12 or later for `tune=iq`. This setting
improves compression in the [synthetic comparison](bench/README.md). The libaom-sys crate bundles 3.11,
so `Scripts/build-libaom.sh` builds libaom 3.15.3 from its upstream release tarball (pinned URL
and sha256, 8-bit, static, no tools or tests) into `Binaries/.cache/libaom/` (the tarball in
`Binaries/.cache/dl/`, where the release's source archive collects upstream tarballs) and points
libaom-sys at it through `LIB_AOM_*`. `Scripts/build-engine.sh` also writes
`Binaries/LICENSES/libaom.txt`, and `--notices` records libaom as a "static in `esclop-engine`"
row in `THIRD_PARTY-engine.md`, which `Scripts/licence-gate.sh` checks. CI builds it for both
targets, cached by the tarball's SHA-256 (`.github/workflows/binaries.yml`). A plain `cargo build` without those variables still works:
it builds the bundled 3.11 without `tune=iq` (larger AVIF files), and `hello` reports
`"libaom 3.11.0 (tune=default)"`. The tarball belongs in the release's third-party source
archive with the other upstream sources.

**AVIF encoder features.** `avif-aom` (default) or `avif-rav1e` (pure Rust, larger files):
`cargo build --no-default-features --features avif-rav1e`. With neither, `avif.encode` answers
`unsupported` and `hello.features.avif_encoder` is null, so clients can detect that AVIF encoding is unavailable.

### Universal binary

`Scripts/build-engine.sh` builds every macOS target whose standard library is installed and
merges them with `lipo`. With rustup (CI):

```
rustup target add aarch64-apple-darwin x86_64-apple-darwin
brew install nasm cmake
Scripts/build-engine.sh          # -> Binaries/esclop-engine (arm64 + x86_64), libaom per target
lipo -archs Binaries/esclop-engine
```

A Homebrew `rust` without rustup has only the host's standard library, so the script then
builds the host slice and says which target it skipped. CI must use rustup.

The script fails when a slice is larger than 15 MB or when `otool -L` shows a library outside
`/usr/lib` and `/System/Library/Frameworks` (today: libSystem and libiconv only).

## Test

```
cargo test                       # unit, op-by-op (one-shot CLI), serve protocol, schema drift
cargo deny check                 # licences, banned crates (no network stack), sources, advisories
python3 bench/bench.py CORPUS    # sizes, SSIMULACRA2, time and RSS against Clop's tools
```

Every fixture is generated (`src/synth.rs`): photo-like texture, UI screenshots, transparency,
animations. No personal media is used or needed. `cargo run --release --example make-corpus --
DIR --big` writes the benchmark corpus, including a 24-megapixel JPEG for the memory target.

The JSON Schemas in `schema/` are generated: `cargo run -p esclop-engine -- schema schema`. A
test fails when they are stale.

## Layout

```
crates/esclop-engine/src/
  main.rs        CLI: serve, one-shot, schema, version
  server.rs      JSON-lines loop, worker pool, progress, cancel
  protocol.rs    wire types (source of schema/)
  quality.rs     compression factor -> encoder settings (Clop 3.5 curves)
  ops/           one module per op family
  codec/         jpeg (JpegCodec trait + mozjpeg), png, webp, avif, gif
  meta.rs        container metadata, byte for byte
  pixels.rs      decoding, animation frames, orientation
  fsio.rs        atomic writes, permissions, creation date, xattrs
  synth.rs       generated fixtures
```

## Choices

### JPEG codec

mozjpeg supports encoding and lossless transcoding, which the JPEG optimisation path needs.
`codec::jpeg::JpegCodec` isolates `encode`, `transcode` and `estimate_quality` so another
codec can implement the same interface. The [benchmark report](bench/README.md) records
size, quality and speed against jpegoptim on synthetic inputs.

### AVIF codec

On the 10 opaque synthetic inputs, rav1e needed median size ratios of 1.509 at normal and
2.328 at aggressive quality to reach the reference heif-enc SSIMULACRA2 scores. libaom with
`tune=iq` reached ratios of 1.003 and 1.026. The grid encoder used 224 MB on the separate
24 MP memory fixture. See [benchmarks](bench/README.md) for the method and limitations.
`codec::avif::AvifCodec` keeps rav1e selectable with `avif-rav1e` as a Rust AVIF encoder.
Other codecs still use C.

**gifski without its `gifsicle` feature.** That feature is a port of gifsicle's lossy LZW
writer; gifsicle is GPL-2.0-only, so the engine leaves it off and runs gifsicle as a separate
process instead. The built-in GIF optimiser (frame differencing, transparency, exact palettes,
colour tolerance) is the engine's own.

**AGPL.** gifski is AGPL-3.0-or-later, so the combined engine is too. Running it locally needs
nothing; offering it to remote users (an MCP server over HTTP) means offering them its source.

**No network.** The engine opens no sockets; `deny.toml` bans HTTP, TLS and async-runtime
crates from the dependency tree.

**Size.** The release profile is `opt-level = 3`, fat LTO, one codegen unit and `strip`. On the
arm64 slice (8.4 MB) libaom is 3.9 MB, the Rust code 3.5 MB, libwebp 0.4 MB and mozjpeg 0.3 MB.
`opt-level = "z"` saves 0.65 MB (8 %) but makes the bench 15 % slower (WebP 31 %, because the C
libraries follow it), and `"s"` is larger than 3, so neither is used. `panic = "abort"` is not
an option: requests are isolated with `catch_unwind` and mozjpeg reports errors by unwinding.
libaom is built 8-bit (building it without AVX-512 did not change the x86_64 slice); its
decoder (0.2 MB) stays because libavif 1.0.4 always compiles its decode path.
