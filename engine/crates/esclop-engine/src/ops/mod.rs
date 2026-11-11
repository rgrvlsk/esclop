// SPDX-License-Identifier: GPL-3.0-or-later
//! One function per protocol op, plus what they share: param parsing, metadata carrying, the
//! encoder dispatch and writing the result.

pub mod encode;
pub mod fit;
pub mod frames;
pub mod geometry;
pub mod optimise;
pub mod probe;
pub mod strip;

use crate::codec::{self, avif::AvifOptions, gif::GifskiOptions, jpeg::Layout, png::Quant, webp::WebpOptions};
use crate::ctx::Ctx;
use crate::error::{EngineError, Result};
use crate::fsio::{self, OutputTarget};
use crate::meta;
use crate::pixels::{self, Animation, Content, Frame, SourceMeta};
use crate::protocol::{EncodeParams, Format, Keep, OpResult, OutputParams, Request};
use crate::quality;
use image::DynamicImage;
use schemars::JsonSchema;
use serde::de::DeserializeOwned;
use std::path::{Path, PathBuf};

/// Params of type `T` plus the keys `T` does not know.
pub fn parse_params<T: DeserializeOwned + JsonSchema>(v: &serde_json::Value) -> Result<(T, Vec<String>)> {
    let v = match v {
        serde_json::Value::Null => serde_json::Value::Object(Default::default()),
        serde_json::Value::Object(_) => v.clone(),
        _ => return Err(EngineError::invalid("`params` must be an object")),
    };
    let known = known_keys::<T>();
    let ignored = v.as_object().unwrap().keys().filter(|k| !known.contains(k)).cloned().collect();
    let t = serde_json::from_value(v).map_err(|e| EngineError::invalid(format!("params: {e}")))?;
    Ok((t, ignored))
}

/// Property names of `T`'s JSON schema (flattened structs included).
pub fn known_keys<T: JsonSchema>() -> Vec<String> {
    let schema = schemars::SchemaGenerator::default().into_root_schema_for::<T>();
    let mut keys = Vec::new();
    collect_properties(schema.as_value(), schema.as_value(), &mut keys);
    keys
}

fn collect_properties(root: &serde_json::Value, v: &serde_json::Value, keys: &mut Vec<String>) {
    if let Some(p) = v.get("properties").and_then(|p| p.as_object()) {
        keys.extend(p.keys().cloned());
    }
    for k in ["allOf", "anyOf", "oneOf"] {
        if let Some(arr) = v.get(k).and_then(|a| a.as_array()) {
            for s in arr {
                collect_properties(root, s, keys);
            }
        }
    }
    if let Some(r) = v.get("$ref").and_then(|r| r.as_str())
        && let Some(name) = r.strip_prefix("#/$defs/")
        && let Some(def) = root.get("$defs").and_then(|d| d.get(name))
    {
        collect_properties(root, def, keys);
    }
}

pub fn input_path(req: &Request) -> Result<&Path> {
    let p = req.input.as_deref().ok_or_else(|| EngineError::invalid("missing `input`"))?;
    if !p.is_absolute() {
        return Err(EngineError::invalid(format!("`input` must be an absolute path: {}", p.display())));
    }
    Ok(p)
}

/// Reads the input and validates the output before any heavy work.
pub fn open(req: &Request, out: &OutputParams) -> Result<(Vec<u8>, OutputTarget)> {
    let input = input_path(req)?;
    let target = OutputTarget::resolve(Some(input), req.output.as_deref(), out.in_place)?;
    let bytes = fsio::read_input(input)?;
    Ok((bytes, target))
}

pub fn compression(c: Option<u8>) -> Result<u8> {
    match c {
        Some(c) if c > 100 => Err(EngineError::invalid("`compression` must be 0..=100")),
        Some(c) => Ok(c),
        None => Ok(quality::NORMAL),
    }
}

pub fn check_quality(q: Option<u8>, name: &str) -> Result<Option<u8>> {
    match q {
        Some(q) if q > 100 => Err(EngineError::invalid(format!("`{name}` must be 0..=100"))),
        q => Ok(q),
    }
}

/// An encoded result ready to be written.
#[derive(Debug, Default)]
pub struct Encoded {
    pub bytes: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub format: Option<Format>,
    pub quality: Option<u8>,
    pub lossy: bool,
    pub frames: u32,
    pub backend: Option<String>,
}

