// SPDX-License-Identifier: GPL-3.0-or-later
//! JPEG encoding behind a trait, so the codec can change (mozjpeg today; jpegli is the candidate).
//!
//! The mozjpeg implementation talks to `mozjpeg-sys` directly: the safe `mozjpeg` wrapper exposes
//! neither lossless transcoding (`jpeg_read_coefficients`/`jpeg_write_coefficients`) nor
//! sequential mode with trellis quantisation. libjpeg reports fatal errors through `error_exit`,
//! which here unwinds (mozjpeg-sys builds the C code with unwinding support); every entry point
//! catches that and turns it into an engine error.

use crate::error::{EngineError, Result};
use mozjpeg_sys::*;
use std::os::raw::{c_int, c_uint, c_ulong};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::sync::OnceLock;

/// Pixel layout handed to the encoder.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Layout {
    Rgb,
    Gray,
}

#[derive(Debug, Clone)]
pub struct EncodeOptions<'a> {
    pub quality: u8,
    pub progressive: bool,
    /// Progressive with the standard scan script instead of mozjpeg's scan search: within a few
    /// percent of the final size at a fraction of the memory (used by `fit`'s probes).
    pub fast_scans: bool,
    /// APPn/COM markers written after the JFIF header: (marker code, payload).
    pub markers: &'a [(u8, Vec<u8>)],
}

#[derive(Debug, Clone)]
pub struct TranscodeOptions<'a> {
    pub progressive: bool,
    /// APPn/COM markers to write instead of the source's (the caller filters them).
    pub markers: &'a [(u8, Vec<u8>)],
}

pub trait JpegCodec: Send + Sync {
    fn name(&self) -> &'static str;
    /// Encodes 8-bit RGB or gray pixels.
    fn encode(&self, pixels: &[u8], width: u32, height: u32, layout: Layout, opts: &EncodeOptions) -> Result<Vec<u8>>;
    /// Recompresses without touching the DCT coefficients.
    fn transcode(&self, jpeg: &[u8], opts: &TranscodeOptions) -> Result<Vec<u8>>;
    /// Estimates the quality a file was saved at, on this codec's 0..=100 scale.
    fn estimate_quality(&self, luma_table: &[u16; 64]) -> u8;
}

/// The codec the engine uses.
pub fn codec() -> &'static dyn JpegCodec {
    static C: Mozjpeg = Mozjpeg;
    &C
}

pub struct Mozjpeg;

/// libjpeg (jpegoptim) quality -> mozjpeg quality giving the same SSIMULACRA2, the median over
/// the calibration corpus (bench/calibrate_jpeg.py). mozjpeg's trellis quantisation removes
/// fine texture at a given nominal quality, so it needs a higher number to look the same.
/// Between rows the mapping is linear; it is monotonic, so the inverse is well defined.
/// Calibrated on photo-like content (the 95 row is extrapolated: the corpus had no source above
/// q92 to re-encode at 95). Screenshots need less than this; JPEG is for photos.
const LIBJPEG_TO_MOZJPEG: &[(u8, u8)] = &[
    (1, 1),
    (18, 18),
    (25, 25),
    (35, 39),
    (42, 49),
    (50, 58),
    (58, 68),
    (65, 71),
    (70, 74),
    (75, 80),
    (80, 83),
    (85, 90),
    (90, 95),
    (100, 100),
];

impl Mozjpeg {
    /// The mozjpeg quality used for a libjpeg-scale quality.
    pub fn native_quality(q: u8) -> u8 {
        let q = q.clamp(1, 100);
        let t = LIBJPEG_TO_MOZJPEG;
        let i = t.iter().position(|r| r.0 >= q).unwrap_or(t.len() - 1);
        if t[i].0 == q || i == 0 {
            return t[i].1;
        }
        let ((a, na), (b, nb)) = (t[i - 1], t[i]);
        let f = (q - a) as f64 / (b - a) as f64;
        (na as f64 + f * (nb as f64 - na as f64)).round().clamp(1.0, 100.0) as u8
    }

    /// The lowest libjpeg-scale quality that maps to at least `native`: never above the quality
    /// a file was written at, so a re-optimised file is never re-encoded at the same ceiling.
    pub fn libjpeg_equivalent(native: u8) -> u8 {
        (1..=100).find(|&q| Self::native_quality(q) >= native).unwrap_or(100)
    }

