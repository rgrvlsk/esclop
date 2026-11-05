// SPDX-License-Identifier: GPL-3.0-or-later
//! Decoding to pixels (pure-Rust decoders from the `image` crate), animations as composited
//! frames, EXIF orientation, and the metadata worth carrying into another format.

use crate::ctx::Ctx;
use crate::error::{EngineError, Result};
use crate::format;
use crate::meta;
use crate::protocol::Format;
use image::{AnimationDecoder, DynamicImage, ImageDecoder, ImageReader, Limits, RgbaImage};
use std::io::Cursor;

/// Largest image the engine accepts: 256 megapixels.
pub const MAX_PIXELS: u64 = 256 * 1024 * 1024;

#[derive(Debug, Clone)]
pub struct Frame {
    pub image: RgbaImage,
    pub delay_ms: u32,
}

#[derive(Debug, Clone)]
pub struct Animation {
    pub width: u32,
    pub height: u32,
    pub frames: Vec<Frame>,
    /// 0 loops forever.
    pub repeat: u16,
}

#[derive(Debug, Clone)]
pub enum Content {
    /// `Rgb8`, `Rgba8` (only when some pixel is not opaque) or `Luma8`.
    Still(DynamicImage),
    Anim(Animation),
}

impl Content {
    pub fn dimensions(&self) -> (u32, u32) {
        match self {
            Content::Still(i) => (i.width(), i.height()),
            Content::Anim(a) => (a.width, a.height),
        }
    }

    pub fn frames(&self) -> u32 {
        match self {
            Content::Still(_) => 1,
            Content::Anim(a) => a.frames.len() as u32,
        }
    }

    /// The first frame, borrowed when the content is a still image.
    pub fn first_frame(&self) -> std::borrow::Cow<'_, DynamicImage> {
        match self {
            Content::Still(i) => std::borrow::Cow::Borrowed(i),
            Content::Anim(a) => std::borrow::Cow::Owned(normalise(DynamicImage::ImageRgba8(
                a.frames.first().map(|f| f.image.clone()).unwrap_or_default(),
            ))),
        }
    }

    /// The first frame as a still image (for encoders without animation).
    pub fn into_still(self) -> DynamicImage {
        match self {
            Content::Still(i) => i,
            Content::Anim(a) => {
                normalise(DynamicImage::ImageRgba8(a.frames.into_iter().next().map(|f| f.image).unwrap_or_default()))
            }
        }
    }
}

/// Metadata that survives a change of format.
#[derive(Debug, Clone, Default)]
pub struct SourceMeta {
    pub icc: Option<Vec<u8>>,
    /// TIFF payload, without the `Exif\0\0` prefix.
    pub exif: Option<Vec<u8>>,
    pub orientation: u8,
}

#[derive(Debug, Clone)]
pub struct Decoded {
    pub format: Format,
    pub content: Content,
    pub meta: SourceMeta,
}

fn limits() -> Limits {
    let mut l = Limits::default();
    l.max_image_width = Some(65_535);
    l.max_image_height = Some(65_535);
    l.max_alloc = Some(MAX_PIXELS * 4 + (64 << 20));
    l
}

fn image_format(f: Format) -> Option<image::ImageFormat> {
    Some(match f {
        Format::Png => image::ImageFormat::Png,
        Format::Jpeg => image::ImageFormat::Jpeg,
        Format::Gif => image::ImageFormat::Gif,
        Format::Webp => image::ImageFormat::WebP,
        Format::Tiff => image::ImageFormat::Tiff,
        Format::Bmp => image::ImageFormat::Bmp,
        _ => return None,
    })
}

/// Detects the format, refusing what the engine cannot decode.
pub fn detect(bytes: &[u8]) -> Result<Format> {
    match format::sniff(bytes) {
        Some(f) if format::decodable(f) => Ok(f),
        Some(f) => Err(EngineError::unsupported(format!(
            "{} input is decoded by the system (ImageIO), not the engine",
            f.name()
        ))),
        None => Err(EngineError::unsupported("unrecognised image format")),
    }
}

