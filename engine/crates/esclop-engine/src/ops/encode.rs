// SPDX-License-Identifier: GPL-3.0-or-later
//! `webp.encode`, `avif.encode`, `convert`: decode anything decodable, encode to a format.

use super::{carry, encode_content, finish, open, parse_params};
use crate::ctx::Ctx;
use crate::error::{EngineError, Result};
use crate::pixels;
use crate::protocol::{AvifParams, ConvertParams, EncodeParams, Format, OpResult, OutputParams, Request, WebpParams};

/// Shared body: decode (keeping animation when the target can hold it), turn upright unless the
/// target is JPEG (which keeps the EXIF orientation as stored), encode, write.
pub fn run(
    req: &Request,
    fmt: Format,
    enc: &EncodeParams,
    out: &OutputParams,
    ignored: Vec<String>,
    ctx: &Ctx,
) -> Result<OpResult> {
    if !fmt.encodable() {
        return Err(EngineError::unsupported(format!("the engine cannot encode {}", fmt.name())));
    }
    let (bytes, target) = open(req, out)?;
    let animated = matches!(fmt, Format::Webp | Format::Gif);
    let decoded = pixels::decode(&bytes, animated, &ctx.sub(0.0, 0.3))?;
    let upright = fmt != Format::Jpeg && decoded.meta.orientation != 1;
    let content =
        if upright { pixels::orient_content(decoded.content, decoded.meta.orientation) } else { decoded.content };
    let c = carry(&decoded.meta, out, upright);
    let e = encode_content(&content, fmt, enc, &c, &ctx.sub(0.3, 0.98))?;
    finish(&target, bytes.len() as u64, e, out.allow_larger.unwrap_or(true), ignored, ctx)
}

pub fn webp(req: &Request, ctx: &Ctx) -> Result<OpResult> {
    let (p, ignored) = parse_params::<WebpParams>(&req.params)?;
    if p.method.is_some_and(|m| m > 6) {
        return Err(EngineError::invalid("`method` must be 0..=6"));
    }
    let enc = EncodeParams {
        compression: p.compression,
        quality: p.quality,
        lossless: p.lossless,
        method: p.method,
        ..Default::default()
    };
    run(req, Format::Webp, &enc, &p.out, ignored, ctx)
}

pub fn avif(req: &Request, ctx: &Ctx) -> Result<OpResult> {
    let (p, ignored) = parse_params::<AvifParams>(&req.params)?;
    if p.speed.is_some_and(|s| !(1..=10).contains(&s)) {
        return Err(EngineError::invalid("`speed` must be 1..=10"));
    }
    let enc = EncodeParams { compression: p.compression, quality: p.quality, speed: p.speed, ..Default::default() };
    run(req, Format::Avif, &enc, &p.out, ignored, ctx)
}

pub fn convert(req: &Request, ctx: &Ctx) -> Result<OpResult> {
    let (p, ignored) = parse_params::<ConvertParams>(&req.params)?;
    let fmt = p.format.ok_or_else(|| EngineError::invalid("missing `format` (png, jpeg, webp, avif or gif)"))?;
    run(req, fmt, &p.encode, &p.out, ignored, ctx)
}
