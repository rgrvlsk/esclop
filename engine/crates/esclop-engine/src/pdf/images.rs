// SPDX-License-Identifier: GPL-3.0-or-later
//! Image XObjects: downsample to the target resolution, then store each as the smaller of a
//! JPEG at the compression factor's ceiling and lossless Flate with PNG predictors. The colour
//! space, `/Decode`, `/SMask`, `/Intent` and every other key stay as they are; only the samples'
//! encoding (and, when downsampled, `/Width` and `/Height`) changes.
//!
//! JPEG is only used where a reader would interpret the new samples exactly like the old ones:
//! 8-bit (or 16-bit, reduced to 8) gray, RGB or CMYK in a device, calibrated or ICC-based space,
//! never for masks, colour-keyed images, indexed, separation, DeviceN or Lab images.

use super::budget::Budget;
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
    /// Lowest SSIM (7x7 window, mean over channels) a lossy encode may have against the samples
    /// it replaces; below it, `encode_checked` tries harder or gives up.
    pub min_ssim: f64,
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
pub fn recompress(doc: &Document, stream: &Stream, plan: &ImagePlan, budget: &Budget) -> Result<Option<(Stream, bool)>> {
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
    if filters.len() == 1 && filters[0] == b"JPXDecode" {
        return jpx_image(stream, w, h, space, plan, lossy_ok, budget);
    }
    // Working set: the samples about five times over (decoded, resampled or filtered, encoded,
    // and the encode decoded again and smoothed for the fidelity check).
    let comps_est = match space {
        Some(Space::Jpegable(n) | Space::Other(n)) => n.max(1),
        None => 4,
    };
    let cost = (w as usize) * (h as usize) * comps_est * (bpc.max(8) as usize / 8) * 5 + stream.content.len() * 2;
    let Some(_hold) = budget.hold(cost)? else { return Ok(None) };
    let scale = match (plan.dpi, plan.drawn_dpi) {
        (Some(target), Some(drawn)) if drawn > target * DOWNSAMPLE_THRESHOLD => target / drawn,
        _ => 1.0,
    };

    // JPEG in: re-encode when it is above the ceiling or needs downsampling, else optimise the
    // Huffman coding losslessly.
    if filters.len() == 1 && filters[0] == b"DCTDecode" {
        let original = &stream.content;
        // The JPEG's own frame must be the image the PDF declares: a frame larger than
        // `/Width` x `/Height` (a 65280-row placeholder height, say) would be decoded in full.
        let parts = JpegParts::parse(original).ok();
        if parts.as_ref().and_then(|p| p.dimensions()) != Some((w, h)) {
            return Ok(None);
        }
        let lossless = || -> Option<Vec<u8>> {
            // CoreGraphics draws a progressive transcode of a very large JPEG differently from the
            // baseline original (pdf.js large_jpeg_downscale, 40000 px wide: SSIM 0.855, while
            // libjpeg decodes both to identical pixels): past 16384 px the mode is kept.
            let progressive = parts.as_ref().is_some_and(|p| p.progressive()) || (w <= 16384 && h <= 16384);
            jpeg::codec().transcode(original, &TranscodeOptions { progressive, markers: &[] }).ok()
        };
        let best: Option<Vec<u8>> = lossless().filter(|t| t.len() < original.len());
        let jpegable = matches!(space, Some(Space::Jpegable(_))) && lossy_ok && !has_decode_parms;
        let est = parts.and_then(|p| p.luma_qtable()).map(|t| jpeg::codec().estimate_quality(&t));
        let above = plan.reencode_jpeg && est.is_some_and(|q| q > plan.jpeg_quality);
        if jpegable && (above || scale < 1.0) {
            let raw = jpeg::decode_samples(original, u64::from(w) * u64::from(h))?;
            if raw.width == w && raw.height == h && space == Some(Space::Jpegable(raw.layout.components())) {
                let comps = raw.layout.components();
                let Some(r) = view_ref(&raw.pixels, w, h, comps, plan)? else {
                    return Ok(best.map(|b| (Stream::new(d.clone(), b), false)));
                };
                let checked = checked_scale(&raw.pixels, w, h, comps, scale, plan, &r)?;
                let src = (checked < 1.0).then(|| raw.pixels.clone());
                let (px, nw, nh) = resample(raw.pixels, w, h, comps, checked)?;
                let limit = best.as_ref().map_or(original.len(), |b| b.len());
                let mut chosen = encode_checked(&px, nw, nh, raw.layout, plan, &r, limit)?.map(|e| (e, nw, nh));
                if let Some(src) = src
                    && (chosen.is_none() || checked > scale)
                {
                    chosen = larger_scales(&src, w, h, raw.layout, plan, &r, checked, chosen, limit, above)?;
                }
                if let Some((enc, nw, nh)) = chosen {
                    return Ok(Some((with_jpeg(d, enc, nw, nh), true)));
                }
            }
        }
        return Ok(best.map(|b| (Stream::new(d.clone(), b), false)));
    }

    // Everything lopdf can decode (Flate, LZW, RunLength, ASCII filters, none).
    let decodable = filters.iter().all(|f| decodable_filter(f));
    if bpc == 1 && (stencil || space == Some(Space::Jpegable(1))) {
        return mono_image(doc, stream, &filters, decodable, w, h, plan, lossy_ok);
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
    let Some(mut samples) = strict_samples(doc, stream, &filters, need + row_bytes + 1024) else { return Ok(None) };
    if samples.len() < need {
        return Ok(None);
    }
    samples.truncate(need);
    let original_len = stream.content.len();

    let jpegable = matches!(space, Space::Jpegable(_)) && lossy_ok && (bpc == 8 || bpc == 16);
    let mut out_bpc = bpc;
    let (mut px, mut nw, mut nh) = (samples, w, h);
    let mut reference = None;
    // The samples before downsampling, for `larger_scales`.
    let mut src = None;
    let mut checked = 1.0;
    if jpegable {
        if bpc == 16 {
            px = px.as_chunks::<2>().0.iter().map(|c| c[0]).collect();
            out_bpc = 8;
        }
        reference = view_ref(&px, w, h, comps, plan)?;
        checked = match &reference {
            Some(r) => checked_scale(&px, w, h, comps, scale, plan, r)?,
            None => 1.0,
        };
        if checked < 1.0 {
            src = Some(px.clone());
        }
        (px, nw, nh) = resample(px, w, h, comps, checked)?;
    }
    let out_row = (nw as usize * comps * out_bpc as usize).div_ceil(8);
    let bpp = (comps * out_bpc as usize).div_ceil(8).max(1);
    let filtered = deflate::png_filter(&px, out_row, bpp);
    let mut lossless = None;
    if jpegable {
        // JPEG must clearly beat lossless: flat graphics and text stay sharp. A fast deflate
        // settles most images; the strong one only runs when it could change the answer.
        let quick = deflate::zlib(&filtered, 4);
        let probe = encode_jpeg(&px, nw, nh, layout(comps), plan.jpeg_quality, false)?;
        let strong = if probe.len() * 2 < quick.len() {
            quick
        } else {
            deflate::zlib(&filtered, if filtered.len() > 1 << 20 { 9 } else { 12 })
        };
        let limit = original_len.min(strong.len() * 3 / 4);
        let mut chosen = match &reference {
            Some(r) if probe.len() < limit => encode_checked(&px, nw, nh, layout(comps), plan, r, limit)?.map(|e| (e, nw, nh)),
            _ => None,
        };
        if let (Some(src), Some(r)) = (src.take(), &reference)
            && (chosen.is_none() || checked > scale)
        {
            chosen = larger_scales(&src, w, h, layout(comps), plan, r, checked, chosen, limit, true)?;
        }
        if let Some((enc, nw, nh)) = chosen {
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

/// A JPEG 2000 image (`/JPXDecode`) as a checked JPEG, decoded only to the resolution needed:
/// JPEG 2000 can skip resolution levels, so a 143-megapixel scan drawn at 250 dpi decodes at a
/// quarter of its size. Only images whose PDF colour space is gray or RGB (device, calibrated
/// or ICC) and that carry no alpha, `/SMaskInData` or `/Decode` are handled; the rest stay as
/// stored, and so does any result not smaller than the JPEG 2000 original.
fn jpx_image(
    stream: &Stream,
    w: u32,
    h: u32,
    space: Option<Space>,
    plan: &ImagePlan,
    lossy_ok: bool,
    budget: &Budget,
) -> Result<Option<(Stream, bool)>> {
    let d = &stream.dict;
    let Some(Space::Jpegable(comps @ (1 | 3))) = space else { return Ok(None) };
    let smask_in_data = d.get(b"SMaskInData").and_then(|o| o.as_i64()).unwrap_or(0) != 0;
    if !lossy_ok || smask_in_data || d.has(b"Decode") || !jpx_full_sampling(&stream.content) {
        return Ok(None);
    }
    let scale = match (plan.dpi, plan.drawn_dpi) {
        (Some(target), Some(drawn)) if drawn > target * DOWNSAMPLE_THRESHOLD => target / drawn,
        _ => 1.0,
    };
    // Decode at the larger of the target and the 150 dpi view the fidelity check compares at.
    let view = plan.drawn_dpi.filter(|d| *d > 0.0).map_or(1.0, |d| (VIEW_DPI / d).min(1.0));
    let need = scale.max(view);
    let target = (((w as f64 * need).ceil() as u32).max(1), ((h as f64 * need).ceil() as u32).max(1));
    let settings = hayro_jpeg2000::DecodeSettings { target_resolution: Some(target), ..Default::default() };
    let Ok(image) = hayro_jpeg2000::Image::new(&stream.content, &settings) else { return Ok(None) };
    let (iw, ih) = (image.width(), image.height());
    if image.has_alpha() || usize::from(image.color_space().num_channels()) != comps || iw == 0 || ih == 0 {
        return Ok(None);
    }
    let cost = (iw as usize) * (ih as usize) * comps * 6 + stream.content.len() * 2;
    let Some(_hold) = budget.hold(cost)? else { return Ok(None) };
    let mut ctx = hayro_jpeg2000::DecoderContext::default();
    let Ok(decoded) = image.decode(&mut ctx) else { return Ok(None) };
    let px = decoded.data_u8();
    if px.len() != (iw as usize) * (ih as usize) * comps {
        return Ok(None);
    }
    // From here the decoded image stands in for the original: its own resolution as drawn.
    let local = ImagePlan { drawn_dpi: plan.drawn_dpi.map(|d| d * f64::from(iw) / f64::from(w)), ..*plan };
    let s = ((w as f64 * scale) / f64::from(iw)).min(1.0);
    let Some(r) = view_ref(&px, iw, ih, comps, &local)? else { return Ok(None) };
    let s = checked_scale(&px, iw, ih, comps, s, &local, &r)?;
    let (px, nw, nh) = resample(px, iw, ih, comps, s)?;
    let layout = if comps == 1 { Layout::Gray } else { Layout::Rgb };
    Ok(encode_checked(&px, nw, nh, layout, &local, &r, stream.content.len())?.map(|enc| (with_jpeg(d, enc, nw, nh), true)))
}

/// Whether every component of a JPEG 2000 codestream is sampled at full resolution (the SIZ
/// marker's XRsiz and YRsiz are 1): subsampled components decode at their own sizes, and
/// interleaving them as if they were full gave pdf.js jpx_subsampling SSIM 0.92.
fn jpx_full_sampling(data: &[u8]) -> bool {
    let Some(soc) = data.windows(4).position(|w| w == [0xFF, 0x4F, 0xFF, 0x51]) else { return false };
    let siz = soc + 2;
    let Some(n) = data.get(siz + 38..siz + 40).map(|b| u16::from_be_bytes([b[0], b[1]]) as usize) else { return false };
    (0..n).all(|k| data.get(siz + 41 + 3 * k) == Some(&1) && data.get(siz + 42 + 3 * k) == Some(&1))
}

/// An image's decoded bytes, Flate (with or without PNG predictors) decoded here strictly: lopdf
/// un-filtered one PNG-predicted image wrongly (pdf.js issue14814), and the rewrite stored its
/// reading. TIFF predictors are left alone; other filters go through lopdf.
fn strict_samples(doc: &Document, stream: &Stream, filters: &[Vec<u8>], limit: usize) -> Option<Vec<u8>> {
    let d = &stream.dict;
    // `/DecodeParms` may be a reference (lopdf then ignored the predictor: pdf.js issue14814),
    // a dictionary, or an array of one.
    let parms = match d.get(b"DecodeParms").map(|o| resolve(doc, o)) {
        Err(_) | Ok(Object::Null) => None,
        Ok(Object::Dictionary(p)) => Some(p),
        Ok(Object::Array(a)) if a.len() == 1 => match resolve(doc, &a[0]) {
            Object::Dictionary(p) => Some(p),
            Object::Null => None,
            _ => return None,
        },
        Ok(_) => return None,
    };
    let get = |k: &[u8], default: i64| parms.and_then(|p| p.get(k).ok()).map(|o| resolve(doc, o)).and_then(|o| o.as_i64().ok()).unwrap_or(default);
    let predictor = get(b"Predictor", 1);
    match filters {
        [] => Some(stream.content.clone()),
        [f] if matches!(f.as_slice(), b"FlateDecode" | b"Fl") => {
            let inflated = miniz_oxide::inflate::decompress_to_vec_zlib_with_limit(&stream.content, limit).ok()?;
            match predictor {
                1 => Some(inflated),
                10..=15 => {
                    let (colors, bpc, columns) = (get(b"Colors", 1), get(b"BitsPerComponent", 8), get(b"Columns", 1));
                    if !(1..=32).contains(&colors) || !matches!(bpc, 1 | 2 | 4 | 8 | 16) || !(1..=1 << 20).contains(&columns) {
                        return None;
                    }
                    let row = (colors * bpc * columns) as usize;
                    let (row, bpp) = (row.div_ceil(8), ((colors * bpc) as usize).div_ceil(8).max(1));
                    let rows = inflated.len() / (row + 1);
                    deflate::png_unfilter(&inflated, row, bpp, rows)
                }
                _ => None,
            }
        }
        _ if predictor != 1 => None,
        _ => stream.decompressed_content_with_limit(limit).ok(),
    }
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
#[allow(clippy::too_many_arguments)]
fn mono_image(
    doc: &Document,
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
        let Some(packed) = strict_samples(doc, stream, filters, need + 1024) else { return Ok(None) };
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
    nd.remove(b"SMaskInData");
    nd.set("BitsPerComponent", 8);
    nd.set("Width", w as i64);
    nd.set("Height", h as i64);
    Stream::new(nd, data)
}

fn encode_jpeg(px: &[u8], w: u32, h: u32, layout: Layout, quality: u8, chroma_full: bool) -> Result<Vec<u8>> {
    jpeg::codec().encode(px, w, h, layout, &EncodeOptions { quality, progressive: true, fast_scans: true, chroma_full, markers: &[] })
}

/// The source image as a viewer shows it at `VIEW_DPI`: what every lossy step (downsampling,
/// then JPEG) is judged against, so their losses add up in one score instead of passing one
/// by one (pdf.js issue17289: each step alone scored 0.98, the page 0.970).
struct ViewRef {
    px: Vec<u8>,
    w: u32,
    h: u32,
    comps: usize,
    smoothed: bool,
}

/// A viewer draws an image through its interpolation filter, which smooths pixel noise a JPEG
/// drops. Drawn denser than the view, area-averaging to it is that filter; drawn at or below it,
/// one [1 2 1] pass stands in for it (a noisy 150 dpi scan scored SSIM 0.873 on raw pixels,
/// 0.981 after the pass, and 0.987 as CoreGraphics renders the page).
fn view_ref(px: &[u8], w: u32, h: u32, comps: usize, plan: &ImagePlan) -> Result<Option<ViewRef>> {
    let view = plan.drawn_dpi.filter(|d| *d > 0.0).map_or(1.0, |d| (VIEW_DPI / d).min(1.0));
    if view >= 1.0 {
        if !matches!(comps, 1 | 3 | 4) {
            return Ok(None);
        }
        return Ok(Some(ViewRef { px: smooth(px, w as usize, h as usize, comps), w, h, comps, smoothed: true }));
    }
    let (vw, vh) = (((w as f64 * view).round() as u32).max(1), ((h as f64 * view).round() as u32).max(1));
    Ok(view_resample(px, w, h, comps, vw, vh)?.map(|p| ViewRef { px: p, w: vw, h: vh, comps, smoothed: false }))
}

impl ViewRef {
    /// SSIM of `px` (`w` x `h`: the source downsampled, or its encode decoded) against the source,
    /// both as a viewer shows them.
    fn score(&self, px: &[u8], w: u32, h: u32) -> Result<f64> {
        let seen = if (w, h) == (self.w, self.h) {
            px.to_vec()
        } else {
            match view_resample(px, w, h, self.comps, self.w, self.h)? {
                Some(p) => p,
                None => return Ok(0.0),
            }
        };
        let seen = if self.smoothed { smooth(&seen, self.w as usize, self.h as usize, self.comps) } else { seen };
        Ok(ssim(&self.px, &seen, self.w as usize, self.h as usize, self.comps))
    }
}

/// The smallest JPEG of `px` under `limit` bytes that keeps the plan's SSIM against the source
/// `r`: the ceiling quality, then without chroma subsampling, then 10, 20 and 40 points higher
/// (at most 92). `None` when none does: the caller keeps a lossless form.
fn encode_checked(
    px: &[u8],
    w: u32,
    h: u32,
    layout: Layout,
    plan: &ImagePlan,
    r: &ViewRef,
    limit: usize,
) -> Result<Option<Vec<u8>>> {
    let q = plan.jpeg_quality;
    let up = |n: u8| q.saturating_add(n).min(92).max(q);
    for (quality, full) in [(q, false), (q, true), (up(10), true), (up(20), true), (up(40), true)] {
        let enc = encode_jpeg(px, w, h, layout, quality, full)?;
        if enc.len() >= limit {
            return Ok(None);
        }
        let back = jpeg::decode_samples(&enc, u64::from(w) * u64::from(h))?;
        if back.pixels.len() != px.len() {
            return Ok(None);
        }
        if r.score(&back.pixels, w, h)? >= plan.min_ssim {
            return Ok(Some(enc));
        }
    }
    Ok(None)
}

/// JPEG at the scales above `checked`, for when JPEG at `checked` failed the gate (`chosen` is
/// `None`) or the gate refused the planned downsampling (`checked` above it): 150 dpi, then full
/// size when `full` (a JPEG source already at or under the ceiling stays as it is instead). A
/// downsampled JPEG is judged at its own size, a larger one through the viewer's downsampling,
/// which hides more of its error: on noise the larger image can pass at a lower quality and come
/// out smaller. Keeps whichever passing JPEG is smallest, `chosen` included.
#[allow(clippy::too_many_arguments)]
fn larger_scales(
    src: &[u8],
    w: u32,
    h: u32,
    layout: Layout,
    plan: &ImagePlan,
    r: &ViewRef,
    checked: f64,
    mut chosen: Option<(Vec<u8>, u32, u32)>,
    limit: usize,
    full: bool,
) -> Result<Option<(Vec<u8>, u32, u32)>> {
    let comps = layout.components();
    let view = plan.drawn_dpi.filter(|d| *d > 0.0).map_or(1.0, |d| (VIEW_DPI / d).min(1.0));
    if chosen.is_none() && view > checked && view < 1.0 {
        let (px, vw, vh) = resample(src.to_vec(), w, h, comps, view)?;
        chosen = encode_checked(&px, vw, vh, layout, plan, r, limit)?.map(|e| (e, vw, vh));
    }
    if full {
        let lim = chosen.as_ref().map_or(limit, |c| c.0.len());
        if let Some(e) = encode_checked(src, w, h, layout, plan, r, lim)? {
            chosen = Some((e, w, h));
        }
    }
    Ok(chosen)
}

/// One separable [1 2 1] / 4 pass over each channel of an interleaved image, edges clamped.
/// Three horizontally filtered rows at a time: memory beyond the output is O(width).
fn smooth(px: &[u8], w: usize, h: usize, comps: usize) -> Vec<u8> {
    let n = w * comps;
    let row = |y: usize, out: &mut Vec<u32>| {
        out.clear();
        let r = &px[y * n..(y + 1) * n];
        for x in 0..w {
            let (l, rr) = (x.saturating_sub(1), (x + 1).min(w - 1));
            for c in 0..comps {
                out.push(u32::from(r[l * comps + c]) + 2 * u32::from(r[x * comps + c]) + u32::from(r[rr * comps + c]));
            }
        }
    };
    let mut out = vec![0u8; px.len()];
    let (mut up, mut mid, mut down) = (Vec::with_capacity(n), Vec::with_capacity(n), Vec::with_capacity(n));
    row(0, &mut mid);
    up.clone_from(&mid);
    for y in 0..h {
        row((y + 1).min(h - 1), &mut down);
        for i in 0..n {
            out[y * n + i] = ((up[i] + 2 * mid[i] + down[i] + 8) / 16) as u8;
        }
        std::mem::swap(&mut up, &mut mid);
        std::mem::swap(&mut mid, &mut down);
    }
    out
}

/// Mean SSIM over the channels of two interleaved 8-bit images, 7x7 uniform window (as the
/// benchmark's judge measures pages). Column sums over the window's rows keep memory O(width).
pub fn ssim(a: &[u8], b: &[u8], w: usize, h: usize, comps: usize) -> f64 {
    const R: usize = 3;
    const K: usize = 2 * R + 1;
    if w < K || h < K {
        let diff: u64 = a.iter().zip(b).map(|(x, y)| u64::from(x.abs_diff(*y))).sum();
        return 1.0 - diff as f64 / (255.0 * a.len().max(1) as f64);
    }
    let (c1, c2, k) = (6.5025, 58.5225, (K * K) as f64);
    let n = w * comps;
    let mut col = vec![[0f64; 5]; n];
    let add = |col: &mut [[f64; 5]], y: usize, sign: f64| {
        for (i, c) in col.iter_mut().enumerate() {
            let (p, q) = (f64::from(a[y * n + i]), f64::from(b[y * n + i]));
            c[0] += sign * p;
            c[1] += sign * q;
            c[2] += sign * p * p;
            c[3] += sign * q * q;
            c[4] += sign * p * q;
        }
    };
    for y in 0..K {
        add(&mut col, y, 1.0);
    }
    let mut acc = vec![0f64; comps];
    for y in R..h - R {
        if y > R {
            add(&mut col, y - R - 1, -1.0);
            add(&mut col, y + R, 1.0);
        }
        for (ch, total) in acc.iter_mut().enumerate() {
            let mut s = [0f64; 5];
            for x in 0..K {
                for (q, v) in s.iter_mut().enumerate() {
                    *v += col[x * comps + ch][q];
                }
            }
            for x in R..w - R {
                if x > R {
                    for (q, v) in s.iter_mut().enumerate() {
                        *v += col[(x + R) * comps + ch][q] - col[(x - R - 1) * comps + ch][q];
                    }
                }
                let (mx, my) = (s[0] / k, s[1] / k);
                let (vx, vy, cxy) = (s[2] / k - mx * mx, s[3] / k - my * my, s[4] / k - mx * my);
                *total += ((2.0 * mx * my + c1) * (2.0 * cxy + c2)) / ((mx * mx + my * my + c1) * (vx + vy + c2));
            }
        }
    }
    let count = ((w - 2 * R) * (h - 2 * R)) as f64;
    acc.iter().map(|t| t / count).sum::<f64>() / comps as f64
}

/// Downsamples 8-bit interleaved samples by `scale` (< 1) with Catmull-Rom, like Ghostscript's
/// bicubic downsampling. Returns the input when `scale` is 1.
fn resample(px: Vec<u8>, w: u32, h: u32, comps: usize, scale: f64) -> Result<(Vec<u8>, u32, u32)> {
    if scale >= 1.0 {
        return Ok((px, w, h));
    }
    let nw = ((w as f64 * scale).round() as u32).max(1);
    let nh = ((h as f64 * scale).round() as u32).max(1);
    match resample_to(&px, w, h, comps, nw, nh)? {
        Some(out) => Ok((out, nw, nh)),
        None => Ok((px, w, h)),
    }
}

/// `px` resized to `nw` x `nh` (Catmull-Rom); `None` for a pixel layout it does not handle.
fn resample_to(px: &[u8], w: u32, h: u32, comps: usize, nw: u32, nh: u32) -> Result<Option<Vec<u8>>> {
    resample_with(px, w, h, comps, nw, nh, fr::FilterType::CatmullRom)
}

/// `px` as a viewer draws it smaller: halved by area averaging while still at least twice too
/// large (what JPEG's DCT scaling, JPEG 2000's resolution levels and mipmaps amount to), then
/// bilinear to the view, which aliases a reduction of less than half. Measured against
/// CoreGraphics' render: pdf.js issue17289 page 4 scores 0.966 here and 0.970 in the judge (a
/// plain Catmull-Rom resize said 0.99 and passed a failing JPEG); a q97 photo book 0.982 here
/// and 0.9975 there.
fn view_resample(px: &[u8], w: u32, h: u32, comps: usize, nw: u32, nh: u32) -> Result<Option<Vec<u8>>> {
    let (mut cur, mut cw, mut ch) = (None::<Vec<u8>>, w, h);
    // Two pixels of slack: a 2403-pixel image drawn 1202 wide is a 2:1 reduction.
    while cw + 2 >= 2 * nw && ch + 2 >= 2 * nh && cw > nw && ch > nh {
        let (hw, hh) = ((cw / 2).max(nw), (ch / 2).max(nh));
        let Some(half) = resample_with(cur.as_deref().unwrap_or(px), cw, ch, comps, hw, hh, fr::FilterType::Box)? else {
            return Ok(None);
        };
        (cur, cw, ch) = (Some(half), hw, hh);
    }
    if (cw, ch) == (nw, nh) {
        return Ok(Some(cur.unwrap_or_else(|| px.to_vec())));
    }
    resample_with(cur.as_deref().unwrap_or(px), cw, ch, comps, nw, nh, fr::FilterType::Bilinear)
}

fn resample_with(
    px: &[u8],
    w: u32,
    h: u32,
    comps: usize,
    nw: u32,
    nh: u32,
    filter: fr::FilterType,
) -> Result<Option<Vec<u8>>> {
    let pt = match comps {
        1 => fr::PixelType::U8,
        3 => fr::PixelType::U8x3,
        4 => fr::PixelType::U8x4,
        _ => return Ok(None),
    };
    let err = |e: &dyn std::fmt::Display| EngineError::internal(format!("resize: {e}"));
    let src = fr::images::ImageRef::new(w, h, px, pt).map_err(|e| err(&e))?;
    let mut dst = fr::images::Image::new(nw, nh, pt);
    // CMYK is four colour channels, not RGBA: no alpha handling.
    let opts =
        fr::ResizeOptions::new().resize_alg(fr::ResizeAlg::Convolution(filter)).use_alpha(false);
    fr::Resizer::new().resize(&src, &mut dst, &opts).map_err(|e| err(&e))?;
    Ok(Some(dst.into_vec()))
}

/// Images are downsampled only when drawn at more than this many times the target resolution
/// (Ghostscript's default `DownsampleThreshold`): a mild, non-integer reduction (300 to 250 dpi)
/// saves little and changes how a viewer then resamples text edges (pdf.js issue17289: a page
/// scored 0.970 while each step scored 0.98).
const DOWNSAMPLE_THRESHOLD: f64 = 1.05;

/// Resolution, in pixels per inch on the page, at which downsampling is judged: what the
/// benchmark renders pages at, and about what a screen shows at 100 to 150 % zoom.
const VIEW_DPI: f64 = 150.0;

/// The downsampling scale to use: `scale` when the image, downsampled and drawn back at
/// `VIEW_DPI`, keeps the plan's SSIM against the full image drawn at `VIEW_DPI`; else the first
/// of 72, 100 and 150 dpi that does (150 dpi loses nothing at that view).
fn checked_scale(px: &[u8], w: u32, h: u32, comps: usize, scale: f64, plan: &ImagePlan, r: &ViewRef) -> Result<f64> {
    let Some(drawn) = plan.drawn_dpi.filter(|d| *d > 0.0) else { return Ok(scale) };
    let view = (VIEW_DPI / drawn).min(1.0);
    if scale >= view {
        return Ok(scale);
    }
    let candidates = [72.0, 100.0].into_iter().map(|d| d / drawn).filter(|s| *s > scale && *s < view);
    for s in std::iter::once(scale).chain(candidates) {
        let (sw, sh) = (((w as f64 * s).round() as u32).max(1), ((h as f64 * s).round() as u32).max(1));
        let Some(small) = resample_to(px, w, h, comps, sw, sh)? else { return Ok(scale) };
        if r.score(&small, sw, sh)? >= plan.min_ssim {
            return Ok(s);
        }
    }
    Ok(view)
}

#[cfg(test)]
mod ssim_tests {
    use super::{smooth, ssim};

    #[test]
    fn smooth_matches_direct() {
        let (w, h, c) = (9usize, 7usize, 3usize);
        let px: Vec<u8> = (0..w * h * c).map(|i| ((i * 53) % 256) as u8).collect();
        let at = |x: usize, y: usize, ch: usize| u32::from(px[(y * w + x) * c + ch]);
        let got = smooth(&px, w, h, c);
        for y in 0..h {
            for x in 0..w {
                for ch in 0..c {
                    let hz = |yy: usize| at(x.saturating_sub(1), yy, ch) + 2 * at(x, yy, ch) + at((x + 1).min(w - 1), yy, ch);
                    let v = (hz(y.saturating_sub(1)) + 2 * hz(y) + hz((y + 1).min(h - 1)) + 8) / 16;
                    assert_eq!(u32::from(got[(y * w + x) * c + ch]), v);
                }
            }
        }
    }

    #[test]
    fn ssim_bounds() {
        let (w, h) = (32, 24);
        let a: Vec<u8> = (0..w * h * 3).map(|i| ((i * 37) % 251) as u8).collect();
        assert!((ssim(&a, &a, w, h, 3) - 1.0).abs() < 1e-9);
        let b: Vec<u8> = a.iter().map(|v| v.saturating_add(40)).collect();
        let c: Vec<u8> = a.iter().map(|v| 255 - v).collect();
        let (sb, sc) = (ssim(&a, &b, w, h, 3), ssim(&a, &c, w, h, 3));
        assert!(sb < 1.0 && sb > sc, "{sb} {sc}");
    }
}