/// Decodes `bytes`. With `animated`, multi-frame GIF/WebP/APNG come back as `Content::Anim`;
/// otherwise only the first frame is decoded.
pub fn decode(bytes: &[u8], animated: bool, ctx: &Ctx) -> Result<Decoded> {
    let fmt = detect(bytes)?;
    ctx.progress(0.0, "decode");
    let meta = source_meta(bytes, fmt);
    if animated && is_animated(bytes, fmt) {
        let anim = decode_animation(bytes, fmt, ctx)?;
        return Ok(Decoded { format: fmt, content: Content::Anim(anim), meta });
    }
    let mut reader = ImageReader::with_format(Cursor::new(bytes), image_format(fmt).unwrap());
    reader.limits(limits());
    let dec = reader.into_decoder()?;
    let (w, h) = dec.dimensions();
    check_size(w, h)?;
    let img = DynamicImage::from_decoder(dec)?;
    ctx.check()?;
    Ok(Decoded { format: fmt, content: Content::Still(normalise(img)), meta })
}

pub fn check_size(w: u32, h: u32) -> Result<()> {
    if w == 0 || h == 0 {
        return Err(EngineError::decode("image has no pixels"));
    }
    if w as u64 * h as u64 > MAX_PIXELS {
        return Err(EngineError::unsupported(format!("{w}x{h} is larger than the engine's 256-megapixel limit")));
    }
    Ok(())
}

/// Rgb8 / Rgba8 / Luma8, dropping an alpha channel that is fully opaque and 16-bit precision.
pub fn normalise(img: DynamicImage) -> DynamicImage {
    use DynamicImage as D;
    match img {
        D::ImageLuma8(_) | D::ImageRgb8(_) => img,
        D::ImageLuma16(_) => D::ImageLuma8(img.to_luma8()),
        D::ImageRgb16(_) | D::ImageRgb32F(_) => D::ImageRgb8(img.to_rgb8()),
        D::ImageRgba8(rgba) => {
            if rgba.pixels().all(|p| p.0[3] == 255) {
                D::ImageRgb8(DynamicImage::ImageRgba8(rgba).to_rgb8())
            } else {
                D::ImageRgba8(rgba)
            }
        }
        other => {
            let opaque = !other.color().has_alpha();
            let rgba = other.to_rgba8();
            if opaque || rgba.pixels().all(|p| p.0[3] == 255) {
                D::ImageRgb8(D::ImageRgba8(rgba).to_rgb8())
            } else {
                D::ImageRgba8(rgba)
            }
        }
    }
}

pub fn source_meta(bytes: &[u8], fmt: Format) -> SourceMeta {
    let mut m = SourceMeta { orientation: 1, ..Default::default() };
    match fmt {
        Format::Jpeg => {
            if let Ok(p) = meta::JpegParts::parse(bytes) {
                m.icc = p.icc();
                m.exif = p.exif().map(<[u8]>::to_vec);
            }
        }
        Format::Webp => {
            if let Ok(w) = meta::WebpChunks::parse(bytes) {
                m.icc = w.get(b"ICCP").map(<[u8]>::to_vec);
                m.exif = w.get(b"EXIF").map(|e| meta::tiff_payload(e).to_vec());
            }
        }
        Format::Png | Format::Tiff => {
            if let Some(f) = image_format(fmt)
                && let Ok(mut d) = ImageReader::with_format(Cursor::new(bytes), f).into_decoder()
            {
                m.icc = d.icc_profile().ok().flatten();
                m.exif = d.exif_metadata().ok().flatten().map(|e| meta::tiff_payload(&e).to_vec());
            }
        }
        _ => {}
    }
    m.orientation = m.exif.as_deref().and_then(meta::exif_orientation).unwrap_or(1);
    m
}

pub fn is_animated(bytes: &[u8], fmt: Format) -> bool {
    match fmt {
        Format::Gif => meta::gif_filter(bytes, |_, _| false).map(|(_, n)| n > 1).unwrap_or(false),
        Format::Webp => meta::WebpChunks::parse(bytes).map(|w| w.is_animated() && w.frames() > 1).unwrap_or(false),
        Format::Png => meta::png_chunks(bytes).map(|c| meta::png_is_animated(&c)).unwrap_or(false),
        _ => false,
    }
}

