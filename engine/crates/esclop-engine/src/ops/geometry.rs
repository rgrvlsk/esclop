// SPDX-License-Identifier: GPL-3.0-or-later
//! `resize` and `crop`. Both work in displayed pixels: EXIF orientation is applied first and the
//! output is written upright (orientation 1).

use super::{carry, default_format, encode_content, finish, open, parse_params};
use crate::ctx::Ctx;
use crate::error::{EngineError, Result};
use crate::pixels::{self, Content};
use crate::protocol::{Aspect, CropParams, Filter, Format, Gravity, OpResult, Rect, Request, ResizeParams};
use fast_image_resize as fr;
use image::DynamicImage;

pub fn resize(req: &Request, ctx: &Ctx) -> Result<OpResult> {
    let (p, ignored) = parse_params::<ResizeParams>(&req.params)?;
    let (bytes, target) = open(req, &p.out)?;
    let fmt = p.format.unwrap_or(default_format(pixels::detect(&bytes)?));
    let decoded = pixels::decode(&bytes, matches!(fmt, Format::Gif | Format::Webp), &ctx.sub(0.0, 0.2))?;
    let content = pixels::orient_content(decoded.content, decoded.meta.orientation);
    let (w, h) = content.dimensions();
    let scale = target_scale(w, h, &p)?;
    let (nw, nh) = scaled(w, h, scale);
    ctx.progress(0.25, "resize");
    let content = resize_content(content, nw, nh, p.filter.unwrap_or_default(), ctx)?;
    let c = carry(&decoded.meta, &p.out, true);
    let e = encode_content(&content, fmt, &p.encode, &c, &ctx.sub(0.4, 0.98))?;
    let mut r = finish(&target, bytes.len() as u64, e, p.out.allow_larger.unwrap_or(true), ignored, ctx)?;
    r.scale = Some(nw as f64 / w as f64);
    Ok(r)
}

/// The factor `resize` applies to the displayed size.
pub fn target_scale(w: u32, h: u32, p: &ResizeParams) -> Result<f64> {
    let given = [p.scale.is_some(), p.long_edge.is_some(), p.width.is_some() || p.height.is_some()]
        .iter()
        .filter(|b| **b)
        .count();
    if given != 1 {
        return Err(EngineError::invalid("give exactly one of `scale`, `long_edge`, or `width`/`height`"));
    }
    let positive = |v: u32, name: &str| {
        if v == 0 { Err(EngineError::invalid(format!("`{name}` must be > 0"))) } else { Ok(v as f64) }
    };
    let s = if let Some(s) = p.scale {
        if !(s > 0.0 && s <= 4.0) {
            return Err(EngineError::invalid("`scale` must be in (0, 4]"));
        }
        s
    } else if let Some(l) = p.long_edge {
        positive(l, "long_edge")? / w.max(h) as f64
    } else {
        let sw = p.width.map(|v| positive(v, "width").map(|v| v / w as f64)).transpose()?;
        let sh = p.height.map(|v| positive(v, "height").map(|v| v / h as f64)).transpose()?;
        match (sw, sh) {
            (Some(a), Some(b)) => a.min(b),
            (Some(a), None) | (None, Some(a)) => a,
            (None, None) => unreachable!(),
        }
    };
    Ok(if p.only_shrink.unwrap_or(true) { s.min(1.0) } else { s.min(16.0) })
}

pub fn scaled(w: u32, h: u32, s: f64) -> (u32, u32) {
    (((w as f64 * s).round() as u32).max(1), ((h as f64 * s).round() as u32).max(1))
}

