# esclop-pdf

Makes PDFs smaller without changing what they show. It is the PDF engine of
[L'Esclop](https://github.com/rgrvlsk/esclop), a macOS file optimiser, as a library.

```rust,no_run
use esclop_pdf::{Options, Outcome};

let input = std::fs::read("report.pdf")?;
let options = Options::builder().max_dpi(150).strip_metadata(true).build()?;
match esclop_pdf::optimise(input, &options)? {
    Outcome::Rewritten { bytes, report, .. } => {
        println!("{} -> {} bytes", report.bytes_before, report.bytes_after);
        std::fs::write("report-small.pdf", bytes)?;
    }
    Outcome::Kept { reason, .. } => println!("left as it is: {reason}"),
    _ => {}
}
# Ok::<(), Box<dyn std::error::Error>>(())
```

## What it does

- **Images** are downsampled to `max_dpi` where they are drawn denser, and stored as the smaller
  of a JPEG at the compression's quality ceiling and lossless Flate. A lossy result is kept only
  if it stays within a fidelity gate: SSIM at least 0.98 per page at the default setting (0.95
  aggressive), and at least 0.90 (0.85) for any single image, however small, so signatures and
  QR codes stay legible. JPEGs are re-encoded only when downsampled or above the ceiling;
  otherwise they are recoded losslessly. JPEG 2000, CCITT, 16-bit, CMYK, indexed and masked
  images are handled.
- **Fonts**: embedded TrueType and CFF fonts keep only the glyphs the document draws, with glyph
  ids unchanged, so content streams, widths and ToUnicode maps stay valid. Fonts an interactive
  form types with stay whole.
- **Structure**: large inline images move into image objects, every stream is recompressed,
  identical streams are stored once, unreachable objects are dropped, and objects go into object
  streams.
- **Metadata** (optional): the document information, XMP, page thumbnails and application data.

Nothing else changes: text, links, outlines, form fields, annotations, the structure tree and
permissions stay as they were. Encrypted files that open without a password are encrypted again
with the same keys and permissions.

It leaves a file as it is, and says why (`Outcome::Kept`), when a rewrite could not be faithful:
signed or Reader-extended files, files that need a password, encryption it cannot write again,
or a file that would need more than the memory budget. Damaged files are an error.

## How well

Measured on 1,576 real PDFs (the pdf.js test suite and GovDocs1, thread 0) and a synthetic
corpus of 35 files, against the Ghostscript `pdfwrite` settings L'Esclop shipped before. Every
output was rendered at 150 dpi and compared page by page; text, pages, links, outlines, form
fields, permissions and form fillability were checked. Details: `engine/bench/pdf/RESULTS.md`.

| | default | aggressive |
|---|---:|---:|
| outputs failing a check (1,539 judged) | 0 | 0 |
| Ghostscript outputs failing a check | 506 | 502 |
| size against Ghostscript, files Ghostscript handled cleanly | 0.975× | 1.007× |
| seconds per file, median / p95 | 0.020 / 0.338 | 0.018 / 0.345 |
| Ghostscript, seconds per file, median / p95 | 0.090 / 0.603 | 0.087 / 0.660 |
| peak memory, any file | 487 MB | |

The library is fuzzed with cargo-fuzz (see below).

## Memory

A rewrite holds what it decodes (parsed objects, font programs) within the memory budget, 256 MB
by default, besides the file itself; images are decoded a few at a time on top. Inputs over 1 GB
are left as they are. While a file is parsed it is copied once, so for files over roughly 256 MB
the peak is about twice the file's size.

## Interface

- `optimise(bytes, &options)` and `optimise_with(bytes, &options, &observer)`.
- `Options`, built through `Options::builder()`: compression 0 to 100 (0 leaves images
  untouched), `max_dpi`, `strip_metadata`, `memory_budget`.
- `Observer`: progress and cancellation, called from several threads.
- `Outcome::Rewritten { bytes, report }` or `Outcome::Kept { reason, detail }`, and one `Error`
  with an `ErrorKind`.

Public types are `#[non_exhaustive]`, so new options, reasons and report fields can arrive in
minor versions.

## Fuzzing

```sh
cargo +nightly fuzz run optimise <corpus-dir> -- -timeout=10 -rss_limit_mb=1024
```

Targets: `optimise` (the whole rewrite), `load` (loading and its checks), `cff` and `font` (the
subsetters) and `inline` (inline-image extraction). The corpus is not part of the repository.

## Minimum Rust version

1.92 (set by `hayro-jpeg2000`).

## Licence

[MPL-2.0](LICENSE). The dependencies are under permissive licences (MIT, Apache-2.0, BSD, zlib,
IJG). L'Esclop itself is GPL-3.0-or-later; this crate is its PDF engine, relicensed by its author.
