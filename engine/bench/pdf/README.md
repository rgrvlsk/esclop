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
  CoreGraphics and compared by SSIM (7×7 window, mean of R, G, B).
- **Targets**: no failures; identical text and counts; min SSIM ≥ 0.98 default, ≥ 0.95
  aggressive, and never more than 0.01 below gs; corpus total within 10 % of gs at both
  settings; no image-heavy file (images over half of its bytes) more than 25 % larger than gs;
  median time per file no worse than gs.