    /// Encodes at a mozjpeg-scale quality (calibration and tests).
    pub fn encode_native(
        &self,
        pixels: &[u8],
        width: u32,
        height: u32,
        layout: Layout,
        opts: &EncodeOptions,
    ) -> Result<Vec<u8>> {
        let comps = if layout == Layout::Rgb { 3 } else { 1 };
        if width == 0 || height == 0 || pixels.len() < (width as usize) * (height as usize) * comps {
            return Err(EngineError::internal("jpeg encode: pixel buffer does not match the size"));
        }
        if width > 65500 || height > 65500 {
            return Err(EngineError::unsupported("JPEG is limited to 65500 pixels per side"));
        }
        guarded(|| unsafe { encode_unchecked(pixels, width, height, layout, opts) })
    }
}

impl JpegCodec for Mozjpeg {
    fn name(&self) -> &'static str {
        "mozjpeg"
    }

    /// `opts.quality` is on the libjpeg scale.
    fn encode(&self, pixels: &[u8], width: u32, height: u32, layout: Layout, opts: &EncodeOptions) -> Result<Vec<u8>> {
        let native = EncodeOptions { quality: Self::native_quality(opts.quality), ..opts.clone() };
        self.encode_native(pixels, width, height, layout, &native)
    }

    fn transcode(&self, jpeg: &[u8], opts: &TranscodeOptions) -> Result<Vec<u8>> {
        guarded(|| unsafe { transcode_unchecked(jpeg, opts) })
    }

    /// On the libjpeg scale: a file with IJG tables (cameras, most apps, jpegoptim) estimates as
    /// its libjpeg quality; one with mozjpeg's tables (what this engine writes) is translated
    /// back through the calibration.
    fn estimate_quality(&self, luma: &[u16; 64]) -> u8 {
        let [ijg, moz] = reference_tables();
        let best = |family: &Vec<[u16; 64]>| {
            let mut best = (u64::MAX, 100u8);
            for (i, t) in family.iter().enumerate() {
                let err: u64 = t.iter().zip(luma).map(|(a, b)| (*a as i64 - *b as i64).unsigned_abs()).sum();
                let q = i as u8 + 1;
                // ties go to the higher quality, so a re-optimised file is never judged worse
                if err < best.0 || (err == best.0 && q > best.1) {
                    best = (err, q);
                }
            }
            best
        };
        let (ei, qi) = best(ijg);
        let (em, qm) = best(moz);
        if em < ei { Self::libjpeg_equivalent(qm) } else { qi }
    }
}

/// Runs libjpeg code, turning its unwinding fatal errors into `EngineError`s.
fn guarded<T>(f: impl FnOnce() -> Result<T>) -> Result<T> {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(r) => r,
        Err(payload) => {
            let msg = payload
                .downcast_ref::<String>()
                .cloned()
                .or_else(|| payload.downcast_ref::<&str>().map(|s| s.to_string()))
                .unwrap_or_else(|| "libjpeg error".into());
            Err(EngineError::decode(msg))
        }
    }
}

extern "C-unwind" fn error_exit(cinfo: &mut jpeg_common_struct) {
    let msg = unsafe {
        let mut buf = [0u8; 80];
        let err = &*cinfo.err;
        match err.format_message {
            Some(fmt) => {
                let f: unsafe extern "C-unwind" fn(&mut jpeg_common_struct, &mut [u8; 80]) = std::mem::transmute(fmt);
                f(cinfo, &mut buf);
                let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
                String::from_utf8_lossy(&buf[..end]).into_owned()
            }
            None => format!("libjpeg error {}", err.msg_code),
        }
    };
    std::panic::resume_unwind(Box::new(format!("JPEG: {msg}")));
}

extern "C-unwind" fn emit_message(_cinfo: &mut jpeg_common_struct, _level: c_int) {}

fn error_mgr() -> Box<jpeg_error_mgr> {
    unsafe {
        let mut err: Box<jpeg_error_mgr> = Box::new(std::mem::zeroed());
        jpeg_std_error(&mut err);
        err.error_exit = Some(error_exit);
        err.emit_message = Some(emit_message);
        err
    }
}

/// Owns a compress struct and its malloc'd memory destination; cleans up on drop, which also
/// runs while unwinding out of a libjpeg error.
struct Compressor {
    cinfo: Box<jpeg_compress_struct>,
    _err: Box<jpeg_error_mgr>,
    out: Box<(*mut u8, c_ulong)>,
}

