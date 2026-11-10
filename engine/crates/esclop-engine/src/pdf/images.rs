// SPDX-License-Identifier: GPL-3.0-or-later
//! Image XObjects: downsample to the target resolution, then store each as the smaller of a
//! JPEG at the compression factor's ceiling and lossless Flate with PNG predictors. The colour
//! space, `/Decode`, `/SMask`, `/Intent` and every other key stay as they are; only the samples'
//! encoding (and, when downsampled, `/Width` and `/Height`) changes.
//!
//! JPEG is only used where a reader would interpret the new samples exactly like the old ones:
//! 8-bit (or 16-bit, reduced to 8) gray, RGB or CMYK in a device, calibrated or ICC-based space,
//! never for masks, colour-keyed images, indexed, separation, DeviceN or Lab images.

use super::{deflate, mono};
use crate::codec::jpeg::{self, EncodeOptions, Layout, TranscodeOptions};
use crate::error::{EngineError, Result};
use crate::meta::JpegParts;
use fast_image_resize as fr;
use lopdf::{Dictionary, Document, Object, Stream};

/// Largest image the engine decodes (as for still images).
const MAX_PIXELS: u64 = 256_000_000;

#[derive(Debug, Clone, Copy)]
pub struct ImagePlan {
    /// libjpeg-scale quality ceiling.
    pub jpeg_quality: u8,
    /// Target resolution; images drawn denser than this are downsampled to it.
    pub dpi: Option<f64>,
    /// Lowest effective resolution the image is drawn at, if known.
    pub drawn_dpi: Option<f64>,
    /// The image is some other image's `/SMask` or `/Mask`: never lossy.
    pub is_mask: bool,
    /// Re-encode JPEGs above the quality ceiling (else only downsampling re-encodes them).
    pub reencode_jpeg: bool,
}

/// What a colour space allows.
#[derive(Debug, Clone, Copy, PartialEq)]
enum Space {
    /// Gray, RGB or CMYK samples a JPEG can carry: (components).
    Jpegable(usize),
    /// Anything else with a known component count: lossless only.
    Other(usize),
}

fn resolve<'a>(doc: &'a Document, o: &'a Object) -> &'a Object {
    match o {
        Object::Reference(id) => doc.get_object(*id).map(|o| resolve(doc, o)).unwrap_or(o),
        o => o,
    }
}

fn space(doc: &Document, cs: Option<&Object>) -> Option<Space> {
    let cs = resolve(doc, cs?);
    match cs {
        Object::Name(n) => match n.as_slice() {
            b"DeviceGray" | b"G" | b"CalGray" => Some(Space::Jpegable(1)),
            b"DeviceRGB" | b"RGB" | b"CalRGB" => Some(Space::Jpegable(3)),
            b"DeviceCMYK" | b"CMYK" => Some(Space::Jpegable(4)),
            _ => None,
        },
        Object::Array(a) => {
            let kind = a.first().and_then(|k| k.as_name().ok())?;
            match kind {
                b"ICCBased" => {
                    let s = resolve(doc, a.get(1)?).as_stream().ok()?;
                    match s.dict.get(b"N").and_then(|n| n.as_i64()).ok()? {
                        n @ (1 | 3 | 4) => Some(Space::Jpegable(n as usize)),
                        n => Some(Space::Other(n as usize)),
                    }
                }
                b"CalGray" => Some(Space::Jpegable(1)),
                b"CalRGB" => Some(Space::Jpegable(3)),
                b"Lab" => Some(Space::Other(3)),
                b"Indexed" | b"I" | b"Separation" => Some(Space::Other(1)),
                b"DeviceN" => Some(Space::Other(resolve(doc, a.get(1)?).as_array().ok()?.len())),
                _ => None,
            }
        }
        _ => None,
    }
}

fn int(d: &Dictionary, k: &[u8]) -> Option<i64> {
    d.get(k).and_then(|o| o.as_i64()).ok()
}

fn layout(comps: usize) -> Layout {
    match comps {
        1 => Layout::Gray,
        4 => Layout::Cmyk,
        _ => Layout::Rgb,
    }
}