/// Writes `enc` unless it is not smaller and larger results are not allowed.
pub fn finish(
    target: &OutputTarget,
    bytes_before: u64,
    enc: Encoded,
    allow_larger: bool,
    ignored: Vec<String>,
    ctx: &Ctx,
) -> Result<OpResult> {
    let after = enc.bytes.len() as u64;
    if !allow_larger && after >= bytes_before {
        return Err(EngineError::already_smaller(bytes_before, after));
    }
    ctx.check()?;
    ctx.progress(0.99, "write");
    target.write(&enc.bytes)?;
    Ok(OpResult {
        bytes_before,
        bytes_after: after,
        width: enc.width,
        height: enc.height,
        format: enc.format,
        output: Some(target.path.clone()),
        quality: enc.quality,
        lossy: Some(enc.lossy),
        frames: (enc.frames > 1).then_some(enc.frames),
        backend: enc.backend,
        ignored_params: ignored,
        ..Default::default()
    })
}

/// ICC and EXIF to embed in a re-encoded image.
#[derive(Debug, Default, Clone)]
pub struct Carry {
    pub icc: Option<Vec<u8>>,
    /// TIFF payload.
    pub exif: Option<Vec<u8>>,
}

/// What to carry from `meta`. `upright` says the pixels were already rotated to the EXIF
/// orientation, in which case the carried orientation becomes 1.
pub fn carry(meta: &SourceMeta, out: &OutputParams, upright: bool) -> Carry {
    let keep = out.keep_list();
    let icc = if !out.strip || keep.contains(&Keep::Icc) { meta.icc.clone() } else { None };
    let exif = if !out.strip {
        meta.exif.clone().map(|mut e| {
            if upright {
                meta::exif_set_orientation(&mut e, 1);
            }
            e
        })
    } else if keep.contains(&Keep::Orientation) && !upright && meta.orientation != 1 {
        Some(meta::minimal_exif(meta.orientation))
    } else {
        None
    };
    Carry { icc, exif }
}

/// Default output format for a decoded input.
pub fn default_format(input: Format) -> Format {
    if input.encodable() { input } else { Format::Png }
}

