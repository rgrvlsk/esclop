# PDF benchmark: Ghostscript against `pdf.optimise`

Answers one question with numbers: can `esclop-engine` optimise PDFs well enough to stop
shipping Ghostscript? It runs both on a generated corpus at the default and aggressive settings
and judges every output against its original.

```sh
python3 engine/bench/pdf/make_corpus.py /tmp/pdf-corpus         # 34 files, about 30 s
cargo build --release --manifest-path engine/Cargo.toml
python3 engine/bench/pdf/run.py /tmp/pdf-corpus --out /tmp/pdf-bench   # gs and engine, 3 runs each
```

Needs macOS (PDFKit, Quartz), Python 3 with numpy and Pillow, `gs` on PATH (10.08.0 is what
L'Esclop bundled) and `swiftc` (`DEVELOPER_DIR` pointing at Xcode).

- **Corpus** (`make_corpus.py`): everything is synthesised; no third-party files. Scans (JPEG,
  Flate, CCITT G4 at 300 and 600 dpi), slides with Flate, JPEG and soft-masked images, text with
  Quartz subset fonts, fully embedded TrueType and base-14 fonts, vector drawings, a mixed report,
  AcroForm fields, links/notes/outline, a tagged PDF, owner- and user-password encryption (RC4),
  a linearised file, transparency with Display P3 ICC images, CMYK, 300 pages, duplicates,
  metadata, a q97 photo book, indexed, inline and colour-keyed images, 16-bit, PNG predictors,
  object streams, and two damaged files. `corpus.sha256` records one run; the Quartz files
  (creation date) and the gs-linearised one differ between runs, the rest are reproducible.
- **gs path**: the argument list from `Sources/EsclopOptimisers/GhostscriptArguments.swift` as it
  was when L'Esclop still shipped Ghostscript, frozen in `run.py`, with the same per-document DPI
  choice (ported in `judge.swift`), one stop lower when aggressive. Files the app refused
  (locked, unreadable) count at their original size, and so do results that are not smaller.
- **Engine path**: `pdf.optimise` with the same DPI, compression 30 or 64, `strip: true`.
- **Judge** (`judge.swift`): opens with PDFKit; page, link, outline and form-field counts and a
  hash of PDFKit's text must match the original; every page is rendered at 150 dpi with
  CoreGraphics and compared by SSIM (7×7 window, mean of R, G, B). `compare-many` also reports
  `diffpx` (pixels where a channel differs by more than 32) and `diffpx_ink` (pixels whose 5×5
  mean signed luminance difference passes 24): SSIM to four decimals hides a page of lost
  glyphs (0.984 on one), `diffpx_ink` does not, and it ignores the one-pixel antialiasing
  shifts CoreGraphics makes whenever a font's unused glyphs are emptied.
- **Real corpus** (`fetch_real.py`): the pdf.js test PDFs and one GovDocs1 thread, 1576 files
  pinned by `real.sha256`, kept in the gitignored `.data/` beside the binaries under test.
  `fontoracle.py` renders engine v1's output against a newer engine's on every file: the two
  differ only in font programs, so any `diffpx_ink` is a font bug.
- **Memory**: this benchmark once took a 16 GB Mac down (four judges at 11 GB each). SSIM now
  slides a window over column sums (O(width) memory); a page's cost (two rasters plus
  CoreGraphics' full-size decode of its images, ~8 bytes per image pixel) counts against
  `JUDGE_RASTER_MB` (400) in flight; a page over `JUDGE_PAGE_MB` (1200) is not rendered and
  reports SSIM -1 (unjudged); the judge exits 75 above `JUDGE_SELF_MB` (1300) resident.
  `run.py` runs every child in its own process group under `/usr/bin/time -l`, kills it above
  1.4 GB (judge) or 2.25 GB (tools), allows one judge at a time, caps files a child writes at
  2 GB, refuses `--jobs` whose worst case passes 6 GB, and stops below 10 GB of free disk.
  Use `--jobs 2`.
- **Targets**: no failures; identical text and counts; min SSIM ≥ 0.98 default, ≥ 0.95
  aggressive, and never more than 0.01 below gs; corpus total within 10 % of gs at both
  settings; no image-heavy file (images over half of its bytes) more than 25 % larger than gs;
  median time per file no worse than gs.
