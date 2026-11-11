// SPDX-License-Identifier: GPL-3.0-or-later
//! `png.optimise`, `jpeg.optimise`, `gif.optimise`: same format in, smaller file out.

use super::{Encoded, compression, finish, open, parse_params};
use crate::codec::{self, jpeg::Layout, png::Quant};
use crate::ctx::Ctx;
use crate::error::{EngineError, Result};
use crate::meta;
use crate::pixels::{self, Content};
use crate::protocol::{Format, GifBackend, GifParams, JpegParams, OpResult, PngParams, Request};
use crate::quality;
use image::DynamicImage;

pub fn png(req: &Request, ctx: &Ctx) -> Result<OpResult> {
    let (p, ignored) = parse_params::<PngParams>(&req.params)?;
    let (bytes, target) = open(req, &p.out)?;
    let chunks = meta::png_chunks(&bytes)?;
    let f = compression(p.compression)?;
    let level = p.level.unwrap_or_else(|| quality::png_level(f)).min(6);
    let keep = p.out.keep_list().to_vec();
    let animated = meta::png_is_animated(&chunks);
    let lossy = p.lossy.unwrap_or(true) && !animated;
    let (min, tgt) = match p.quality {
        Some([a, b]) if a > b || b > 100 => {
            return Err(EngineError::invalid("`quality` must be [min, max] with min <= max <= 100"));
        }
        Some([a, b]) => (a, b),
        None => quality::png_quality(f),
    };
    if p.speed.is_some_and(|s| !(1..=10).contains(&s)) {
        return Err(EngineError::invalid("`speed` must be 1..=10"));
    }
    let mut best: Option<Encoded> = None;
    if lossy {
        let decoded = pixels::decode(&bytes, false, &ctx.sub(0.0, 0.1))?;
        let img = decoded.content.into_still();
        let (w, h) = (img.width(), img.height());
        let quant = Quant {
            min,
            target: tgt,
            speed: p.speed.unwrap_or_else(|| quality::png_speed(f)),
            colors: p.colors.map(u32::from).or_else(|| quality::png_colors(f)).unwrap_or(256),
            dither: p.dither.unwrap_or(1.0),
        };
        if let Some(ix) = codec::png::quantise(&img, &quant, &ctx.sub(0.1, 0.7))? {
            drop(img);
            ctx.progress(0.7, "compress");
            let carry = meta::png_chunks_to_carry(&chunks, p.out.strip, &keep, None);
            let reached = ix.quality;
            let out = codec::png::encode_indexed(ix, &carry, level)?;
            best = Some(Encoded {
                bytes: out,
                width: w,
                height: h,
                format: Some(Format::Png),
                quality: Some(reached),
                lossy: true,
                ..Default::default()
            });
        }
    }
    ctx.check()?;
    if best.as_ref().is_none_or(|b| b.bytes.len() >= bytes.len()) {
        ctx.progress(0.8, "compress");
        let src = if p.out.strip { meta::png_strip(&bytes, &keep)? } else { bytes.clone() };
        let out = codec::png::optimise_lossless(&src, level)?;
        if best.as_ref().is_none_or(|b| out.len() < b.bytes.len()) {
            let (w, h) = png_size(&chunks);
            let frames = chunks.iter().filter(|c| &c.name == b"fcTL").count() as u32;
            best = Some(Encoded {
                bytes: out,
                width: w,
                height: h,
                format: Some(Format::Png),
                lossy: false,
                frames,
                ..Default::default()
            });
        }
    }
    let best = best.ok_or_else(|| EngineError::internal("png: no candidate"))?;
    finish(&target, bytes.len() as u64, best, p.out.allow_larger.unwrap_or(false), ignored, ctx)
}

fn png_size(chunks: &[meta::Chunk]) -> (u32, u32) {
    let d = chunks[0].data;
    let r = |o: usize| d.get(o..o + 4).map(|b| u32::from_be_bytes(b.try_into().unwrap())).unwrap_or(0);
    (r(0), r(4))
}

pub fn jpeg(req: &Request, ctx: &Ctx) -> Result<OpResult> {
    let (p, ignored) = parse_params::<JpegParams>(&req.params)?;
    let (bytes, target) = open(req, &p.out)?;
    let parts = meta::JpegParts::parse(&bytes)?;
    let f = compression(p.compression)?;
    let ceiling = match p.quality {
        None => Some(quality::jpeg_max_quality(f)),
        Some(Some(q)) if q > 100 => return Err(EngineError::invalid("`quality` must be 0..=100 or null")),
        Some(q) => q,
    };
    let progressive = p.progressive.unwrap_or(true);
    let keep = p.out.keep_list().to_vec();
    let markers = meta::jpeg_markers_to_carry(&parts, p.out.strip, &keep, None);
    let codec = codec::jpeg::codec();
    let estimated = parts.luma_qtable().map(|t| codec.estimate_quality(&t));
    let reencode = match ceiling {
        Some(q) => parts.components() != 4 && estimated.is_none_or(|e| e > q),
        None => false,
    };
    let mut best: Option<Encoded> = None;
    if let Some(q) = ceiling.filter(|_| reencode) {
        let decoded = pixels::decode(&bytes, false, &ctx.sub(0.0, 0.2))?;
        let img = decoded.content.into_still();
        let (w, h) = (img.width(), img.height());
        let (layout, px) = match pixels::flatten(img) {
            DynamicImage::ImageLuma8(g) => (Layout::Gray, g.into_raw()),
            other => (Layout::Rgb, other.into_rgb8().into_raw()),
        };
        ctx.check()?;
        ctx.progress(0.25, "encode");
        let out = codec.encode(
            &px,
            w,
            h,
            layout,
            &codec::jpeg::EncodeOptions { quality: q, progressive, fast_scans: false, chroma_full: false, markers: &markers },
        )?;
        best = Some(Encoded {
            bytes: out,
            width: w,
            height: h,
            format: Some(Format::Jpeg),
            quality: Some(q),
            lossy: true,
            ..Default::default()
        });
    }
    ctx.check()?;
    if best.as_ref().is_none_or(|b| b.bytes.len() >= bytes.len()) {
        ctx.progress(0.6, "transcode");
        let out = codec.transcode(&bytes, &codec::jpeg::TranscodeOptions { progressive, markers: &markers })?;
        if best.as_ref().is_none_or(|b| out.len() < b.bytes.len()) {
            let (w, h) = jpeg_size(&parts);
            best = Some(Encoded {
                bytes: out,
                width: w,
                height: h,
                format: Some(Format::Jpeg),
                quality: None,
                lossy: false,
                ..Default::default()
            });
        }
    }
    let best = best.ok_or_else(|| EngineError::internal("jpeg: no candidate"))?;
    finish(&target, bytes.len() as u64, best, p.out.allow_larger.unwrap_or(false), ignored, ctx)
}