/// Encodes `content` as `fmt`. Encoders without animation take the first frame.
pub fn encode_content(content: &Content, fmt: Format, p: &EncodeParams, carry: &Carry, ctx: &Ctx) -> Result<Encoded> {
    let f = compression(p.compression)?;
    let q = check_quality(p.quality, "quality")?;
    ctx.check()?;
    ctx.progress(0.05, "encode");
    let (w, h) = content.dimensions();
    let mut e = Encoded { width: w, height: h, format: Some(fmt), frames: 1, ..Default::default() };
    match fmt {
        Format::Jpeg => {
            let quality = q.unwrap_or_else(|| quality::jpeg_max_quality(f));
            let mut markers = Vec::new();
            if let Some(x) = &carry.exif {
                markers.push((meta::APP1, meta::exif_app1(x)));
            }
            if let Some(icc) = &carry.icc {
                markers.extend(meta::icc_app2(icc).into_iter().map(|d| (meta::APP2, d)));
            }
            let opts = codec::jpeg::EncodeOptions {
                quality,
                progressive: p.progressive.unwrap_or(true),
                fast_scans: p.jpeg_fast_scans,
                chroma_full: false, markers: &markers,
            };
            let still = content.first_frame();
            e.bytes = match &*still {
                DynamicImage::ImageLuma8(g) => codec::jpeg::codec().encode(g.as_raw(), w, h, Layout::Gray, &opts)?,
                DynamicImage::ImageRgb8(c) => codec::jpeg::codec().encode(c.as_raw(), w, h, Layout::Rgb, &opts)?,
                other => {
                    let rgb = pixels::flatten(other.clone()).into_rgb8();
                    codec::jpeg::codec().encode(rgb.as_raw(), w, h, Layout::Rgb, &opts)?
                }
            };
            e.quality = Some(quality);
            e.lossy = true;
        }
        Format::Png => {
            let img = content.first_frame();
            let chunks: Vec<([u8; 4], Vec<u8>)> = carry.exif.iter().map(|x| (*b"eXIf", x.clone())).collect();
            let level = quality::png_level(f);
            if p.lossy.unwrap_or(true) {
                let (_, target) = quality::png_quality(f);
                let quant = Quant {
                    min: 0,
                    target: q.unwrap_or(target),
                    speed: p.speed.unwrap_or_else(|| quality::png_speed(f)).clamp(1, 10),
                    colors: p.colors.map(u32::from).or_else(|| quality::png_colors(f)).unwrap_or(256),
                    dither: 1.0,
                };
                if let Some(ix) = codec::png::quantise(&img, &quant, ctx)? {
                    e.quality = Some(ix.quality);
                    e.bytes = codec::png::encode_indexed(ix, &with_icc(chunks, carry), level)?;
                    e.lossy = true;
                    return Ok(e);
                }
            }
            e.bytes = codec::png::encode_lossless(&img, &with_icc(chunks, carry), level)?;
        }
        Format::Webp => {
            let lossless = p.lossless.unwrap_or(false);
            let quality = q.unwrap_or_else(|| quality::webp_quality(f));
            let o = WebpOptions { quality, lossless, method: p.method.unwrap_or(4).min(6) };
            e.bytes = match content {
                Content::Anim(a) => {
                    e.frames = a.frames.len() as u32;
                    codec::webp::encode_animation(a, &o, carry.icc.as_deref(), carry.exif.as_deref())?
                }
                Content::Still(img) => codec::webp::encode_still(img, &o, carry.icc.as_deref(), carry.exif.as_deref())?,
            };
            e.quality = (!lossless).then_some(quality);
            e.lossy = !lossless;
        }
        Format::Avif => {
            let codec = codec::avif::codec().ok_or_else(|| {
                EngineError::unsupported("this engine build has no AVIF encoder; encode AVIF with ImageIO")
            })?;
            let quality = q.unwrap_or_else(|| quality::avif_quality(f));
            let o = AvifOptions { quality, alpha_quality: quality, speed: p.speed.unwrap_or(6).clamp(1, 10) };
            e.bytes = codec.encode(&content.first_frame(), &o, carry.icc.as_deref(), carry.exif.as_deref())?;
            e.quality = Some(quality);
            e.lossy = true;
        }
        Format::Gif => {
            let quality = q.unwrap_or_else(|| quality::gifski_quality_from_lossy(quality::gif(f).lossy));
            e.quality = Some(quality);
            e.lossy = true;
            e.backend = Some("builtin".into());
            match content {
                // frames from an animation: frame differencing, palettes without dithering
                Content::Anim(a) => {
                    e.frames = a.frames.len() as u32;
                    let o = codec::gif::DiffOptions {
                        colors: p.colors.map(u32::from).unwrap_or(256),
                        quality,
                        dither: 0.5,
                        tolerance: (quality::gif(f).lossy / 10).min(32) as u8,
                    };
                    e.bytes = codec::gif::encode_diff(a, &o, ctx)?;
                }
                // a still (photo, screenshot): gifski's dithered palette looks best
                Content::Still(img) => {
                    let anim = Animation {
                        width: w,
                        height: h,
                        frames: vec![Frame { image: img.to_rgba8(), delay_ms: 100 }],
                        repeat: 0,
                    };
                    e.bytes = codec::gif::encode_gifski(
                        anim,
                        &GifskiOptions { quality, width: None, height: None, fast: false },
                        &ctx.sub(0.05, 0.98),
                    )?;
                }
            }
        }
        other => return Err(EngineError::unsupported(format!("the engine cannot encode {}", other.name()))),
    }
    Ok(e)
}

fn with_icc(mut chunks: Vec<([u8; 4], Vec<u8>)>, carry: &Carry) -> Vec<([u8; 4], Vec<u8>)> {
    if let Some(icc) = &carry.icc {
        chunks.insert(0, (*b"iCCP", iccp_chunk(icc)));
    }
    chunks
}

/// An iCCP chunk body: name, compression method 0, zlib stream.
fn iccp_chunk(icc: &[u8]) -> Vec<u8> {
    let mut d = b"ICC Profile\0\0".to_vec();
    d.extend_from_slice(&miniz_oxide::deflate::compress_to_vec_zlib(icc, 9));
    d
}

/// The absolute frames folder or input of `gif.from_frames`.
pub fn dir_param(p: Option<&PathBuf>, req: &Request) -> Result<PathBuf> {
    let d = p.cloned().or_else(|| req.input.clone()).ok_or_else(|| EngineError::invalid("missing `frames_dir`"))?;
    if !d.is_absolute() {
        return Err(EngineError::invalid(format!("`frames_dir` must be an absolute path: {}", d.display())));
    }
    Ok(d)
}
