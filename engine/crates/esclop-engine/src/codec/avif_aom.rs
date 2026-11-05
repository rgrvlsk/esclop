// SPDX-License-Identifier: GPL-3.0-or-later
//! AVIF through libavif and libaom (the default build).
//!
//! Settings follow what Clop's heif-enc does with the same libaom: 4:2:0, 8 bit, no AV1 tiles,
//! speed 6, quality translated from heif-enc's scale to libavif's, and `tune=iq`, libaom's
//! tuning for still images (3.12+).
//! `tune=iq` is the whole difference at normal compression: without it the same libaom needs
//! ~1.5x the bytes for the same SSIMULACRA2 (engine/bench/README.md).
//!
//! Images above 12 megapixels are written as an AVIF grid of cells of about 6 MP, each coded on
//! its own: libaom's state for a 24 MP frame is ~350 MB, for a 6 MP cell under 100 MB, and the
//! files differ by ~0.3 %. Grids are part of MIAF/AVIF and decode everywhere AVIF does.

use super::avif::{AvifCodec, AvifOptions, interpolate};
use crate::error::{EngineError, Result};
use image::DynamicImage;
use libavif_sys::*;
use std::ffi::{CStr, CString};

pub struct Libaom;

/// Version of the libaom linked in, e.g. (3, 15, 3).
pub fn libaom_version() -> (u32, u32, u32) {
    let v = unsafe { libaom_sys::aom_codec_version() } as u32;
    ((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff)
}

/// `iq` with libaom 3.12 and later. Older libaom keeps its default tuning: its `ssim` tuning
/// is no more efficient and shifts rates so far that the quality mapping no longer holds.
pub fn tune() -> Option<&'static str> {
    (libaom_version() >= (3, 12, 0)).then_some("iq")
}

/// heif-enc quality -> the libavif quality that gives libaom the same quantizer. Both drive the
/// same libaom with the same settings, but libheif and libavif map quality to quantizer
/// differently; at each row the two encoders' files match within 0.1 % (bench/avif_rd.py and
/// the size match in engine/bench/README.md). Linear between rows.
const HEIF_TO_LIBAVIF: &[(u8, u8)] =
    &[(0, 0), (15, 9), (32, 24), (43, 33), (50, 41), (60, 52), (75, 70), (90, 87), (100, 100)];

/// Without `tune=iq` (libaom before 3.12) the same quantizer looks much worse, so the bundled
/// libaom of a plain `cargo build` needs higher libavif qualities to reach heif-enc's
/// SSIMULACRA2 (bench/avif_rd.py: heif 60 -> 70, 43 -> 55). Coarse, and ~1.4x the bytes: release
/// builds always link libaom 3.15.
const HEIF_TO_LIBAVIF_WITHOUT_IQ: &[(u8, u8)] = &[(0, 5), (43, 55), (60, 70), (100, 100)];

/// The libavif quality for a heif-enc quality.
pub fn native_quality(q: u8) -> i32 {
    let table = if tune().is_some() { HEIF_TO_LIBAVIF } else { HEIF_TO_LIBAVIF_WITHOUT_IQ };
    interpolate(table, q.min(100)) as i32
}

/// One image up to this many pixels; above it, a grid.
const SINGLE_MAX_PIXELS: u64 = 12_000_000;
/// Target cell area of a grid.
const CELL_PIXELS: f64 = 6_000_000.0;

/// Cell width and height, columns and rows for a `w`x`h` image (1x1 means no grid). Cells keep
/// the image's aspect ratio, have even sides of at least 64 px (MIAF rules for 4:2:0), and only
/// the right column and bottom row may be smaller.
pub fn grid_for(w: u32, h: u32) -> (u32, u32, u32, u32) {
    let single = (w, h, 1, 1);
    if (w as u64) * (h as u64) <= SINGLE_MAX_PIXELS || w % 2 == 1 || h % 2 == 1 {
        return single;
    }
    let aspect = w as f64 / h as f64;
    let even = |v: f64| ((v.ceil() as u32 + 1) & !1).max(64);
    let cw = even(w as f64 / (w as f64 / (CELL_PIXELS * aspect).sqrt()).ceil());
    let ch = even(h as f64 / (h as f64 / (CELL_PIXELS / aspect).sqrt()).ceil());
    let (cols, rows) = (w.div_ceil(cw), h.div_ceil(ch));
    if cols > 256 || rows > 256 || w - (cols - 1) * cw < 2 || h - (rows - 1) * ch < 2 {
        return single;
    }
    (cw, ch, cols, rows)
}

fn check(r: avifResult, what: &str) -> Result<()> {
    if r == AVIF_RESULT_OK {
        return Ok(());
    }
    let msg = unsafe { CStr::from_ptr(avifResultToString(r)) }.to_string_lossy().into_owned();
    Err(EngineError::encode(format!("libavif {what}: {msg}")))
}

/// Owns libavif objects so that every exit path frees them.
struct Owned {
    images: Vec<*mut avifImage>,
    encoder: *mut avifEncoder,
    out: avifRWData,
}

impl Drop for Owned {
    fn drop(&mut self) {
        unsafe {
            for &i in &self.images {
                avifImageDestroy(i);
            }
            if !self.encoder.is_null() {
                avifEncoderDestroy(self.encoder);
            }
            avifRWDataFree(&mut self.out);
        }
    }
}

impl AvifCodec for Libaom {
    fn describe(&self) -> String {
        let (a, b, c) = libaom_version();
        format!("libaom {a}.{b}.{c} (tune={})", tune().unwrap_or("default"))
    }