pub fn resize_content(c: Content, nw: u32, nh: u32, filter: Filter, ctx: &Ctx) -> Result<Content> {
    let (w, h) = c.dimensions();
    if (w, h) == (nw, nh) {
        return Ok(c);
    }
    pixels::check_size(nw, nh)?;
    Ok(match c {
        Content::Still(img) => Content::Still(resize_image(&img, nw, nh, filter)?),
        Content::Anim(mut a) => {
            for f in &mut a.frames {
                ctx.check()?;
                let img = resize_image(&DynamicImage::ImageRgba8(std::mem::take(&mut f.image)), nw, nh, filter)?;
                f.image = img.into_rgba8();
            }
            a.width = nw;
            a.height = nh;
            Content::Anim(a)
        }
    })
}

/// A resized copy, leaving `c` untouched (for `fit`, which probes many sizes of one original).
pub fn resized_copy(c: &Content, nw: u32, nh: u32, filter: Filter, ctx: &Ctx) -> Result<Content> {
    pixels::check_size(nw, nh)?;
    Ok(match c {
        Content::Still(img) => Content::Still(resize_image(img, nw, nh, filter)?),
        Content::Anim(a) => {
            let mut frames = Vec::with_capacity(a.frames.len());
            for f in &a.frames {
                ctx.check()?;
                let img = resize_image(&DynamicImage::ImageRgba8(f.image.clone()), nw, nh, filter)?;
                frames.push(pixels::Frame { image: img.into_rgba8(), delay_ms: f.delay_ms });
            }
            Content::Anim(pixels::Animation { width: nw, height: nh, frames, repeat: a.repeat })
        }
    })
}

fn alg(f: Filter) -> fr::ResizeAlg {
    use fr::FilterType as T;
    match f {
        Filter::Nearest => fr::ResizeAlg::Nearest,
        Filter::Box => fr::ResizeAlg::Convolution(T::Box),
        Filter::Bilinear => fr::ResizeAlg::Convolution(T::Bilinear),
        Filter::Hamming => fr::ResizeAlg::Convolution(T::Hamming),
        Filter::CatmullRom => fr::ResizeAlg::Convolution(T::CatmullRom),
        Filter::Mitchell => fr::ResizeAlg::Convolution(T::Mitchell),
        Filter::Lanczos3 => fr::ResizeAlg::Convolution(T::Lanczos3),
    }
}

/// Resamples with fast_image_resize (SIMD). Alpha is premultiplied around the convolution.
pub fn resize_image(img: &DynamicImage, nw: u32, nh: u32, filter: Filter) -> Result<DynamicImage> {
    let (w, h) = (img.width(), img.height());
    let err = |e: &dyn std::fmt::Display| EngineError::internal(format!("resize: {e}"));
    let (pt, data): (fr::PixelType, &[u8]) = match img {
        DynamicImage::ImageLuma8(i) => (fr::PixelType::U8, i.as_raw()),
        DynamicImage::ImageRgb8(i) => (fr::PixelType::U8x3, i.as_raw()),
        DynamicImage::ImageRgba8(i) => (fr::PixelType::U8x4, i.as_raw()),
        other => return resize_image(&pixels::normalise(other.clone()), nw, nh, filter),
    };
    let src = fr::images::ImageRef::new(w, h, data, pt).map_err(|e| err(&e))?;
    let mut dst = fr::images::Image::new(nw, nh, pt);
    let opts = fr::ResizeOptions::new().resize_alg(alg(filter)).use_alpha(true);
    fr::Resizer::new().resize(&src, &mut dst, &opts).map_err(|e| err(&e))?;
    let buf = dst.into_vec();
    let bad = || EngineError::internal("resize: buffer size");
    Ok(match pt {
        fr::PixelType::U8 => DynamicImage::ImageLuma8(image::GrayImage::from_raw(nw, nh, buf).ok_or_else(bad)?),
        fr::PixelType::U8x3 => DynamicImage::ImageRgb8(image::RgbImage::from_raw(nw, nh, buf).ok_or_else(bad)?),
        _ => DynamicImage::ImageRgba8(image::RgbaImage::from_raw(nw, nh, buf).ok_or_else(bad)?),
    })
}

