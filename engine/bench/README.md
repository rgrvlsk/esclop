# Engine benchmarks

`bench.py` runs `esclop-engine` over a corpus and, for every file, the tool Clop 3.5 runs for
the same job with Clop's flags for the same compression factor:

| kind | engine op | reference (Clop's command) |
|---|---|---|
| PNG | `png.optimise` | `pngquant --force --speed S --quality 0-Q [colours]` |
| JPEG | `jpeg.optimise` | `jpegoptim --keep-all --force --max Q --auto-mode` |
| GIF | `gif.optimise` | `gifsicle -OL --lossy=N [--colors=N] --threads=T` |
| WebP | `webp.encode` | `cwebp -mt -q Q -sharp_yuv -metadata all` |

It records output size, SSIMULACRA2 against the input (when `ssimulacra2` is on `PATH`), wall
time and peak RSS (`/usr/bin/time -l`), then the per-format medians against the targets in
[the roadmap](../../docs/PLAN.md): median size ≤ 102 % of the reference at equal or better SSIMULACRA2, and peak
RSS ≤ 300 MB on a 24-megapixel JPEG (`--big`).

```
cargo build --release
cargo run --release --example make-corpus -- /tmp/esclop-corpus --big   # synthetic corpus
python3 bench/bench.py /tmp/esclop-corpus --big /tmp/big-24mp.jpg --out report.md
python3 bench/bench.py /tmp/esclop-corpus --compression 64              # aggressive
```

**Reference binaries.** With `CLOP_BIN` set to a local `Clop.app` (or the folder holding its
tools) the script runs Clop's own binaries; otherwise it uses the tools on `PATH` (Homebrew's
pngquant 3, jpegoptim on libjpeg-turbo, gifsicle, cwebp). Clop's binaries are only executed in
place: never copied, committed or redistributed.

**Corpus.** Any folder of `.png`, `.jpg` and `.gif` files works. `make-corpus` writes a
synthetic one (no personal media): photo-like JPEGs and PNGs with grain and hard edges, UI
screenshots, transparent illustrations, and animations with per-frame palettes.

**JPEG calibration.** `calibrate_jpeg.py CORPUS` finds, for each libjpeg quality, the mozjpeg
quality whose SSIMULACRA2 matches jpegoptim's, and prints the table `codec/jpeg.rs` uses. Run
it again after changing the JPEG codec (for example to jpegli).

**AVIF encoders.** `avif_rd.py CORPUS --candidate NAME='cmd {in} {out} {q}' ...` compares AVIF
encoders by rate-distortion, independent of any quality mapping: for each image and each of
Clop's two heif-enc qualities it finds the smallest file each candidate makes at heif-enc's
SSIMULACRA2 or better. `calibrate_avif.py` calibrates the optional rav1e codec's mapping.

## Results

Synthetic corpus from `make-corpus` (14 files: 4 photo JPEGs at q92, 2 photo PNGs, 1 screenshot
JPEG at q95, 3 screenshot PNGs, 2 transparent PNGs, 2 GIFs; WebP and AVIF are converted from
every PNG and JPEG). Apple M4, release build linking libaom 3.15.3, one process per file.
Reference: Homebrew pngquant 3.0.3, jpegoptim 1.5.6 (libjpeg-turbo), gifsicle 1.98, cwebp
1.6.0, heif-enc 1.23.7 (libaom 3.15.3) with Clop 3.5's flags. This run used reference tools from Homebrew,
not Clop's bundled binaries (`CLOP_BIN` unset). It is not a benchmark of the Clop app.

### Normal (compression 30)

| kind | n | size engine / ref | SSIMULACRA2 engine | SSIMULACRA2 ref | time engine / ref | ≤ 1.02 at ≥ quality |
|---|--:|--:|--:|--:|--:|---|
| PNG | 7 | 0.932 | 91.5 | 91.2 | 0.75 | pass |
| JPEG | 5 | 0.881 | 79.3 | 76.3 | 4.25 | pass |
| GIF | 2 | 1.000 | – | – | 1.25 | same backend; quality not measured |
| WebP | 12 | 1.000 | 64.2 | 64.2 | 1.08 | pass |
| AVIF | 12 | 1.000 | 73.8 | 73.9 | 0.95 | below quality target by 0.1 |

### Aggressive (compression 64)

| kind | n | size engine / ref | SSIMULACRA2 engine | SSIMULACRA2 ref | time engine / ref | ≤ 1.02 at ≥ quality |
|---|--:|--:|--:|--:|--:|---|
| PNG | 7 | 0.934 | 66.8 | 67.3 | 1.00 | borderline: 0.5 below |
| JPEG | 5 | 0.774 | 57.0 | 54.9 | 2.50 | pass |
| GIF | 2 | 1.000 | – | – | 1.15 | same backend; quality not measured |
| WebP | 12 | 1.000 | 59.6 | 59.6 | 1.06 | pass |
| AVIF | 12 | 1.000 | 63.5 | 63.9 | 0.90 | below quality target by 0.4 |

### Memory and time on a 24-megapixel JPEG (6000x4000, 6.3 MB)