/// The new stream for an image and whether its pixels changed, or None to keep it as it is.
pub fn recompress(doc: &Document, stream: &Stream, plan: &ImagePlan) -> Result<Option<(Stream, bool)>> {
    let d = &stream.dict;
    let (Some(w), Some(h)) = (int(d, b"Width"), int(d, b"Height")) else { return Ok(None) };
    if w <= 0 || h <= 0 || (w as u64) * (h as u64) > MAX_PIXELS {
        return Ok(None);
    }
    let (w, h) = (w as u32, h as u32);
    let filters: Vec<Vec<u8>> = stream.filters().map(|f| f.iter().map(|n| n.to_vec()).collect()).unwrap_or_default();
    let stencil = d.get(b"ImageMask").and_then(|o| o.as_bool()).unwrap_or(false);
    let colour_key = matches!(d.get(b"Mask"), Ok(Object::Array(_)));
    let has_decode_parms = d.has(b"DecodeParms");
    let bpc = if stencil { 1 } else { int(d, b"BitsPerComponent").unwrap_or(8) };
    let space = if stencil { Some(Space::Other(1)) } else { space(doc, d.get(b"ColorSpace").ok()) };
    let lossy_ok = !plan.is_mask && !colour_key && !stencil;
    let scale = match (plan.dpi, plan.drawn_dpi) {
        (Some(target), Some(drawn)) if drawn > target * 1.05 => target / drawn,
        _ => 1.0,
    };

    // JPEG in: re-encode when it is above the ceiling or needs downsampling, else optimise the
    // Huffman coding losslessly.
    if filters.len() == 1 && filters[0] == b"DCTDecode" {
        let original = &stream.content;
        let lossless = || -> Option<Vec<u8>> {
            jpeg::codec().transcode(original, &TranscodeOptions { progressive: true, markers: &[] }).ok()
        };
        let best: Option<Vec<u8>> = lossless().filter(|t| t.len() < original.len());
        let jpegable = matches!(space, Some(Space::Jpegable(_))) && lossy_ok && !has_decode_parms;
        let est =
            JpegParts::parse(original).ok().and_then(|p| p.luma_qtable()).map(|t| jpeg::codec().estimate_quality(&t));
        let above = plan.reencode_jpeg && est.is_some_and(|q| q > plan.jpeg_quality);
        if jpegable && (above || scale < 1.0) {
            let raw = jpeg::decode_samples(original, MAX_PIXELS)?;
            if raw.width == w && raw.height == h && space == Some(Space::Jpegable(raw.layout.components())) {
                let comps = raw.layout.components();
                let (px, nw, nh) = resample(raw.pixels, w, h, comps, scale)?;
                let enc = encode_jpeg(&px, nw, nh, raw.layout, plan.jpeg_quality)?;
                if enc.len() < best.as_ref().map_or(original.len(), |b| b.len()) {
                    return Ok(Some((with_jpeg(d, enc, nw, nh), true)));
                }
            }
        }
        return Ok(best.map(|b| (Stream::new(d.clone(), b), false)));
    }

    // Everything lopdf can decode (Flate, LZW, RunLength, ASCII filters, none).
    let decodable = filters.iter().all(|f| decodable_filter(f));
    if bpc == 1 && (stencil || space == Some(Space::Jpegable(1))) {
        return mono_image(stream, &filters, decodable, w, h, plan, lossy_ok);
    }
    let Some(space) = space else { return Ok(None) };
    let comps = match space {
        Space::Jpegable(n) | Space::Other(n) => n,
    };
    if !decodable || !matches!(bpc, 1 | 2 | 4 | 8 | 16) {
        return Ok(None);
    }
    let row_bytes = (w as usize * comps * bpc as usize).div_ceil(8);
    let need = row_bytes * h as usize;
    let Ok(mut samples) = stream.decompressed_content_with_limit(need + row_bytes + 1024) else { return Ok(None) };
    if samples.len() < need {
        return Ok(None);
    }
    samples.truncate(need);
    let original_len = stream.content.len();

    let jpegable = matches!(space, Space::Jpegable(_)) && lossy_ok && (bpc == 8 || bpc == 16);
    let mut out_bpc = bpc;
    let (mut px, mut nw, mut nh) = (samples, w, h);
    if jpegable {
        if bpc == 16 {
            px = px.as_chunks::<2>().0.iter().map(|c| c[0]).collect();
            out_bpc = 8;
        }
        (px, nw, nh) = resample(px, w, h, comps, scale)?;
    }
    let out_row = (nw as usize * comps * out_bpc as usize).div_ceil(8);
    let bpp = (comps * out_bpc as usize).div_ceil(8).max(1);
    let filtered = deflate::png_filter(&px, out_row, bpp);
    let mut lossless = None;
    if jpegable {
        let enc = encode_jpeg(&px, nw, nh, layout(comps), plan.jpeg_quality)?;
        // JPEG must clearly beat lossless: flat graphics and text stay sharp. A fast deflate
        // settles most images; the strong one only runs when it could change the answer.
        let quick = deflate::zlib(&filtered, 4);
        let strong = if enc.len() * 2 < quick.len() {
            quick
        } else {
            deflate::zlib(&filtered, if filtered.len() > 1 << 20 { 9 } else { 12 })
        };
        if enc.len() < original_len && enc.len() * 4 < strong.len() * 3 {
            return Ok(Some((with_jpeg(d, enc, nw, nh), true)));
        }
        lossless = Some(strong);
    }
    // Level 12 gains a few percent over 9 at a fraction of the speed: small images only.
    let lossless = lossless.unwrap_or_else(|| deflate::zlib(&filtered, if filtered.len() > 1 << 20 { 9 } else { 12 }));
    // Lossless output changes size or depth only where lossy output was allowed.
    if lossless.len() < original_len && (jpegable || (nw == w && nh == h && out_bpc == bpc)) {
        let mut nd = d.clone();
        nd.set("Width", nw as i64);
        nd.set("Height", nh as i64);
        nd.set("BitsPerComponent", out_bpc);
        nd.set("Filter", Object::Name(b"FlateDecode".to_vec()));
        let mut parms = Dictionary::new();
        parms.set("Predictor", 15);
        parms.set("Colors", comps as i64);
        parms.set("BitsPerComponent", out_bpc);
        parms.set("Columns", nw as i64);
        nd.set("DecodeParms", Object::Dictionary(parms));
        return Ok(Some((Stream::new(nd, lossless), nw != w || nh != h || out_bpc != bpc)));
    }
    Ok(None)
}