impl Compressor {
    unsafe fn new() -> Self {
        unsafe {
            let mut err = error_mgr();
            let mut cinfo: Box<jpeg_compress_struct> = Box::new(std::mem::zeroed());
            cinfo.common.err = &mut *err;
            jpeg_create_compress(&mut *cinfo);
            let mut out = Box::new((ptr::null_mut::<u8>(), 0 as c_ulong));
            jpeg_mem_dest(&mut cinfo, &mut out.0, &mut out.1);
            Self { cinfo, _err: err, out }
        }
    }

    fn bytes(&self) -> Vec<u8> {
        if self.out.0.is_null() {
            return Vec::new();
        }
        unsafe { std::slice::from_raw_parts(self.out.0, self.out.1 as usize).to_vec() }
    }

    unsafe fn set_scans(&mut self, progressive: bool, search: bool) {
        unsafe {
            if progressive {
                // the scan script mozjpeg generates depends on this flag: set it first
                jpeg_c_set_bool_param(&mut self.cinfo, J_BOOLEAN_PARAM::JBOOLEAN_OPTIMIZE_SCANS, search as boolean);
                jpeg_simple_progression(&mut self.cinfo);
            } else {
                self.cinfo.num_scans = 0;
                self.cinfo.scan_info = ptr::null();
                jpeg_c_set_bool_param(&mut self.cinfo, J_BOOLEAN_PARAM::JBOOLEAN_OPTIMIZE_SCANS, 0);
            }
            self.cinfo.optimize_coding = 1;
        }
    }

    unsafe fn write_markers(&mut self, markers: &[(u8, Vec<u8>)]) {
        for (m, d) in markers {
            if d.len() <= 65533 {
                unsafe { jpeg_write_marker(&mut self.cinfo, *m as c_int, d.as_ptr(), d.len() as c_uint) };
            }
        }
    }
}

impl Drop for Compressor {
    fn drop(&mut self) {
        unsafe {
            jpeg_destroy_compress(&mut self.cinfo);
            if !self.out.0.is_null() {
                libc::free(self.out.0.cast());
            }
        }
    }
}

struct Decompressor {
    dinfo: Box<jpeg_decompress_struct>,
    _err: Box<jpeg_error_mgr>,
}

impl Drop for Decompressor {
    fn drop(&mut self) {
        unsafe { jpeg_destroy_decompress(&mut self.dinfo) };
    }
}

unsafe fn encode_unchecked(
    pixels: &[u8],
    width: u32,
    height: u32,
    layout: Layout,
    opts: &EncodeOptions,
) -> Result<Vec<u8>> {
    unsafe {
        let mut c = Compressor::new();
        let comps = if layout == Layout::Rgb { 3 } else { 1 };
        c.cinfo.image_width = width;
        c.cinfo.image_height = height;
        c.cinfo.input_components = comps as c_int;
        c.cinfo.in_color_space =
            if layout == Layout::Rgb { J_COLOR_SPACE::JCS_RGB } else { J_COLOR_SPACE::JCS_GRAYSCALE };
        jpeg_set_defaults(&mut c.cinfo);
        jpeg_set_quality(&mut c.cinfo, opts.quality.clamp(1, 100) as c_int, 1);
        c.set_scans(opts.progressive, !opts.fast_scans);
        jpeg_start_compress(&mut c.cinfo, 1);
        c.write_markers(opts.markers);
        let stride = width as usize * comps;
        while c.cinfo.next_scanline < c.cinfo.image_height {
            let row = pixels[c.cinfo.next_scanline as usize * stride..].as_ptr();
            let rows = [row];
            jpeg_write_scanlines(&mut c.cinfo, rows.as_ptr(), 1);
        }
        jpeg_finish_compress(&mut c.cinfo);
        Ok(c.bytes())
    }
}

unsafe fn transcode_unchecked(jpeg: &[u8], opts: &TranscodeOptions) -> Result<Vec<u8>> {
    unsafe {
        let mut err = error_mgr();
        let mut dinfo: Box<jpeg_decompress_struct> = Box::new(std::mem::zeroed());
        dinfo.common.err = &mut *err;
        jpeg_create_decompress(&mut *dinfo);
        let mut d = Decompressor { dinfo, _err: err };
        jpeg_mem_src(&mut d.dinfo, jpeg.as_ptr(), jpeg.len() as c_ulong);
        jpeg_read_header(&mut d.dinfo, 1);
        let coefs = jpeg_read_coefficients(&mut d.dinfo);
        if coefs.is_null() {
            return Err(EngineError::decode("JPEG: could not read coefficients"));
        }
        let mut c = Compressor::new();
        jpeg_copy_critical_parameters(&d.dinfo, &mut c.cinfo);
        c.set_scans(opts.progressive, true);
        jpeg_write_coefficients(&mut c.cinfo, coefs);
        c.write_markers(opts.markers);
        jpeg_finish_compress(&mut c.cinfo);
        jpeg_finish_decompress(&mut d.dinfo);
        Ok(c.bytes())
    }
}

