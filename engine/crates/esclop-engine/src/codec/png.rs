// SPDX-License-Identifier: GPL-3.0-or-later
//! PNG: imagequant for palettes, oxipng for the lossless part.

use crate::ctx::Ctx;
use crate::error::{EngineError, Result};
use image::DynamicImage;
use imagequant::RGBA;
use oxipng::{BitDepth, ColorType, Options, RawImage, StripChunks};

#[derive(Debug, Clone, Copy)]
pub struct Quant {
    pub min: u8,
    pub target: u8,
    pub speed: u8,
    pub colors: u32,
    pub dither: f32,
}

/// A quantised image: palette plus one index per pixel.
pub struct Indexed {
    pub width: u32,
    pub height: u32,
    pub palette: Vec<RGBA>,
    pub indices: Vec<u8>,
    /// Quality imagequant reached, 0..=100.
    pub quality: u8,
}

/// Quantises to a palette. `Ok(None)` when the palette cannot reach `q.min`.
///
/// The pixels are never copied: RGBA is handed over as is, RGB and gray rows are converted on
/// demand (imagequant itself keeps no full-size buffer above ~4 megapixels).
pub fn quantise(img: &DynamicImage, q: &Quant, ctx: &Ctx) -> Result<Option<Indexed>> {
    use rgb::FromSlice;
    let (w, h) = (img.width(), img.height());
    let mut attr = imagequant::new();
    attr.set_speed(q.speed.clamp(1, 10) as i32).map_err(liq)?;
    attr.set_quality(q.min.min(q.target), q.target).map_err(liq)?;
    attr.set_max_colors(q.colors.clamp(2, 256)).map_err(liq)?;
    let cancel = ctx.cancel_flag();
    let progress = ctx.sub(0.0, 0.6);
    attr.set_progress_callback(move |f| {
        progress.progress(f / 100.0, "quantise");
        if cancel.load(std::sync::atomic::Ordering::Relaxed) {
            imagequant::ControlFlow::Break
        } else {
            imagequant::ControlFlow::Continue
        }
    });
    let (wu, hu) = (w as usize, h as usize);
    let mut image = match img {
        DynamicImage::ImageRgba8(i) => attr.new_image_borrowed(i.as_raw().as_rgba(), wu, hu, 0.0),
        DynamicImage::ImageRgb8(i) => {
            let raw = i.as_raw().as_slice();
            // SAFETY: the callback writes every pixel of the row it is given.
            unsafe {
                imagequant::Image::new_fn(
                    &attr,
                    move |row: &mut [std::mem::MaybeUninit<RGBA>], y: usize| {
                        for (d, s) in row.iter_mut().zip(raw[y * wu * 3..(y + 1) * wu * 3].as_chunks::<3>().0) {
                            d.write(RGBA::new(s[0], s[1], s[2], 255));
                        }
                    },
                    wu,
                    hu,
                    0.0,
                )
            }
        }
        DynamicImage::ImageLuma8(i) => {
            let raw = i.as_raw().as_slice();
            // SAFETY: the callback writes every pixel of the row it is given.
            unsafe {
                imagequant::Image::new_fn(
                    &attr,
                    move |row: &mut [std::mem::MaybeUninit<RGBA>], y: usize| {
                        for (d, &g) in row.iter_mut().zip(&raw[y * wu..(y + 1) * wu]) {
                            d.write(RGBA::new(g, g, g, 255));
                        }
                    },
                    wu,
                    hu,
                    0.0,
                )
            }
        }
        other => {
            let px: Vec<RGBA> = other.to_rgba8().pixels().map(|p| RGBA::new(p.0[0], p.0[1], p.0[2], p.0[3])).collect();
            attr.new_image(px, wu, hu, 0.0)
        }
    }
    .map_err(liq)?;
    let mut res = match attr.quantize(&mut image) {
        Ok(r) => r,
        Err(imagequant::Error::QualityTooLow) => return Ok(None),
        Err(imagequant::Error::Aborted) => return Err(EngineError::cancelled()),
        Err(e) => return Err(liq(e)),
    };
    res.set_dithering_level(q.dither.clamp(0.0, 1.0)).map_err(liq)?;
    let (palette, indices) = match res.remapped(&mut image) {
        Ok(r) => r,
        Err(imagequant::Error::Aborted) => return Err(EngineError::cancelled()),
        Err(e) => return Err(liq(e)),
    };
    let quality = res.quantization_quality().unwrap_or(q.target);
    ctx.check()?;
    Ok(Some(Indexed { width: w, height: h, palette, indices, quality }))
}