fn decodable_filter(f: &[u8]) -> bool {
    matches!(
        f,
        b"FlateDecode"
            | b"Fl"
            | b"LZWDecode"
            | b"LZW"
            | b"RunLengthDecode"
            | b"RL"
            | b"ASCII85Decode"
            | b"A85"
            | b"ASCIIHexDecode"
            | b"AHx"
    )
}

/// 1-bit gray images and stencil masks: stored as the smaller of CCITT Group 4 and Flate, and
/// where lossy output is allowed and a target resolution is set, downsampled to 300 dpi (what
/// Ghostscript's `MonoImageResolution` of at least 300 did).
fn mono_image(
    stream: &Stream,
    filters: &[Vec<u8>],
    decodable: bool,
    w: u32,
    h: u32,
    plan: &ImagePlan,
    lossy_ok: bool,
) -> Result<Option<(Stream, bool)>> {
    let d = &stream.dict;
    let samples = if filters.len() == 1 && matches!(filters[0].as_slice(), b"CCITTFaxDecode" | b"CCF") {
        let parms = match d.get(b"DecodeParms") {
            Ok(Object::Dictionary(p)) => Some(p),
            Ok(Object::Array(a)) => a.first().and_then(|p| p.as_dict().ok()),
            _ => None,
        };
        let get = |k: &[u8]| parms.and_then(|p| p.get(k).ok());
        let k = get(b"K").and_then(|o| o.as_i64().ok()).unwrap_or(0);
        let columns = get(b"Columns").and_then(|o| o.as_i64().ok()).unwrap_or(1728);
        let aligned = get(b"EncodedByteAlign").and_then(|o| o.as_bool().ok()).unwrap_or(false);
        let black_is_1 = get(b"BlackIs1").and_then(|o| o.as_bool().ok()).unwrap_or(false);
        if k >= 0 || columns != w as i64 || aligned {
            return Ok(None);
        }
        match mono::decode_g4(&stream.content, w, h, black_is_1) {
            Some(s) => s,
            None => return Ok(None),
        }
    } else if decodable {
        let need = (w as usize).div_ceil(8) * h as usize;
        let Ok(packed) = stream.decompressed_content_with_limit(need + 1024) else { return Ok(None) };
        if packed.len() < need {
            return Ok(None);
        }
        mono::unpack(&packed, w, h)
    } else {
        return Ok(None);
    };
    let (px, nw, nh) = match (plan.dpi, plan.drawn_dpi) {
        (Some(_), Some(drawn)) if lossy_ok && drawn > 300.0 * 1.05 => {
            let scale = 300.0 / drawn;
            let nw = ((w as f64 * scale).round() as u32).max(1);
            let nh = ((h as f64 * scale).round() as u32).max(1);
            (mono::downsample(&samples, w, h, nw, nh), nw, nh)
        }
        _ => (samples, w, h),
    };
    let g4 = mono::encode_g4(&px, nw, nh);
    let row = (nw as usize).div_ceil(8);
    let flate = deflate::zlib(&deflate::png_filter(&mono::pack(&px, nw), row, 1), 12);
    let mut nd = d.clone();
    nd.set("Width", nw as i64);
    nd.set("Height", nh as i64);
    nd.set("BitsPerComponent", 1);
    let mut parms = Dictionary::new();
    let data = match g4 {
        Some(g4) if g4.len() <= flate.len() => {
            nd.set("Filter", Object::Name(b"CCITTFaxDecode".to_vec()));
            parms.set("K", -1);
            parms.set("Columns", nw as i64);
            parms.set("Rows", nh as i64);
            parms.set("BlackIs1", false);
            g4
        }
        _ => {
            nd.set("Filter", Object::Name(b"FlateDecode".to_vec()));
            parms.set("Predictor", 15);
            parms.set("Colors", 1);
            parms.set("BitsPerComponent", 1);
            parms.set("Columns", nw as i64);
            flate
        }
    };
    nd.set("DecodeParms", Object::Dictionary(parms));
    if data.len() >= stream.content.len() {
        return Ok(None);
    }
    Ok(Some((Stream::new(nd, data), nw != w)))
}