/// Loop count from the container (0 = forever).
pub fn repeat_count(bytes: &[u8], fmt: Format) -> u16 {
    match fmt {
        Format::Gif => {
            let mut r = 0;
            let _ = meta::gif_filter(bytes, |label, block| {
                if label == 0xFF && meta::gif_is_loop_ext(block) && block.len() >= 19 && block[15] == 1 {
                    r = u16::from_le_bytes([block[16], block[17]]);
                }
                false
            });
            r
        }
        Format::Webp => meta::WebpChunks::parse(bytes)
            .ok()
            .and_then(|w| w.get(b"ANIM").and_then(|a| a.get(4..6)).map(|b| u16::from_le_bytes([b[0], b[1]])))
            .unwrap_or(0),
        Format::Png => meta::png_chunks(bytes)
            .ok()
            .and_then(|c| {
                c.iter()
                    .find(|c| &c.name == b"acTL")
                    .and_then(|a| a.data.get(4..8))
                    .map(|b| u32::from_be_bytes(b.try_into().unwrap()).min(u16::MAX as u32) as u16)
            })
            .unwrap_or(0),
        _ => 0,
    }
}

fn decode_animation(bytes: &[u8], fmt: Format, ctx: &Ctx) -> Result<Animation> {
    let frames: Box<dyn Iterator<Item = image::ImageResult<image::Frame>>> = match fmt {
        Format::Gif => Box::new(image::codecs::gif::GifDecoder::new(Cursor::new(bytes))?.into_frames()),
        Format::Webp => Box::new(image::codecs::webp::WebPDecoder::new(Cursor::new(bytes))?.into_frames()),
        Format::Png => Box::new(image::codecs::png::PngDecoder::new(Cursor::new(bytes))?.apng()?.into_frames()),
        _ => return Err(EngineError::unsupported("not an animation")),
    };
    let mut out = Vec::new();
    let mut total: u64 = 0;
    for f in frames {
        let f = f?;
        let (n, d) = f.delay().numer_denom_ms();
        let delay_ms = n.checked_div(d).unwrap_or(100);
        let image = f.into_buffer();
        total += image.width() as u64 * image.height() as u64;
        if total > MAX_PIXELS * 2 {
            return Err(EngineError::unsupported("animation has too many pixels across its frames"));
        }
        out.push(Frame { image, delay_ms });
        if out.len() % 16 == 0 {
            ctx.check()?;
        }
    }
    let first = out.first().ok_or_else(|| EngineError::decode("animation has no frames"))?;
    let (width, height) = first.image.dimensions();
    check_size(width, height)?;
    Ok(Animation { width, height, frames: out, repeat: repeat_count(bytes, fmt) })
}

/// Turns stored pixels upright for an EXIF orientation 1..=8.
pub fn orient(img: DynamicImage, orientation: u8) -> DynamicImage {
    match orientation {
        2 => img.fliph(),
        3 => img.rotate180(),
        4 => img.flipv(),
        5 => img.rotate90().fliph(),
        6 => img.rotate90(),
        7 => img.rotate270().fliph(),
        8 => img.rotate270(),
        _ => img,
    }
}

pub fn orient_content(c: Content, orientation: u8) -> Content {
    if orientation <= 1 || orientation > 8 {
        return c;
    }
    match c {
        Content::Still(i) => Content::Still(orient(i, orientation)),
        Content::Anim(mut a) => {
            for f in &mut a.frames {
                let img = orient(DynamicImage::ImageRgba8(std::mem::take(&mut f.image)), orientation);
                f.image = img.to_rgba8();
            }
            if let Some(f) = a.frames.first() {
                (a.width, a.height) = f.image.dimensions();
            }
            Content::Anim(a)
        }
    }
}

/// Size after orientation.
pub fn display_size(w: u32, h: u32, orientation: u8) -> (u32, u32) {
    if (5..=8).contains(&orientation) { (h, w) } else { (w, h) }
}

/// Composites over white (for formats without alpha).
pub fn flatten(img: DynamicImage) -> DynamicImage {
    match img {
        DynamicImage::ImageRgba8(rgba) => {
            let (w, h) = rgba.dimensions();
            let mut out = image::RgbImage::new(w, h);
            for (o, p) in out.pixels_mut().zip(rgba.pixels()) {
                let a = p.0[3] as u32;
                for c in 0..3 {
                    o.0[c] = ((p.0[c] as u32 * a + 255 * (255 - a) + 127) / 255) as u8;
                }
            }
            DynamicImage::ImageRgb8(out)
        }
        other => other,
    }
}