fn liq(e: imagequant::Error) -> EngineError {
    EngineError::encode(format!("imagequant: {e}"))
}

fn ox(e: oxipng::PngError) -> EngineError {
    match e {
        oxipng::PngError::DeflatedDataTooLong(_) => EngineError::encode("oxipng: no smaller encoding found"),
        oxipng::PngError::NotPNG => EngineError::unsupported(format!("oxipng: {e}")),
        other => EngineError::decode(format!("oxipng: {other}")),
    }
}

fn options(level: u8, optimize_alpha: bool) -> Options {
    let mut o = Options::from_preset(level.min(6));
    // Apple's iDOT indexes IDAT offsets that a rewrite moves; a stale one makes ImageIO misrender.
    o.strip = StripChunks::Strip([*b"iDOT"].into_iter().collect());
    o.optimize_alpha = optimize_alpha;
    o
}

/// oxipng evaluates its candidates in parallel, each with its own filtered copy and deflate
/// buffers: on a 24-megapixel image that alone reaches ~270 MB with all cores. Large images get
/// a two-thread pool, which keeps the whole PNG path under the engine's 300 MB budget.
fn bounded<T: Send>(pixels: u64, f: impl FnOnce() -> T + Send) -> T {
    const LARGE: u64 = 8_000_000;
    if pixels < LARGE {
        return f();
    }
    match rayon::ThreadPoolBuilder::new().num_threads(2).build() {
        Ok(pool) => pool.install(f),
        Err(_) => f(),
    }
}

/// Writes a quantised image, carrying `chunks` (name, raw data) across.
pub fn encode_indexed(ix: Indexed, chunks: &[([u8; 4], Vec<u8>)], level: u8) -> Result<Vec<u8>> {
    let palette = ix.palette.iter().map(|c| rgb::RGBA8::new(c.r, c.g, c.b, c.a)).collect();
    let mut raw =
        RawImage::new(ix.width, ix.height, ColorType::Indexed { palette }, BitDepth::Eight, ix.indices).map_err(ox)?;
    for (name, data) in chunks {
        raw.add_png_chunk(*name, data.clone());
    }
    let px = ix.width as u64 * ix.height as u64;
    bounded(px, || raw.create_optimized_png(&options(level, true))).map_err(ox)
}

/// Writes pixels losslessly (oxipng picks the smallest colour type and filters).
pub fn encode_lossless(img: &DynamicImage, chunks: &[([u8; 4], Vec<u8>)], level: u8) -> Result<Vec<u8>> {
    let (w, h) = (img.width(), img.height());
    let (ct, data) = match img {
        DynamicImage::ImageLuma8(g) => (ColorType::Grayscale { transparent_shade: None }, g.as_raw().clone()),
        DynamicImage::ImageRgb8(c) => (ColorType::RGB { transparent_color: None }, c.as_raw().clone()),
        other => (ColorType::RGBA, other.to_rgba8().into_raw()),
    };
    let mut raw = RawImage::new(w, h, ct, BitDepth::Eight, data).map_err(ox)?;
    for (name, data) in chunks {
        raw.add_png_chunk(*name, data.clone());
    }
    bounded(w as u64 * h as u64, || raw.create_optimized_png(&options(level, false))).map_err(ox)
}

/// Recompresses an existing PNG without changing a pixel (APNG included).
pub fn optimise_lossless(png: &[u8], level: u8) -> Result<Vec<u8>> {
    let px = png
        .get(16..24)
        .map(|d| {
            u32::from_be_bytes(d[0..4].try_into().unwrap()) as u64
                * u32::from_be_bytes(d[4..8].try_into().unwrap()) as u64
        })
        .unwrap_or(0);
    bounded(px, || oxipng::optimize_from_memory(png, &options(level, false))).map_err(ox)
}
