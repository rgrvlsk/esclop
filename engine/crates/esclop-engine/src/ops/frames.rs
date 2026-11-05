// SPDX-License-Identifier: GPL-3.0-or-later
//! `gif.from_frames`: gifski over a folder of PNG frames, streamed one frame at a time.

use super::optimise::gif_size;
use super::{Encoded, dir_param, finish, parse_params};
use crate::codec::{self, gif::GifskiOptions};
use crate::ctx::Ctx;
use crate::error::{EngineError, Result};
use crate::fsio::OutputTarget;
use crate::protocol::{Format, GifFramesParams, OpResult, Request};
use std::path::PathBuf;

pub fn from_frames(req: &Request, ctx: &Ctx) -> Result<OpResult> {
    let (p, ignored) = parse_params::<GifFramesParams>(&req.params)?;
    let dir = dir_param(p.frames_dir.as_ref(), req)?;
    let target = OutputTarget::resolve(None, req.output.as_deref(), false)?;
    let fps = p.fps.unwrap_or(10.0);
    if !(fps > 0.0 && fps <= 100.0) {
        return Err(EngineError::invalid("`fps` must be in (0, 100]"));
    }
    let quality = p.quality.unwrap_or(90);
    if !(1..=100).contains(&quality) {
        return Err(EngineError::invalid("`quality` must be 1..=100"));
    }
    let mut files: Vec<PathBuf> = std::fs::read_dir(&dir)
        .map_err(|e| EngineError::io(e, &dir))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x.eq_ignore_ascii_case("png")))
        .collect();
    files.sort();
    if files.is_empty() {
        return Err(EngineError::invalid(format!("no PNG frames in {}", dir.display())));
    }
    let bytes_before: u64 = files.iter().filter_map(|f| std::fs::metadata(f).ok()).map(|m| m.len()).sum();
    let delay_ms = (1000.0 / fps).round() as u32;
    let n = files.len() as u32;
    let frames = files.into_iter().map(move |f| -> Result<(image::RgbaImage, u32)> {
        let img = image::ImageReader::open(&f)
            .map_err(|e| EngineError::io(e, &f))?
            .with_guessed_format()
            .map_err(|e| EngineError::io(e, &f))?
            .decode()?;
        Ok((img.into_rgba8(), delay_ms))
    });
    let o = GifskiOptions { quality, width: p.width, height: p.height, fast: p.fast.unwrap_or(false) };
    let out = codec::gif::encode_stream(Box::new(frames), n as usize, p.repeat.unwrap_or(0), &o, ctx)?;
    let (w, h) = gif_size(&out);
    let enc = Encoded {
        bytes: out,
        width: w,
        height: h,
        format: Some(Format::Gif),
        quality: Some(quality),
        lossy: true,
        frames: n,
        backend: Some("gifski".into()),
    };
    finish(&target, bytes_before, enc, true, ignored, ctx)
}
