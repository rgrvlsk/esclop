# Results (Apple M4, gs 10.08.0, median of 3 runs)

Ratio is engine size / gs size. `kept`: the result was not smaller, so the app keeps the original; `refused`: encrypted or unreadable input.

**default** (gs → engine: size, min SSIM, seconds)

| file | original | gs | engine | ratio | gs SSIM | engine SSIM | gs s | engine s |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| annotations-links-outline | 13 kB | 11 kB | 8 kB | 0.73 | 0.9999 | 1.0000 | 0.13 | 0.05 |
| cmyk-images | 10.86 MB | 271 kB | 301 kB | 1.11 | 0.9971 | 0.9988 | 0.96 | 0.27 |
| damaged-bad-xref | 13 kB | 11 kB | 8 kB | 0.73 | 0.9999 | 1.0000 | 0.11 | 0.02 |
| damaged-truncated | 1.35 MB | 1.35 MB (refused) | 1.35 MB (refused) | 1.00 | – | – | 0.00 | 0.00 |
| duplicate-images | 4.21 MB | 40 kB | 31 kB | 0.78 | 0.9961 | 0.9966 | 0.26 | 0.18 |
| encrypted-owner-password | 1.46 MB | 50 kB | 1.46 MB (refused) | 29.09 | 0.9995 | – | 0.16 | 0.01 |
| encrypted-user-password | 1.50 MB | 1.50 MB (refused) | 1.50 MB (refused) | 1.00 | – | – | 0.00 | 0.00 |
| forms-acroform | 7 kB | 3 kB | 4 kB | 1.07 | 0.9962 | 1.0000 | 0.13 | 0.02 |
| indexed-images | 94 kB | 94 kB (kept) | 94 kB | 0.99 | 1.0000 | 1.0000 | 0.08 | 0.04 |
| inline-images-masks | 33 kB | 33 kB (kept) | 32 kB | 0.95 | 0.9994 | 1.0000 | 0.05 | 0.05 |
| linearised | 2.24 MB | 381 kB | 275 kB | 0.72 | 0.9959 | 0.9969 | 0.26 | 0.22 |
| metadata-heavy | 474 kB | 9 kB | 6 kB | 0.68 | 1.0000 | 1.0000 | 0.12 | 0.02 |
| mixed-report | 1.93 MB | 157 kB | 480 kB | 3.06 | 0.9970 | 0.9972 | 0.17 | 0.16 |
| object-streams-xref-stream | 1.92 MB | 157 kB | 480 kB | 3.06 | 0.9970 | 0.9972 | 0.16 | 0.14 |
| pages-300-quartz | 6.49 MB | 1.73 MB | 1.19 MB | 0.69 | 0.9993 | 0.9998 | 1.45 | 0.38 |
| photobook-jpeg-q97 | 34.52 MB | 34.52 MB (kept) | 1.79 MB | 0.05 | 1.0000 | 0.9975 | 1.09 | 1.79 |
| png-predictor-image | 408 kB | 81 kB | 57 kB | 0.71 | 0.9991 | 0.9993 | 0.04 | 0.05 |
| scan-ccitt-300dpi | 179 kB | 171 kB | 169 kB | 0.98 | 1.0000 | 1.0000 | 0.05 | 0.55 |
| scan-ccitt-600dpi | 89 kB | 87 kB | 85 kB | 0.98 | 1.0000 | 1.0000 | 0.04 | 1.24 |
| scan-color-flate-150dpi | 8.17 MB | 645 kB | 459 kB | 0.71 | 0.9857 | 0.9867 | 0.10 | 0.14 |
| scan-color-jpeg-300dpi | 6.32 MB | 6.32 MB (kept) | 1.44 MB | 0.23 | 1.0000 | 0.9984 | 0.22 | 0.67 |
| scan-gray-flate-300dpi | 9.79 MB | 1.13 MB | 671 kB | 0.59 | 0.9904 | 0.9909 | 0.13 | 0.27 |
| scan-gray-jpeg-200dpi | 2.35 MB | 1.10 MB | 798 kB | 0.73 | 0.9973 | 0.9974 | 0.10 | 0.22 |
| sixteen-bit-image | 3.73 MB | 85 kB | 69 kB | 0.82 | 0.9969 | 0.9976 | 0.06 | 0.08 |
| slides-alpha-smask | 1.60 MB | 246 kB | 170 kB | 0.69 | 0.9962 | 0.9971 | 0.19 | 0.06 |
| slides-flate-images | 3.09 MB | 374 kB | 268 kB | 0.72 | 0.9963 | 0.9971 | 0.20 | 0.08 |
| slides-jpeg-images | 2.23 MB | 381 kB | 275 kB | 0.72 | 0.9959 | 0.9969 | 0.21 | 0.20 |
| tagged-structure | 7 kB | 5 kB | 3 kB | 0.55 | 1.0000 | 1.0000 | 0.10 | 0.01 |
| text-full-embedded-fonts | 602 kB | 137 kB | 587 kB | 4.29 | 0.9999 | 1.0000 | 0.19 | 0.03 |
| text-quartz-subset-fonts | 140 kB | 133 kB | 97 kB | 0.73 | 0.9996 | 1.0000 | 0.15 | 0.05 |
| text-uncompressed-base14 | 77 kB | 36 kB | 30 kB | 0.82 | 0.9999 | 1.0000 | 0.19 | 0.01 |
| transparency-icc-p3 | 13.19 MB | 525 kB | 434 kB | 0.83 | 0.9693 | 1.0000 | 1.30 | 0.26 |
| vector-flate-level1 | 1.12 MB | 870 kB | 952 kB | 1.09 | 1.0000 | 1.0000 | 0.20 | 0.06 |
| vector-uncompressed | 2.06 MB | 690 kB | 756 kB | 1.10 | 1.0000 | 1.0000 | 0.16 | 0.04 |
| **total / median** | | **53.32 MB** | **16.32 MB** | **0.306** | | | 0.157 | 0.076 |