pub fn crop(req: &Request, ctx: &Ctx) -> Result<OpResult> {
    let (p, ignored) = parse_params::<CropParams>(&req.params)?;
    let (bytes, target) = open(req, &p.out)?;
    let fmt = p.format.unwrap_or(default_format(pixels::detect(&bytes)?));
    let decoded = pixels::decode(&bytes, matches!(fmt, Format::Gif | Format::Webp), &ctx.sub(0.0, 0.2))?;
    let content = pixels::orient_content(decoded.content, decoded.meta.orientation);
    let (w, h) = content.dimensions();
    let (rect, size) = crop_plan(w, h, &p)?;
    ctx.progress(0.25, "crop");
    let content = crop_content(content, rect);
    let content = match size {
        Some((nw, nh)) => resize_content(content, nw, nh, Filter::Lanczos3, ctx)?,
        None => content,
    };
    let c = carry(&decoded.meta, &p.out, true);
    let e = encode_content(&content, fmt, &p.encode, &c, &ctx.sub(0.4, 0.98))?;
    finish(&target, bytes.len() as u64, e, p.out.allow_larger.unwrap_or(true), ignored, ctx)
}

fn crop_content(c: Content, r: Rect) -> Content {
    match c {
        Content::Still(img) => Content::Still(img.crop_imm(r.x, r.y, r.width, r.height)),
        Content::Anim(mut a) => {
            for f in &mut a.frames {
                f.image = image::imageops::crop_imm(&f.image, r.x, r.y, r.width, r.height).to_image();
            }
            a.width = r.width;
            a.height = r.height;
            Content::Anim(a)
        }
    }
}

pub fn parse_aspect(a: &Aspect) -> Result<f64> {
    let v = match a {
        Aspect::Ratio(r) => *r,
        Aspect::Text(t) => {
            let t = t.trim();
            match t.split_once([':', '/', 'x']) {
                Some((a, b)) => {
                    let (a, b): (f64, f64) = (a.trim().parse().unwrap_or(0.0), b.trim().parse().unwrap_or(0.0));
                    if b > 0.0 { a / b } else { 0.0 }
                }
                None => t.parse().unwrap_or(0.0),
            }
        }
    };
    if v.is_finite() && v > 0.0 && (1e-3..=1e3).contains(&v) {
        Ok(v)
    } else {
        Err(EngineError::invalid("`aspect` must be like \"16:9\" or a positive number"))
    }
}

