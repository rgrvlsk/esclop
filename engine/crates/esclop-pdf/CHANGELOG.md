# Changelog

All notable changes to esclop-pdf are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0]

The PDF engine of L'Esclop 0.1.1 as a library, with the same output.

### Added
- `optimise` and `optimise_with`: bytes in, `Outcome` out (`Rewritten { bytes, report }` or
  `Kept { reason, detail }`), one `Error` type with an `ErrorKind`.
- `Options` through `Options::builder()`: compression 0 to 100, `max_dpi`, `strip_metadata`,
  `memory_budget`.
- `Observer`: progress by `Stage` and cancellation.
- Images downsampled and re-encoded under a per-page and per-image SSIM gate; JPEG 2000, CCITT,
  16-bit, CMYK, indexed and masked images; TrueType and CFF font subsetting with glyph ids kept;
  inline images moved to objects; streams recompressed and deduplicated; object streams.
- Signed, Reader-extended and password-protected files, and encryption that cannot be written
  again, left as they are; other encrypted files encrypted again with the same keys.
- cargo-fuzz targets for the whole rewrite, the loader, the CFF and TrueType subsetters and
  inline-image extraction.