**aggressive** (gs → engine: size, min SSIM, seconds)

| file | original | gs | engine | ratio | gs SSIM | engine SSIM | gs s | engine s |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| annotations-links-outline | 13 kB | 11 kB | 8 kB | 0.73 | 0.9999 | 1.0000 | 0.13 | 0.01 |
| cmyk-images | 10.86 MB | 208 kB | 215 kB | 1.03 | 0.9973 | 0.9988 | 0.99 | 0.23 |
| damaged-bad-xref | 13 kB | 11 kB | 8 kB | 0.73 | 0.9999 | 1.0000 | 0.11 | 0.02 |
| damaged-truncated | 1.35 MB | 1.35 MB (refused) | 1.35 MB (refused) | 1.00 | – | – | 0.00 | 0.00 |
| duplicate-images | 4.21 MB | 28 kB | 18 kB | 0.65 | 0.9934 | 0.9927 | 0.23 | 0.18 |
| encrypted-owner-password | 1.46 MB | 50 kB | 1.46 MB (refused) | 29.09 | 0.9995 | – | 0.16 | 0.01 |
| encrypted-user-password | 1.50 MB | 1.50 MB (refused) | 1.50 MB (refused) | 1.00 | – | – | 0.00 | 0.00 |
| forms-acroform | 7 kB | 3 kB | 4 kB | 1.08 | 0.9963 | 1.0000 | 0.13 | 0.02 |
| indexed-images | 94 kB | 94 kB (kept) | 94 kB | 0.99 | 1.0000 | 1.0000 | 0.08 | 0.04 |
| inline-images-masks | 33 kB | 33 kB (kept) | 32 kB | 0.95 | 0.9994 | 1.0000 | 0.05 | 0.04 |
| linearised | 2.24 MB | 235 kB | 152 kB | 0.64 | 0.9932 | 0.9932 | 0.21 | 0.20 |
| metadata-heavy | 474 kB | 9 kB | 6 kB | 0.68 | 1.0000 | 1.0000 | 0.12 | 0.01 |
| mixed-report | 1.93 MB | 131 kB | 452 kB | 3.46 | 0.9950 | 0.9940 | 0.15 | 0.14 |
| object-streams-xref-stream | 1.92 MB | 131 kB | 452 kB | 3.46 | 0.9950 | 0.9940 | 0.16 | 0.14 |
| pages-300-quartz | 6.49 MB | 1.73 MB | 1.15 MB | 0.67 | 0.9993 | 0.9998 | 1.39 | 0.34 |
| photobook-jpeg-q97 | 34.52 MB | 1.25 MB | 886 kB | 0.71 | 0.9941 | 0.9957 | 0.69 | 1.72 |
| png-predictor-image | 408 kB | 81 kB | 53 kB | 0.66 | 0.9991 | 0.9992 | 0.04 | 0.05 |
| scan-ccitt-300dpi | 179 kB | 171 kB | 169 kB | 0.98 | 1.0000 | 1.0000 | 0.05 | 0.53 |
| scan-ccitt-600dpi | 89 kB | 47 kB | 42 kB | 0.91 | 0.9990 | 0.9986 | 0.09 | 0.55 |
| scan-color-flate-150dpi | 8.17 MB | 645 kB | 410 kB | 0.63 | 0.9857 | 0.9865 | 0.10 | 0.14 |
| scan-color-jpeg-300dpi | 6.32 MB | 1.35 MB | 881 kB | 0.65 | 0.9813 | 0.9905 | 0.28 | 0.64 |
| scan-gray-flate-300dpi | 9.79 MB | 662 kB | 411 kB | 0.62 | 0.9969 | 0.9971 | 0.15 | 0.21 |
| scan-gray-jpeg-200dpi | 2.35 MB | 585 kB | 401 kB | 0.68 | 0.9925 | 0.9939 | 0.11 | 0.18 |
| sixteen-bit-image | 3.73 MB | 85 kB | 63 kB | 0.74 | 0.9969 | 0.9973 | 0.06 | 0.08 |
| slides-alpha-smask | 1.60 MB | 153 kB | 100 kB | 0.65 | 0.9934 | 0.9935 | 0.16 | 0.04 |
| slides-flate-images | 3.09 MB | 232 kB | 148 kB | 0.64 | 0.9937 | 0.9935 | 0.17 | 0.05 |
| slides-jpeg-images | 2.23 MB | 235 kB | 151 kB | 0.64 | 0.9932 | 0.9932 | 0.20 | 0.19 |
| tagged-structure | 7 kB | 5 kB | 3 kB | 0.55 | 1.0000 | 1.0000 | 0.10 | 0.01 |
| text-full-embedded-fonts | 602 kB | 137 kB | 587 kB | 4.29 | 0.9999 | 1.0000 | 0.23 | 0.03 |
| text-quartz-subset-fonts | 140 kB | 133 kB | 97 kB | 0.73 | 0.9996 | 1.0000 | 0.15 | 0.05 |
| text-uncompressed-base14 | 77 kB | 36 kB | 30 kB | 0.82 | 0.9999 | 1.0000 | 0.15 | 0.01 |
| transparency-icc-p3 | 13.19 MB | 471 kB | 398 kB | 0.84 | 0.9694 | 1.0000 | 1.11 | 0.24 |
| vector-flate-level1 | 1.12 MB | 870 kB | 952 kB | 1.09 | 1.0000 | 1.0000 | 0.24 | 0.06 |
| vector-uncompressed | 2.06 MB | 690 kB | 756 kB | 1.10 | 1.0000 | 1.0000 | 0.16 | 0.04 |
| **total / median** | | **13.36 MB** | **13.44 MB** | **1.006** | | | 0.153 | 0.070 |
## With TrueType subsetting (2026-11-11)