    fn encode(&self, img: &DynamicImage, o: &AvifOptions, icc: Option<&[u8]>, exif: Option<&[u8]>) -> Result<Vec<u8>> {
        // RGB or RGBA, borrowed: libavif converts each cell straight from the decoded pixels
        let converted;
        let (px, channels, format): (&[u8], u32, avifRGBFormat) = match img {
            DynamicImage::ImageRgba8(i) => (i.as_raw(), 4, AVIF_RGB_FORMAT_RGBA),
            DynamicImage::ImageRgb8(i) => (i.as_raw(), 3, AVIF_RGB_FORMAT_RGB),
            other => {
                converted = other.to_rgb8();
                (converted.as_raw(), 3, AVIF_RGB_FORMAT_RGB)
            }
        };
        let (w, h) = (img.width(), img.height());
        let (cw, ch, cols, rows) = grid_for(w, h);
        let mut owned = Owned { images: Vec::new(), encoder: std::ptr::null_mut(), out: unsafe { std::mem::zeroed() } };
        unsafe {
            for r in 0..rows {
                for c in 0..cols {
                    let (x, y) = (c * cw, r * ch);
                    let (tw, th) = (cw.min(w - x), ch.min(h - y));
                    let cell = avifImageCreate(tw, th, 8, AVIF_PIXEL_FORMAT_YUV420);
                    if cell.is_null() {
                        return Err(EngineError::encode("libavif: out of memory"));
                    }
                    owned.images.push(cell);
                    (*cell).yuvRange = AVIF_RANGE_FULL;
                    (*cell).colorPrimaries = AVIF_COLOR_PRIMARIES_BT709 as _;
                    (*cell).transferCharacteristics = AVIF_TRANSFER_CHARACTERISTICS_SRGB as _;
                    (*cell).matrixCoefficients = AVIF_MATRIX_COEFFICIENTS_BT601 as _;
                    if let Some(icc) = icc {
                        check(avifImageSetProfileICC(cell, icc.as_ptr(), icc.len()), "ICC")?;
                    }
                    if let Some(exif) = exif.filter(|_| owned.images.len() == 1) {
                        check(avifImageSetMetadataExif(cell, exif.as_ptr(), exif.len()), "EXIF")?;
                    }
                    let mut rgb: avifRGBImage = std::mem::zeroed();
                    avifRGBImageSetDefaults(&mut rgb, cell);
                    rgb.format = format;
                    rgb.depth = 8;
                    rgb.rowBytes = w * channels;
                    // libavif only reads through this pointer
                    rgb.pixels = px.as_ptr().add(((y * w + x) * channels) as usize) as *mut u8;
                    check(avifImageRGBToYUV(cell, &rgb), "RGB to YUV")?;
                }
            }
            let enc = avifEncoderCreate();
            if enc.is_null() {
                return Err(EngineError::encode("libavif: out of memory"));
            }
            owned.encoder = enc;
            (*enc).codecChoice = AVIF_CODEC_CHOICE_AOM;
            (*enc).quality = native_quality(o.quality);
            (*enc).qualityAlpha = native_quality(o.alpha_quality);
            (*enc).speed = o.speed.clamp(1, 10) as i32;
            (*enc).maxThreads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).min(16) as i32;
            // no AV1 tiles (heif-enc's default too): tile edges block intra prediction and cost
            // up to 20 % at aggressive compression; libaom's row multithreading keeps it fast
            (*enc).autoTiling = 0;
            if let Some(t) = tune() {
                let (k, v) = (CString::new("tune").unwrap(), CString::new(t).unwrap());
                check(avifEncoderSetCodecSpecificOption(enc, k.as_ptr(), v.as_ptr()), "tune")?;
            }
            let cells: Vec<*const avifImage> = owned.images.iter().map(|&i| i as *const avifImage).collect();
            let single = AVIF_ADD_IMAGE_FLAG_SINGLE as avifAddImageFlags;
            if cells.len() == 1 {
                check(avifEncoderAddImage(enc, cells[0], 1, single), "encode")?;
            } else {
                check(avifEncoderAddImageGrid(enc, cols, rows, cells.as_ptr(), single), "encode grid")?;
            }
            check(avifEncoderFinish(enc, &mut owned.out), "finish")?;
            Ok(std::slice::from_raw_parts(owned.out.data, owned.out.size).to_vec())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grids_only_large_even_images() {
        assert_eq!(grid_for(4000, 3000), (4000, 3000, 1, 1));
        assert_eq!(grid_for(6000, 4000), (3000, 2000, 2, 2));
        assert_eq!(grid_for(6001, 4000), (6001, 4000, 1, 1), "odd width cannot be a 4:2:0 grid");
        let (cw, ch, cols, rows) = grid_for(9000, 3000);
        assert!(cw % 2 == 0 && ch % 2 == 0 && cw >= 64 && ch >= 64);
        assert!(cols * cw >= 9000 && rows * ch >= 3000);
        assert!((cw as u64 * ch as u64) <= 7_000_000);
    }

    #[test]
    fn quality_mapping_is_monotonic_and_spans_the_scale() {
        if tune().is_some() {
            assert_eq!(
                (native_quality(0), native_quality(60), native_quality(43), native_quality(100)),
                (0, 52, 33, 100)
            );
        }
        for q in 1..=100u8 {
            assert!(native_quality(q) >= native_quality(q - 1));
        }
    }

    #[test]
    fn links_a_libaom() {
        assert!(libaom_version() >= (3, 9, 0), "{:?}", libaom_version());
    }
}