| op | time s | peak RSS MB | ≤ 300 MB |
|---|--:|--:|---|
| probe | 0.00 | 15 | pass |
| jpeg.optimise (re-encode) | 2.02 | 264 | pass |
| jpeg.optimise (lossless) | 1.17 | 188 | pass |
| metadata.strip | 0.01 | 15 | pass |
| resize scale 0.5 | 0.30 | 137 | pass |
| crop aspect 1:1 | 1.39 | 181 | pass |
| webp.encode | 1.16 | 228 | pass |
| avif.encode (speed 6) | 0.79 | 224 | pass |
| convert to png | 1.29 | 222 | pass |
| fit 1.5 MB | 10.29 | 239 | pass |

The references on the same image: jpegoptim 172 MB, pngquant 136 MB (from a PNG), cwebp
`-sharp_yuv` 359 MB, heif-enc 527 MB. The stripped arm64 binary is 8.4 MB.

### AVIF: before and after

| | size vs heif-enc, normal | aggressive | SSIMULACRA2 normal (engine / ref) | 24 MP peak RSS | 24 MP time |
|---|--:|--:|---|--:|--:|
| before: ravif/rav1e, 4:4:4 | 1.787 | 4.047 | 76.6 / 73.9 | 793-1100 MB | 5.2 s |
| after: libaom 3.15 `tune=iq`, 4:2:0, grid > 12 MP | 1.000 | 1.000 | 73.8 / 73.9 | 224 MB | 0.79 s |

Per file the two encoders agree: photos within 0.3 % in size and 0.2 in SSIMULACRA2,
screenshots within 0.7 SSIMULACRA2 (the engine decodes JPEG with zune-jpeg, heif-enc with
libjpeg; RGB to YUV rounding differs), transparent images 5-8 % larger at 0.5-2 points better
(alpha gets the same quality mapping as colour). The medians are 0.1 (normal) and 0.4
(aggressive) below heif-enc's. These results do not meet the strict "equal or better"
quality target; the report does not establish a noise threshold.

### How the AVIF encoder was chosen

Rate-distortion with `avif_rd.py` on the 10 opaque files at full size: median size of the
smallest file reaching heif-enc's SSIMULACRA2, relative to heif-enc (lower is better).

| candidate | normal (heif-enc q60) | aggressive (q43) | time / heif-enc |
|---|--:|--:|--:|
| (b) rav1e via ravif, speed 6 (the previous engine) | 1.509 | 2.328 | 3.17 |
| (c) ImageIO (`CGImageDestination`, macOS 26) | 1.511 | 1.366 | 0.96 |
| (a) libaom 3.11 (libaom-sys's copy) via libavif, speed 6 | 1.427 | 1.060 | 0.84 |
| (a) libaom 3.11, speed 8 | 1.570 | 1.364 | 0.36 |
| (a) libaom 3.15 `tune=iq`, speed 6, AV1 tiles on | 1.042 | 1.215 | 0.67 |
| (a) libaom 3.15 `tune=iq`, speed 8 | 1.064 | 1.233 | 0.42 |
| **(a) libaom 3.15 `tune=iq`, speed 6, no tiles (the engine)** | **1.003** | **1.026** | 0.93 |

The deciding variable is `tune=iq`: heif-enc itself, with the same libaom 3.15, needs 1.486x
its own bytes at normal with `tune=psnr` and 1.485x with `tune=ssim` (3-image check). rav1e
has no equivalent tuning and no 4:2:0 in ravif; through libavif with 4:2:0 it was 5-25 s on
24 MP. ImageIO writes unspecified colour primaries and transfer. AV1 tiles cost up to 20 % at
aggressive compression. The aggressive 1.026 above is quantizer granularity in the bisection;
with the quality mapping in `codec/avif_aom.rs` (heif-enc 60 → libavif 52, 43 → 33) the two
encoders' files match within 0.1 % at every one of Clop's qualities.

Memory on the 24 MP image with libaom 3.15 (encoder alone): one image 416 MB; grids 2x1 240 MB
(+0.2 % size), 3x1 182 MB (+0.06 %), 2x2 151 MB (+0.3 %). The engine uses 2x2-like cells of
about 6 MP above 12 MP.

### Reading the numbers

- JPEG produces smaller files and higher median scores on this corpus because the protocol's quality stays on jpegoptim's scale
  and the codec picks the mozjpeg quality that matches it (`calibrate_jpeg.py`); without that
  translation mozjpeg at "85" was half the size but 6 SSIMULACRA2 points worse. It is slower:
  trellis quantisation and scan optimisation cost 2-4x jpegoptim's time (0.1-0.5 s for a 2-6 MP
  photo).
- PNG produces smaller median files here because oxipng recompresses imagequant's palette, which pngquant does not
  do; at aggressive the SSIMULACRA2 median is 0.5 below pngquant's (66.8 vs 67.3), below
  the "equal or better" target.
- AVIF uses the same libaom version as the reference heif-enc in this run. Median sizes
  match, with small quality shortfalls recorded above.
- The corpus is synthetic and small. Re-run with `CLOP_BIN` and a real corpus before treating
  any ratio as final.