fn with_jpeg(d: &Dictionary, data: Vec<u8>, w: u32, h: u32) -> Stream {
    let mut nd = d.clone();
    nd.set("Filter", Object::Name(b"DCTDecode".to_vec()));
    nd.remove(b"DecodeParms");
    nd.set("BitsPerComponent", 8);
    nd.set("Width", w as i64);
    nd.set("Height", h as i64);
    Stream::new(nd, data)
}

fn encode_jpeg(px: &[u8], w: u32, h: u32, layout: Layout, quality: u8) -> Result<Vec<u8>> {
    jpeg::codec().encode(
        px,
        w,
        h,
        layout,
        &EncodeOptions { quality, progressive: true, fast_scans: true, markers: &[] },
    )
}

/// Downsamples 8-bit interleaved samples by `scale` (< 1) with Catmull-Rom, like Ghostscript's
/// bicubic downsampling. Returns the input when `scale` is 1.
fn resample(px: Vec<u8>, w: u32, h: u32, comps: usize, scale: f64) -> Result<(Vec<u8>, u32, u32)> {
    if scale >= 1.0 {
        return Ok((px, w, h));
    }
    let nw = ((w as f64 * scale).round() as u32).max(1);
    let nh = ((h as f64 * scale).round() as u32).max(1);
    let pt = match comps {
        1 => fr::PixelType::U8,
        3 => fr::PixelType::U8x3,
        4 => fr::PixelType::U8x4,
        _ => return Ok((px, w, h)),
    };
    let err = |e: &dyn std::fmt::Display| EngineError::internal(format!("resize: {e}"));
    let src = fr::images::ImageRef::new(w, h, &px, pt).map_err(|e| err(&e))?;
    let mut dst = fr::images::Image::new(nw, nh, pt);
    // CMYK is four colour channels, not RGBA: no alpha handling.
    let opts =
        fr::ResizeOptions::new().resize_alg(fr::ResizeAlg::Convolution(fr::FilterType::CatmullRom)).use_alpha(false);
    fr::Resizer::new().resize(&src, &mut dst, &opts).map_err(|e| err(&e))?;
    Ok((dst.into_vec(), nw, nh))
}
