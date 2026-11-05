// SPDX-License-Identifier: GPL-3.0-or-later
//! `fit`: the highest quality, then the largest scale, whose output is at most `target_bytes`.
//! Each probe encodes from the decoded original, so nothing compounds.

use super::geometry::{resized_copy, scaled};
use super::{Encoded, carry, default_format, encode_content, finish, open, parse_params};
use crate::codec;
use crate::ctx::Ctx;
use crate::error::{EngineError, Result};
use crate::meta;
use crate::pixels;
use crate::pixels::Content;
use crate::protocol::{EncodeParams, Filter, FitParams, Format, OpResult, Request};
use std::cell::{Cell, RefCell};

pub fn fit(req: &Request, ctx: &Ctx) -> Result<OpResult> {
    let (p, ignored) = parse_params::<FitParams>(&req.params)?;
    if p.target_bytes == 0 {
        return Err(EngineError::invalid("`target_bytes` must be > 0"));
    }
    let min_q = p.min_quality.unwrap_or(10);
    let mut max_q = p.max_quality.unwrap_or(95);
    let min_scale = p.min_scale.unwrap_or(0.1);
    if min_q > 100 || max_q > 100 || min_q > max_q {
        return Err(EngineError::invalid("need 0 <= min_quality <= max_quality <= 100"));
    }
    if !(min_scale > 0.0 && min_scale <= 1.0) {
        return Err(EngineError::invalid("`min_scale` must be in (0, 1]"));
    }
    let (bytes, target) = open(req, &p.out)?;
    let in_fmt = pixels::detect(&bytes)?;
    let fmt = p.format.unwrap_or(default_format(in_fmt));
    if !fmt.encodable() {
        return Err(EngineError::unsupported(format!("the engine cannot encode {}", fmt.name())));
    }
    let goal = p.target_bytes;
    if fmt == in_fmt && bytes.len() as u64 <= goal {
        return Err(EngineError::new(
            crate::error::ErrorCode::AlreadySmaller,
            format!("the input ({} bytes) is already within {goal} bytes; nothing was written", bytes.len()),
        ));
    }
    // A JPEG never gets better by re-encoding above its own quality.
    if in_fmt == Format::Jpeg
        && fmt == Format::Jpeg
        && let Some(t) = meta::JpegParts::parse(&bytes).ok().and_then(|j| j.luma_qtable())
    {
        max_q = max_q.min(codec::jpeg::codec().estimate_quality(&t).max(min_q));
    }
    let decoded = pixels::decode(&bytes, matches!(fmt, Format::Gif | Format::Webp), &ctx.sub(0.0, 0.1))?;
    let content = pixels::orient_content(decoded.content, decoded.meta.orientation);
    let c_meta = carry(&decoded.meta, &p.out, true);
    let (w, h) = content.dimensions();

    const BUDGET: f32 = 24.0;
    let probes = Cell::new(0u32);
    let quiet = Ctx::new(ctx.cancel_flag(), std::sync::Arc::new(|_, _| {}));
    let animated = matches!(fmt, Format::Gif | Format::Webp);
    // Large images do not keep the full-size pixels while probing smaller scales: each scale is
    // decoded afresh, so the original, a resized copy and an encoder never coexist.
    let big = w as u64 * h as u64 >= 8_000_000;
    let full: RefCell<Option<Content>> = RefCell::new(Some(content));
    // JPEG probes are progressive with the standard scan script: within a few percent of the
    // final size, without the memory of mozjpeg's scan search, whose buffers grow with quality.
    // The chosen quality is then encoded once with the search, which can only come out smaller.
    let encode_with = |c: &Content, q: u8, final_pass: bool| -> Result<Encoded> {
        ctx.check()?;
        let n = probes.get();
        probes.set(n + 1);
        ctx.progress(0.1 + 0.88 * (n as f32 / BUDGET).min(1.0), "search");
        let enc = EncodeParams {
            quality: Some(q),
            lossy: p.lossy,
            speed: p.speed,
            lossless: Some(false),
            jpeg_fast_scans: !final_pass,
            ..Default::default()
        };
        let e = encode_content(c, fmt, &enc, &c_meta, &quiet)?;
        crate::log::debug(&format!(
            "fit probe q{q} {}x{} final={final_pass}: {} bytes (target {goal}), peak {} MB",
            e.width,
            e.height,
            e.bytes.len(),
            crate::log::peak_rss_mb()
        ));
        Ok(e)
    };
    let encode_q = |c: &Content, q: u8| encode_with(c, q, fmt != Format::Jpeg);
    let at_scale = |scale: f64| -> Result<Content> {
        let (nw, nh) = scaled(w, h, scale);
        if big {
            full.borrow_mut().take();
            let d = pixels::decode(&bytes, animated, &quiet)?;
            let original = pixels::orient_content(d.content, d.meta.orientation);
            resized_copy(&original, nw, nh, Filter::Lanczos3, &quiet)
        } else {
            resized_copy(full.borrow().as_ref().expect("kept for small images"), nw, nh, Filter::Lanczos3, &quiet)
        }
    };
    let fits = |e: &Encoded| e.bytes.len() as u64 <= goal;

    // Highest quality in [lo, hi] that fits `c`, given that `lo` fits (`lo_enc`).
    let best_quality = |c: &Content, lo: u8, lo_enc: Encoded, hi: u8| -> Result<(u8, Encoded)> {
        let (mut lo, mut best, mut hi) = (lo, lo_enc, hi);
        if lo == hi {
            return Ok((lo, best));
        }
        let top = encode_q(c, hi)?;
        if fits(&top) {
            return Ok((hi, top));
        }
        drop(top);
        while hi - lo > 1 {
            let mid = lo + (hi - lo) / 2;
            let e = encode_q(c, mid)?;
            if fits(&e) {
                lo = mid;
                best = e;
            } else {
                hi = mid;
            }
        }
        Ok((lo, best))
    };

    let floor = {
        let f = full.borrow();
        encode_q(f.as_ref().unwrap(), min_q)?
    };
    let (q, scale, enc, fitted) = if fits(&floor) {
        let f = full.borrow();
        let (q, e) = best_quality(f.as_ref().unwrap(), min_q, floor, max_q)?;
        (q, 1.0, e, true)
    } else if !p.allow_resize.unwrap_or(true) || fmt == Format::Gif && w.max(h) <= 16 {
        (min_q, 1.0, floor, false)
    } else {
        // Largest scale that fits at the lowest quality, from an area estimate, then bisection.
        let mut lo_s = min_scale;
        let mut hi_s = 1.0f64;
        let mut best: Option<(f64, Encoded)> = None;
        let mut guess = ((goal as f64 / floor.bytes.len() as f64).sqrt() * 0.95).clamp(min_scale, 0.99);
        drop(floor);
        for _ in 0..7 {
            let e = encode_q(&at_scale(guess)?, min_q)?;
            if fits(&e) {
                lo_s = guess;
                best = Some((guess, e));
            } else {
                hi_s = guess;
            }
            if hi_s / lo_s < 1.04 || (best.is_none() && guess <= min_scale) {
                break;
            }
            guess = if best.is_some() { (lo_s + hi_s) / 2.0 } else { (guess * 0.7).max(min_scale) };
        }
        match best {
            Some((s, e)) => {
                let (q, e) = best_quality(&at_scale(s)?, min_q, e, max_q)?;
                (q, s, e, true)
            }
            None => {
                let e = encode_q(&at_scale(min_scale)?, min_q)?;
                let ok = fits(&e);
                (min_q, min_scale, e, ok)
            }
        }
    };
    let enc = if fmt == Format::Jpeg {
        let progressive = if scale >= 1.0 && full.borrow().is_some() {
            let f = full.borrow();
            encode_with(f.as_ref().unwrap(), q, true)?
        } else {
            encode_with(&at_scale(scale)?, q, true)?
        };
        if progressive.bytes.len() <= enc.bytes.len() { progressive } else { enc }
    } else {
        enc
    };
    ctx.check()?;
    let mut r = finish(&target, bytes.len() as u64, enc, true, ignored, ctx)?;
    r.quality = Some(q);
    r.scale = Some(scaled(w, h, scale).0 as f64 / w as f64);
    r.fitted = Some(fitted);
    Ok(r)
}