/// The rectangle to cut and, for "crop to size", the size to scale it to.
pub fn crop_plan(w: u32, h: u32, p: &CropParams) -> Result<(Rect, Option<(u32, u32)>)> {
    if p.x.is_some() || p.y.is_some() {
        let (Some(x), Some(y), Some(cw), Some(ch)) = (p.x, p.y, p.width, p.height) else {
            return Err(EngineError::invalid("a rectangle crop needs `x`, `y`, `width` and `height`"));
        };
        if cw == 0 || ch == 0 || x as u64 + cw as u64 > w as u64 || y as u64 + ch as u64 > h as u64 {
            return Err(EngineError::invalid(format!("crop rectangle {x},{y} {cw}x{ch} is outside the {w}x{h} image")));
        }
        return Ok((Rect { x, y, width: cw, height: ch }, None));
    }
    let (aspect, size) = match (&p.aspect, p.width, p.height) {
        (Some(a), sw, sh) => {
            let a = parse_aspect(a)?;
            let size = match (sw, sh) {
                (Some(sw), Some(sh)) => Some((sw, sh)),
                (Some(sw), None) => Some((sw, ((sw as f64 / a).round() as u32).max(1))),
                (None, Some(sh)) => Some((((sh as f64 * a).round() as u32).max(1), sh)),
                (None, None) => None,
            };
            (a, size)
        }
        (None, Some(sw), Some(sh)) if sw > 0 && sh > 0 => (sw as f64 / sh as f64, Some((sw, sh))),
        _ => return Err(EngineError::invalid("give `x`,`y`,`width`,`height`; or `aspect`; or `width` and `height`")),
    };
    if size.is_some_and(|(a, b)| a == 0 || b == 0) {
        return Err(EngineError::invalid("`width` and `height` must be > 0"));
    }
    let (cw, ch) = if w as f64 / h as f64 > aspect {
        (((h as f64 * aspect).round() as u32).clamp(1, w), h)
    } else {
        (w, ((w as f64 / aspect).round() as u32).clamp(1, h))
    };
    let (x, y) = if let Some(s) = p.smart {
        let cx = s.x as f64 + s.width as f64 / 2.0;
        let cy = s.y as f64 + s.height as f64 / 2.0;
        (
            (cx - cw as f64 / 2.0).round().clamp(0.0, (w - cw) as f64) as u32,
            (cy - ch as f64 / 2.0).round().clamp(0.0, (h - ch) as f64) as u32,
        )
    } else {
        let (fx, fy) = match p.gravity.unwrap_or_default() {
            Gravity::Center => (0.5, 0.5),
            Gravity::Top => (0.5, 0.0),
            Gravity::Bottom => (0.5, 1.0),
            Gravity::Left => (0.0, 0.5),
            Gravity::Right => (1.0, 0.5),
            Gravity::TopLeft => (0.0, 0.0),
            Gravity::TopRight => (1.0, 0.0),
            Gravity::BottomLeft => (0.0, 1.0),
            Gravity::BottomRight => (1.0, 1.0),
        };
        (((w - cw) as f64 * fx).round() as u32, ((h - ch) as f64 * fy).round() as u32)
    };
    Ok((Rect { x, y, width: cw, height: ch }, size))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cp() -> CropParams {
        CropParams::default()
    }

    #[test]
    fn aspect_crop_with_gravity_and_smart_hint() {
        let mut p = cp();
        p.aspect = Some(Aspect::Text("1:1".into()));
        assert_eq!(crop_plan(400, 200, &p).unwrap().0, Rect { x: 100, y: 0, width: 200, height: 200 });
        p.gravity = Some(Gravity::Right);
        assert_eq!(crop_plan(400, 200, &p).unwrap().0.x, 200);
        p.smart = Some(Rect { x: 0, y: 0, width: 20, height: 20 });
        assert_eq!(crop_plan(400, 200, &p).unwrap().0.x, 0);
        p.smart = Some(Rect { x: 250, y: 50, width: 40, height: 40 });
        assert_eq!(crop_plan(400, 200, &p).unwrap().0.x, 170);
    }

    #[test]
    fn crop_to_size_and_rect_validation() {
        let mut p = cp();
        p.width = Some(160);
        p.height = Some(90);
        let (r, s) = crop_plan(1000, 1000, &p).unwrap();
        assert_eq!((r.width, s), (1000, Some((160, 90))));
        assert!((562..=563).contains(&r.height));
        let mut p = cp();
        p.x = Some(10);
        p.y = Some(10);
        p.width = Some(100);
        p.height = Some(100);
        assert!(crop_plan(100, 100, &p).is_err());
        assert!(crop_plan(110, 110, &p).is_ok());
    }

    #[test]
    fn resize_targets() {
        let mut p = ResizeParams { long_edge: Some(500), ..Default::default() };
        assert_eq!(target_scale(1000, 400, &p).unwrap(), 0.5);
        p.long_edge = None;
        p.width = Some(300);
        p.height = Some(300);
        assert_eq!(target_scale(1200, 600, &p).unwrap(), 0.25);
        p.width = Some(3000);
        p.height = None;
        assert_eq!(target_scale(1200, 600, &p).unwrap(), 1.0);
        p.scale = Some(0.5);
        assert!(target_scale(1200, 600, &p).is_err());
    }
}