/// Luminance tables mozjpeg produces at qualities 1..=100, for the IJG (Annex K) base table and
/// for mozjpeg's default base table, read from the library rather than copied.
fn reference_tables() -> &'static [Vec<[u16; 64]>; 2] {
    static T: OnceLock<[Vec<[u16; 64]>; 2]> = OnceLock::new();
    T.get_or_init(|| {
        let family = |base: c_int| -> Vec<[u16; 64]> {
            guarded(|| unsafe {
                let mut c = Compressor::new();
                c.cinfo.in_color_space = J_COLOR_SPACE::JCS_RGB;
                c.cinfo.input_components = 3;
                jpeg_set_defaults(&mut c.cinfo);
                let mut v = Vec::with_capacity(100);
                for q in 1..=100 {
                    if base >= 0 {
                        jpeg_c_set_int_param(&mut c.cinfo, J_INT_PARAM::JINT_BASE_QUANT_TBL_IDX, base);
                    }
                    jpeg_set_quality(&mut c.cinfo, q, 1);
                    let t = &*c.cinfo.quant_tbl_ptrs[0];
                    v.push(t.quantval);
                }
                Ok(v)
            })
            .unwrap_or_default()
        };
        [family(0), family(-1)]
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gradient(w: u32, h: u32) -> Vec<u8> {
        (0..w * h).flat_map(|i| [(i % w * 255 / w) as u8, (i / w * 255 / h) as u8, 128]).collect()
    }

    #[test]
    fn encode_and_estimate_round_trip() {
        let px = gradient(64, 48);
        for q in [18u8, 40, 58, 85, 95] {
            let out = codec()
                .encode(
                    &px,
                    64,
                    48,
                    Layout::Rgb,
                    &EncodeOptions { quality: q, progressive: true, fast_scans: false, markers: &[] },
                )
                .unwrap();
            let parts = crate::meta::JpegParts::parse(&out).unwrap();
            assert!(parts.progressive());
            let est = codec().estimate_quality(&parts.luma_qtable().unwrap());
            // never above (no re-encode loop), never far below (no needless lossless-only)
            assert!(est <= q && est + 3 >= q, "estimate {est} for q{q}");
        }
    }

    #[test]
    fn calibration_is_monotonic_and_invertible() {
        for q in 2..=100u8 {
            assert!(Mozjpeg::native_quality(q) >= Mozjpeg::native_quality(q - 1));
        }
        for q in 1..=100u8 {
            assert!(Mozjpeg::libjpeg_equivalent(Mozjpeg::native_quality(q)) <= q);
        }
    }

    #[test]
    fn ijg_tables_estimate_exactly() {
        // what libjpeg, cameras and jpegoptim write
        for q in [50u8, 75, 85, 92] {
            let mut out = Vec::new();
            image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, q)
                .encode(&gradient(32, 32), 32, 32, image::ExtendedColorType::Rgb8)
                .unwrap();
            let parts = crate::meta::JpegParts::parse(&out).unwrap();
            assert_eq!(codec().estimate_quality(&parts.luma_qtable().unwrap()), q);
        }
    }

    #[test]
    fn transcode_is_lossless_and_survives_garbage() {
        let px = gradient(80, 60);
        let base = codec()
            .encode(
                &px,
                80,
                60,
                Layout::Rgb,
                &EncodeOptions { quality: 90, progressive: false, fast_scans: false, markers: &[] },
            )
            .unwrap();
        let t = codec().transcode(&base, &TranscodeOptions { progressive: true, markers: &[] }).unwrap();
        let a = image::load_from_memory(&base).unwrap().to_rgb8();
        let b = image::load_from_memory(&t).unwrap().to_rgb8();
        assert_eq!(a.as_raw(), b.as_raw());
        let err = codec().transcode(b"\xFF\xD8\xFF\xE0garbage", &TranscodeOptions { progressive: true, markers: &[] });
        assert!(err.is_err());
    }
}