pub fn jpeg_size(parts: &meta::JpegParts) -> (u32, u32) {
    parts
        .sof()
        .and_then(|s| s.data.get(1..5))
        .map(|d| (u16::from_be_bytes([d[2], d[3]]) as u32, u16::from_be_bytes([d[0], d[1]]) as u32))
        .unwrap_or((0, 0))
}

/// gifsicle arguments for a lossiness, palette cap, level and strip setting.
pub fn gifsicle_args(level: u8, lossy: u32, colors: Option<u32>, strip: bool) -> Vec<String> {
    let mut a = vec![format!("-O{}", level.clamp(1, 3))];
    if lossy > 0 {
        a.push(format!("--lossy={lossy}"));
    }
    if let Some(c) = colors {
        a.push(format!("--colors={}", c.clamp(2, 256)));
    }
    if strip {
        a.extend(["--no-comments", "--no-names", "--no-extensions"].map(String::from));
    }
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1).min(8);
    a.push(format!("--threads={threads}"));
    a.push("--no-warnings".into());
    a
}

pub fn gif(req: &Request, ctx: &Ctx) -> Result<OpResult> {
    let (p, ignored) = parse_params::<GifParams>(&req.params)?;
    let (bytes, target) = open(req, &p.out)?;
    let (_, frames) = meta::gif_filter(&bytes, |_, _| true)?;
    let f = compression(p.compression)?;
    let s = quality::gif(f);
    let lossy = p.lossy.unwrap_or(s.lossy);
    if p.lossy.is_some_and(|l| l > 200) {
        return Err(EngineError::invalid("`lossy` must be 0..=200"));
    }
    let colors = p.colors.map(u32::from).or(s.colors);
    let level = p.level.unwrap_or(s.level);
    let bin =
        match p.backend.unwrap_or_default() {
            GifBackend::Builtin => None,
            GifBackend::Auto => codec::gif::find_gifsicle(),
            GifBackend::Gifsicle => Some(codec::gif::find_gifsicle().ok_or_else(|| {
                EngineError::unsupported("gifsicle not found ($ESCLOP_BIN, next to the engine, PATH)")
            })?),
        };
    let (w, h) = gif_size(&bytes);
    let enc = if let Some(bin) = bin {
        ctx.progress(0.1, "gifsicle");
        let out = codec::gif::run_gifsicle(
            &bin,
            super::input_path(req)?,
            &gifsicle_args(level, lossy, colors, p.out.strip),
            ctx,
        )?;
        Encoded {
            bytes: out,
            width: w,
            height: h,
            format: Some(Format::Gif),
            lossy: lossy > 0 || colors.is_some(),
            frames,
            backend: Some("gifsicle".into()),
            ..Default::default()
        }
    } else {
        let decoded = pixels::decode(&bytes, true, &ctx.sub(0.0, 0.2))?;
        let anim = match decoded.content {
            Content::Anim(a) => a,
            Content::Still(img) => pixels::Animation {
                width: img.width(),
                height: img.height(),
                frames: vec![pixels::Frame { image: img.to_rgba8(), delay_ms: 100 }],
                repeat: 0,
            },
        };
        let q = quality::gifski_quality_from_lossy(lossy);
        let o = codec::gif::DiffOptions {
            colors: colors.unwrap_or(256),
            quality: q,
            dither: 0.0,
            tolerance: (lossy / 10).min(32) as u8,
        };
        let out = codec::gif::encode_diff(&anim, &o, &ctx.sub(0.2, 0.98))?;
        Encoded {
            bytes: out,
            width: w,
            height: h,
            format: Some(Format::Gif),
            quality: Some(q),
            lossy: lossy > 0 || colors.is_some(),
            frames,
            backend: Some("builtin".into()),
        }
    };
    finish(&target, bytes.len() as u64, enc, p.out.allow_larger.unwrap_or(false), ignored, ctx)
}

pub fn gif_size(b: &[u8]) -> (u32, u32) {
    if b.len() < 10 {
        return (0, 0);
    }
    (u16::from_le_bytes([b[6], b[7]]) as u32, u16::from_le_bytes([b[8], b[9]]) as u32)
}