Synthetic corpus, engine at f7f83b2: no failures at either setting. Totals: default 15.06 MB
(gs 53.32 MB, engine before subsetting 16.32 MB), aggressive 12.18 MB (gs 13.36 MB, before
13.44 MB). `text-full-embedded-fonts` drops from 587 kB to 80 kB (gs 137 kB).

## Real corpus (1576 files: pdf.js test PDFs and GovDocs1 thread 0)

`run.py .data/real --jobs 2 --repeat 1`, engine at f7f83b2. 1538 files open in the judge; 24
only in gs, 11 locked, 2 unreadable, 1 beyond the judge's memory cap (a decompression bomb).

| setting | original | gs | engine | files failing a check: gs | engine |
|---|---:|---:|---:|---:|---:|
| default | 670.8 MB | 344.3 MB | 426.4 MB | 456 | 18 |
| aggressive | 670.8 MB | 289.5 MB | 412.8 MB | 451 | 12 |

gs failures are mostly the text hash (372), form fields (133) and SSIM (103). Engine failures
(SSIM 15, text 4, memory 1 at default) all predate font subsetting: the same files fail with
the engine before it. Peak RSS: judge 776 MB comparing, 1315 MB when it stopped itself on the
bomb; gs 2395 MB and engine 3037 MB, both killed at the cap (the engine on pdf.js issue10880,
which it cannot handle in memory). With 0.05 s polls the tool peak is 2.4 GB.

