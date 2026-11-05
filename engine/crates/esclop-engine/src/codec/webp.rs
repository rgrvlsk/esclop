// SPDX-License-Identifier: GPL-3.0-or-later
//! WebP through libwebp (the `webp` crate), still and animated, with ICC/EXIF carried in a
//! correctly flagged VP8X container.

use crate::error::{EngineError, Result};
use crate::meta::{self, WebpChunks};
use crate::pixels::Animation;
use image::DynamicImage;

#[derive(Debug, Clone, Copy)]
pub struct WebpOptions {
    pub quality: u8,
    pub lossless: bool,
    pub method: u8,
}

/// Above this many pixels sharp YUV is skipped: its temporaries alone take ~230 MB on a
/// 24-megapixel image (cwebp -sharp_yuv peaks at 359 MB there), and its benefit, crisp colour
/// edges in UI screenshots, is for images well below this size.
const SHARP_YUV_MAX_PIXELS: u64 = 16_000_000;

fn config(o: &WebpOptions, pixels: u64) -> Result<webp::WebPConfig> {
    let mut c = webp::WebPConfig::new().map_err(|_| EngineError::internal("libwebp config"))?;
    c.quality = o.quality as f32;
    c.lossless = o.lossless as i32;
    c.method = o.method.min(6) as i32;
    // cwebp -sharp_yuv, as the reference does: sharper colour edges for screenshots
    c.use_sharp_yuv = (!o.lossless && pixels <= SHARP_YUV_MAX_PIXELS) as i32;
    c.thread_level = 1;
    if o.lossless {
        c.exact = 0;
    }
    Ok(c)
}

/// Encodes a still image. `icc`/`exif` (TIFF payload) are embedded when given.
pub fn encode_still(img: &DynamicImage, o: &WebpOptions, icc: Option<&[u8]>, exif: Option<&[u8]>) -> Result<Vec<u8>> {
    let (w, h) = (img.width(), img.height());
    if w > 16383 || h > 16383 {
        return Err(EngineError::unsupported("WebP is limited to 16383 pixels per side"));
    }
    let cfg = config(o, w as u64 * h as u64)?;
    let mem = match img {
        DynamicImage::ImageRgba8(rgba) => webp::Encoder::from_rgba(rgba.as_raw(), w, h).encode_advanced(&cfg),
        DynamicImage::ImageRgb8(rgb) => webp::Encoder::from_rgb(rgb.as_raw(), w, h).encode_advanced(&cfg),
        other => {
            let rgb = other.to_rgb8();
            webp::Encoder::from_rgb(rgb.as_raw(), w, h).encode_advanced(&cfg)
        }
    }
    .map_err(|e| EngineError::encode(format!("libwebp: {e:?}")))?;
    with_metadata(&mem, icc, exif)
}

pub fn encode_animation(a: &Animation, o: &WebpOptions, icc: Option<&[u8]>, exif: Option<&[u8]>) -> Result<Vec<u8>> {
    if a.width > 16383 || a.height > 16383 {
        return Err(EngineError::unsupported("WebP is limited to 16383 pixels per side"));
    }
    let cfg = config(o, a.width as u64 * a.height as u64)?;
    let mut enc = webp::AnimEncoder::new(a.width, a.height, &cfg);
    enc.set_loop_count(a.repeat as i32);
    let mut t = 0i32;
    for f in &a.frames {
        enc.add_frame(webp::AnimFrame::from_rgba(f.image.as_raw(), a.width, a.height, t));
        t += f.delay_ms.max(10) as i32;
    }
    let mem = enc.try_encode().map_err(|e| EngineError::encode(format!("libwebp animation: {e:?}")))?;
    with_metadata(&mem, icc, exif)
}

fn with_metadata(webp: &[u8], icc: Option<&[u8]>, exif: Option<&[u8]>) -> Result<Vec<u8>> {
    if icc.is_none() && exif.is_none() {
        return Ok(webp.to_vec());
    }
    let chunks = WebpChunks::parse(webp)?;
    meta::webp_build(&chunks.chunks, icc, exif, None)
}
