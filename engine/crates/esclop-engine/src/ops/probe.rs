// SPDX-License-Identifier: GPL-3.0-or-later
//! `probe`: what the input is, without decoding its pixels.

use super::{input_path, parse_params};
use crate::codec;
use crate::ctx::Ctx;
use crate::error::{EngineError, Result};
use crate::format;
use crate::fsio;
use crate::meta;
use crate::pixels;
use crate::protocol::{Format, OpResult, ProbeInfo, ProbeParams, Request};
use image::{ImageDecoder, ImageReader};
use std::io::Cursor;

pub fn probe(req: &Request, _ctx: &Ctx) -> Result<OpResult> {
    let (_p, ignored) = parse_params::<ProbeParams>(&req.params)?;
    let bytes = fsio::read_input(input_path(req)?)?;
    let fmt = format::sniff(&bytes).ok_or_else(|| EngineError::unsupported("unrecognised image format"))?;
    let size = bytes.len() as u64;
    let mut r = OpResult {
        bytes_before: size,
        bytes_after: size,
        format: Some(fmt),
        ignored_params: ignored,
        ..Default::default()
    };
    let mut info = ProbeInfo { orientation: 1, frames: 1, ..Default::default() };
    if !format::decodable(fmt) {
        r.probe = Some(info);
        return Ok(r);
    }
    info.decodable = true;
    let ifmt = match fmt {
        Format::Png => image::ImageFormat::Png,
        Format::Jpeg => image::ImageFormat::Jpeg,
        Format::Gif => image::ImageFormat::Gif,
        Format::Webp => image::ImageFormat::WebP,
        Format::Tiff => image::ImageFormat::Tiff,
        _ => image::ImageFormat::Bmp,
    };
    let dec = ImageReader::with_format(Cursor::new(&bytes), ifmt).into_decoder()?;
    let (w, h) = dec.dimensions();
    let ct = dec.color_type();
    let oct = dec.original_color_type();
    r.width = w;
    r.height = h;
    info.has_alpha = ct.has_alpha();
    info.bit_depth = Some((oct.bits_per_pixel() / oct.channel_count().max(1) as u16) as u8);
    info.color_space = Some(if ct.has_color() { "rgb" } else { "gray" }.to_string());
    let m = pixels::source_meta(&bytes, fmt);
    info.has_icc = m.icc.is_some();
    info.has_exif = m.exif.is_some();
    info.orientation = m.orientation;
    match fmt {
        Format::Jpeg => {
            let parts = meta::JpegParts::parse(&bytes)?;
            info.has_xmp = parts.has_xmp();
            info.progressive = Some(parts.progressive());
            info.jpeg_quality = parts.luma_qtable().map(|t| codec::jpeg::codec().estimate_quality(&t));
            if parts.components() == 4 {
                let ycck = parts.segments.iter().any(|s| s.is_adobe() && s.data.get(11) == Some(&2));
                info.color_space = Some(if ycck { "ycck" } else { "cmyk" }.into());
            }
            info.multi_picture = parts.has_mpf();
        }
        Format::Png => {
            let chunks = meta::png_chunks(&bytes)?;
            if chunks[0].data.get(9) == Some(&3) {
                info.color_space = Some("indexed".into());
            }
            info.has_xmp = chunks.iter().any(|c| &c.name == b"iTXt" && c.data.starts_with(b"XML:com.adobe.xmp\0"));
            info.has_alpha |= chunks.iter().any(|c| &c.name == b"tRNS");
            if meta::png_is_animated(&chunks) {
                info.frames = chunks
                    .iter()
                    .find(|c| &c.name == b"acTL")
                    .and_then(|c| c.data.get(0..4))
                    .map(|b| u32::from_be_bytes(b.try_into().unwrap()))
                    .unwrap_or(1);
            }
        }
        Format::Gif => {
            info.color_space = Some("indexed".into());
            info.frames = meta::gif_filter(&bytes, |_, _| false)?.1;
        }
        Format::Webp => {
            let wc = meta::WebpChunks::parse(&bytes)?;
            info.has_xmp = wc.get(b"XMP ").is_some();
            info.frames = wc.frames();
            info.has_alpha |= wc.has_alpha();
        }
        _ => {}
    }
    info.animated = info.frames > 1;
    (info.display_width, info.display_height) = pixels::display_size(w, h, info.orientation);
    r.frames = Some(info.frames);
    r.probe = Some(info);
    Ok(r)
}
