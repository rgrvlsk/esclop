# Size techniques in other PDF tools

What six tools do to make PDFs smaller, against what `pdf.optimise` does. Methods only, in our
own words: none of their code is copied, and GPL/AGPL code (MuPDF, pdfsizeopt, Ghostscript) is
read for how it works, never for text. Surveyed 2026-11-10 from each project's source or docs.

| Tool | Licence | What reduces size |
|---|---|---|
| qpdf | Apache-2.0 | object and xref streams (`--object-streams=generate`), Flate recompression at a chosen level (`--recompress-flate`, `--compression-level`), re-encoding non-JPEG images as JPEG when smaller (`--optimize-images`), dropping resources the page content never names (`--remove-unreferenced-resources`), metadata and structure-tree removal. No font work. ([cli.rst](https://github.com/qpdf/qpdf/blob/main/manual/cli.rst)) |
| MuPDF `mutool clean` | AGPL-3.0 | garbage collection in four levels (unused objects, compacted xref, merged duplicate objects, merged duplicate streams), compression of fonts, images and other streams, content-stream cleaning and sanitising (rewrites operators, drops redundant ones), object streams, image subsampling and recompression to JPEG, JPEG 2000, fax or JBIG2, structure-tree removal, and font subsetting marked experimental (`-S`). ([pdfclean.c](https://github.com/ArtifexSoftware/mupdf/blob/master/source/tools/pdfclean.c)) |
| pdfcpu `optimize` | Apache-2.0 | finds and merges duplicate font dictionaries and duplicate images across pages, shares identical content streams, drops unused resources. No subsetting. ([optimize.go](https://github.com/pdfcpu/pdfcpu/blob/master/pkg/pdfcpu/optimize.go)) |
| pdfsizeopt | GPL-2.0 | converts Type 1 fonts to CFF (Type1C) and merges the subsets of one font into a single font (both through old Ghostscript versions), lossless image re-encoding (fewest bits per sample, palettes, best PNG predictor, then pngout, zopflipng or ECT), JBIG2 for bilevel images, duplicate-object elimination, object streams. Aimed at TeX output. ([README](https://github.com/pts/pdfsizeopt/blob/master/README.md)) |
| Typst `subsetter` | MIT OR Apache-2.0 | subsets TrueType and CFF/CFF2 outlines for a PDF *writer*: it drops `cmap` and renumbers glyphs, so the caller must write a CID font with its own CMap. ([lib.rs](https://github.com/typst/subsetter/blob/main/src/lib.rs)) |
| HarfBuzz `hb-subset` | MIT | the reference general subsetter (TrueType, CFF, CFF2, layout closure, retained glyph ids, desubroutinising, hint removal). `skera` (googlefonts/fontations, MIT OR Apache-2.0) is its Rust port. |

## Subsetter choice

`skera`. A rewrite of an existing PDF has to leave its text alone. The codes in content streams
select glyphs through the font's `cmap` (simple TrueType fonts) or `/CIDToGIDMap` (CID fonts),
and both stay valid only if glyph ids stay put. `skera` keeps ids (`SUBSET_FLAGS_RETAIN_GIDS`)
and can copy `cmap` untouched. Typst's crate removes `cmap` and renumbers glyphs by design, so it
would mean re-encoding every string, as Ghostscript does. Caveats: `skera`'s desubroutinise flag
is documented as unimplemented, and retained ids end at the highest glyph kept (we keep the last
glyph to hold the count).

## What we lack, by expected savings

Measured upper bounds come from `examples/font-census.rs` on the real corpus (pdf.js test files
and 200 GovDocs1 files). The other rankings are estimates and need their own measurement.

1. **Font subsetting**: TrueType done in this branch. Measured: TrueType programs not yet subset
   hold 71 MB of the pdf.js set's 553 MB, but only 1.1 MB of GovDocs' 126 MB (most office
   output already subsets). Effort S–M, crate: `skera`.
2. **Merging subsets of the same font** (pdfsizeopt, Ghostscript): copies of a font with the same
   base name inside one file are 11.2 MB (pdf.js) and 2.8 MB (GovDocs, 2.2 % of bytes), an upper
   bound. Effort L: it needs proof that both subsets come from the same font and share glyph ids.
3. **JBIG2 for bilevel scans** (MuPDF, pdfsizeopt): replaces CCITT G4 for scanned text. Not
   measured. Effort L, and no permissive Rust encoder is known to us (jbig2enc is Apache-2.0 C++).
4. **CFF subsetting** (`/FontFile3`): 12.8 MB not yet subset in pdf.js, ~0 in GovDocs. Effort M:
   bare CFF must be wrapped as OpenType for `skera`, and the code-to-glyph mapping goes through
   the CFF charset.
5. **Unreferenced resources** (qpdf, pdfcpu): images and fonts listed in a page's resources but
   never drawn survive pruning, because they are still reachable. Not measured. Effort S.
6. **Lossless image depth and palette reduction** (pdfsizeopt): not measured. Effort M; `oxipng`
   already does this for PNG and its reductions apply to PDF image samples.
7. **Type 1 to CFF** (pdfsizeopt, Ghostscript): Type 1 programs total 4.7 MB (pdf.js) and 0.6 MB
   (GovDocs), so the gain is small. Effort L.
8. **Content-stream sanitising** (MuPDF): not measured. Effort M.