Font oracle (`fontoracle.py`, v1 against f7f83b2 at 150 dpi): 358 outputs change, fonts save
22.2 MB (5.8 % of v1's output), 347 render pixel-identical, 10 differ only by antialiasing
(`diffpx_ink` 0 to 3), none loses or changes a glyph.

## Engine at 1903caf (2026-11-11): no fidelity failures

Real corpus, `run.py --jobs 2`: engine 0 failures at both settings (one judge flake, the
original's render of govdocs/000187 scoring every output 0.9665, passes on rerun; run.py now
re-judges once). Before (v5): 18 files at default, 12 aggressive. Synthetic: 0 failures.

| setting | original | gs | engine | engine / gs, all | engine / gs, files gs passes |
|---|---:|---:|---:|---:|---:|
| default | 670.8 MB | 344.3 MB | 452.1 MB | 1.31 | 1.13 |
| aggressive | 670.8 MB | 289.5 MB | 424.0 MB | 1.46 | 1.27 |

gs fails a check on 474 / 470 files (text 372, fields 133, SSIM 99, permissions 38 at default).
Gap on files gs passes, by cause (gap.py --clean, default): fonts kept whole 21.3 MB (mostly
XFA forms' default fonts, kept on purpose), CFF fonts not subset 7.4, images 7.5, other 4.8,
content 2.3. Peak RSS: judge 826 MB comparing, engine 1096 MB (p99 292), gs killed at its 2 GB cap.

## Engine at 03e9f8b (2026-11-11): CFF subsetting, inline images, 512 MB

| check | default | aggressive | target |
|---|---:|---:|---:|
| engine failures, real corpus (1539 judged) | 0 | 0 | 0 |
| engine first-judgement failures (100 re-judged files, 190 outputs) | 0 | 0 | 0 |
| engine / gs size, files gs passes | 1.092 | 1.224 | 1.10 |
| engine / gs size, all files | 1.255 | 1.395 | |
| engine peak RSS | 487 MB | | 512 MB |

Synthetic corpus: 0 failures; 17.2 MB default (gs 50.5), 8.1 MB aggressive (gs 10.5).
CFF subsetting against the same engine with CFF off: 14.4 MB saved, 73 changed outputs, all
pixel-identical. Aggressive gap on files gs passes (29.2 MB): fonts kept whole 21.6 MB (XFA
forms' default fonts, kept for filling fields), gs downsamples more 8.3, other 6.2,
recompression 3.9, OpenType fonts 2.3.
