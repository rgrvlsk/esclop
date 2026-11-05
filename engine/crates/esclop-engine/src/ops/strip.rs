// SPDX-License-Identifier: GPL-3.0-or-later
//! `metadata.strip`: container surgery, pixels untouched.

use super::optimise::{gif_size, jpeg_size};
use super::{Encoded, finish, open, parse_params};
use crate::ctx::Ctx;
use crate::error::{EngineError, Result};
use crate::format;
use crate::meta;
use crate::protocol::{DEFAULT_KEEP, Format, Keep, OpResult, OutputParams, Request, StripParams};

pub fn strip(req: &Request, ctx: &Ctx) -> Result<OpResult> {
    let (p, ignored) = parse_params::<StripParams>(&req.params)?;
    let out = OutputParams { in_place: p.in_place, ..Default::default() };
    let (bytes, target) = open(req, &out)?;
    let keep: Vec<Keep> = p.keep.clone().unwrap_or_else(|| DEFAULT_KEEP.to_vec());
    let fmt = format::sniff(&bytes).ok_or_else(|| EngineError::unsupported("unrecognised image format"))?;
    let (data, (w, h)) = match fmt {
        Format::Jpeg => {
            let parts = meta::JpegParts::parse(&bytes)?;
            let o = parts.orientation();
            let extra = if keep.contains(&Keep::Orientation) && o != 1 {
                vec![(meta::APP1, meta::exif_app1(&meta::minimal_exif(o)))]
            } else {
                vec![]
            };
            let keep_icc = keep.contains(&Keep::Icc);
            (meta::jpeg_rebuild(&parts, &extra, |s| !s.is_metadata() || (keep_icc && s.is_icc())), jpeg_size(&parts))
        }
        Format::Png => {
            let chunks = meta::png_chunks(&bytes)?;
            let d = chunks[0].data;
            let size =
                (u32::from_be_bytes(d[0..4].try_into().unwrap()), u32::from_be_bytes(d[4..8].try_into().unwrap()));
            (meta::png_strip(&bytes, &keep)?, size)
        }
        Format::Webp => {
            let size = meta::WebpChunks::parse(&bytes)?.dimensions().unwrap_or((0, 0));
            (meta::webp_strip(&bytes, &keep)?, size)
        }
        Format::Gif => (meta::gif_strip(&bytes)?, gif_size(&bytes)),
        other => return Err(EngineError::unsupported(format!("metadata.strip does not handle {}", other.name()))),
    };
    let enc = Encoded { bytes: data, width: w, height: h, format: Some(fmt), lossy: false, ..Default::default() };
    finish(&target, bytes.len() as u64, enc, p.allow_larger.unwrap_or(true), ignored, ctx)
}
