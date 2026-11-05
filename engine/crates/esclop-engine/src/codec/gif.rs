// SPDX-License-Identifier: GPL-3.0-or-later
//! GIF: gifsicle as a separate process when it is installed (it is GPL-2.0-only and is never
//! linked), gifski otherwise and for building GIFs from frames.

use crate::ctx::Ctx;
use crate::error::{EngineError, ErrorCode, Result};
use crate::pixels::Animation;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

/// Finds gifsicle like the Swift tool locator does: `$ESCLOP_BIN/gifsicle`, then next to this
/// executable (`Contents/Resources/bin`), then `PATH`. `ESCLOP_NO_GIFSICLE=1` hides it.
pub fn find_gifsicle() -> Option<PathBuf> {
    if std::env::var_os("ESCLOP_NO_GIFSICLE").is_some_and(|v| v != "0") {
        return None;
    }
    let exe_dir = std::env::current_exe().ok().and_then(|p| p.parent().map(Path::to_path_buf));
    let candidates = std::env::var_os("ESCLOP_BIN")
        .map(PathBuf::from)
        .into_iter()
        .chain(exe_dir)
        .chain(std::env::var_os("PATH").map(|p| std::env::split_paths(&p).collect::<Vec<_>>()).unwrap_or_default());
    candidates.map(|d| d.join("gifsicle")).find(|p| is_executable(p))
}

fn is_executable(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// Runs gifsicle on `input` with `args` and returns what it wrote. Polls for cancellation.
pub fn run_gifsicle(bin: &Path, input: &Path, args: &[String], ctx: &Ctx) -> Result<Vec<u8>> {
    let out = tempfile::Builder::new()
        .prefix("esclop-gif")
        .suffix(".gif")
        .tempfile()
        .map_err(|e| EngineError::io(e, Path::new("temp")))?;
    let mut child = Command::new(bin)
        .args(args)
        .arg("--output")
        .arg(out.path())
        .arg(input)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| EngineError::io(e, bin))?;
    let status = loop {
        if let Some(s) = child.try_wait().map_err(|e| EngineError::io(e, bin))? {
            break s;
        }
        if ctx.is_cancelled() {
            let _ = child.kill();
            let _ = child.wait();
            return Err(EngineError::cancelled());
        }
        std::thread::sleep(Duration::from_millis(15));
    };
    if !status.success() {
        let mut msg = String::new();
        if let Some(mut e) = child.stderr.take() {
            use std::io::Read;
            let _ = e.read_to_string(&mut msg);
        }
        let first = msg.lines().next().unwrap_or("").trim().to_string();
        let code = if first.contains("not a GIF") || first.contains("bad image") {
            ErrorCode::Decode
        } else {
            ErrorCode::Encode
        };
        return Err(EngineError::new(code, format!("gifsicle failed ({status}): {first}")));
    }
    std::fs::read(out.path()).map_err(|e| EngineError::io(e, out.path()))
}

#[derive(Debug, Clone, Copy)]
pub struct GifskiOptions {
    pub quality: u8,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub fast: bool,
}

struct Reporter {
    ctx: Ctx,
    done: usize,
    total: usize,
}

impl gifski::progress::ProgressReporter for Reporter {
    fn increase(&mut self) -> bool {
        self.done += 1;
        self.ctx.progress(self.done as f32 / self.total.max(1) as f32, "encode");
        !self.ctx.is_cancelled()
    }
    fn done(&mut self, _msg: &str) {}
}

/// Frames for gifski: RGBA pixels and how long each shows, in milliseconds.
pub type FrameIter = Box<dyn Iterator<Item = Result<(image::RgbaImage, u32)>> + Send>;

/// Encodes an animation with gifski (imagequant per frame, inter-frame transparency).
pub fn encode_gifski(a: Animation, o: &GifskiOptions, ctx: &Ctx) -> Result<Vec<u8>> {
    let (total, repeat) = (a.frames.len(), a.repeat);
    encode_stream(Box::new(a.frames.into_iter().map(|f| Ok((f.image, f.delay_ms)))), total, repeat, o, ctx)
}

/// Encodes frames as they arrive, so a long sequence never sits in memory at once.
pub fn encode_stream(frames: FrameIter, total: usize, repeat: u16, o: &GifskiOptions, ctx: &Ctx) -> Result<Vec<u8>> {
    let settings = gifski::Settings {
        width: o.width,
        height: o.height,
        quality: o.quality.clamp(1, 100),
        fast: o.fast,
        repeat: if repeat == 0 { gifski::Repeat::Infinite } else { gifski::Repeat::Finite(repeat) },
    };
    let (collector, writer) = gifski::new(settings).map_err(|e| EngineError::encode(format!("gifski: {e}")))?;
    let feed_ctx = ctx.clone();
    let feeder = std::thread::spawn(move || -> Result<()> {
        let mut pts = 0.0f64;
        for (i, f) in frames.enumerate() {
            feed_ctx.check()?;
            let (img, delay_ms) = f?;
            let (w, h) = img.dimensions();
            let px: Vec<rgb::RGBA8> = img.pixels().map(|p| rgb::RGBA8::new(p.0[0], p.0[1], p.0[2], p.0[3])).collect();
            drop(img);
            collector
                .add_frame_rgba(i, imgref::ImgVec::new(px, w as usize, h as usize), pts)
                .map_err(|e| EngineError::encode(format!("gifski: {e}")))?;
            // browsers show delays under 20 ms as 100 ms
            let d = if delay_ms < 20 { 100 } else { delay_ms };
            pts += d as f64 / 1000.0;
        }
        Ok(())
    });
    let mut out = Vec::new();
    let mut reporter = Reporter { ctx: ctx.clone(), done: 0, total };
    let written = writer.write(&mut out, &mut reporter);
    let fed = feeder.join().map_err(|_| EngineError::internal("gifski frame feeder panicked"))?;
    if ctx.is_cancelled() {
        return Err(EngineError::cancelled());
    }
    fed?;
    match written {
        Ok(()) => Ok(out),
        Err(gifski::Error::Aborted) => Err(EngineError::cancelled()),
        Err(e) => Err(EngineError::encode(format!("gifski: {e}"))),
    }
}

/// Settings for [`encode_diff`].
#[derive(Debug, Clone, Copy)]
pub struct DiffOptions {
    /// Palette cap per frame, 2..=256.
    pub colors: u32,
    /// imagequant target quality for frames with more colours than the cap.
    pub quality: u8,
    pub dither: f32,
    /// A pixel within this distance (per channel) of what is already on screen is left alone.
    /// 0 is lossless.
    pub tolerance: u8,
}

/// The built-in GIF optimiser. It tracks the canvas a viewer sees; each frame stores only the
/// rectangle that differs from it (beyond `tolerance`), unchanged pixels inside the rectangle
/// become transparent (long LZW runs), identical frames merge their delays, and frames that fit
/// in a palette keep their exact colours. Frames with more colours than `colors` are quantised by
/// imagequant. Errors never accumulate: every comparison is against the displayed result.
pub fn encode_diff(a: &Animation, o: &DiffOptions, ctx: &Ctx) -> Result<Vec<u8>> {
    use std::borrow::Cow;
    let (w, h) = (a.width, a.height);
    if w > u16::MAX as u32 || h > u16::MAX as u32 {
        return Err(EngineError::unsupported("GIF is limited to 65535 pixels per side"));
    }
    let enc_err = |e: gif::EncodingError| EngineError::encode(format!("gif: {e}"));
    let mut out = Vec::new();
    {
        let mut enc = gif::Encoder::new(&mut out, w as u16, h as u16, &[]).map_err(enc_err)?;
        if a.frames.len() > 1 {
            enc.set_repeat(if a.repeat == 0 { gif::Repeat::Infinite } else { gif::Repeat::Finite(a.repeat) })
                .map_err(enc_err)?;
        }
        let mut pending: Option<gif::Frame<'static>> = None;
        let mut shown: Option<image::RgbaImage> = None;
        for (i, f) in a.frames.iter().enumerate() {
            ctx.check()?;
            ctx.progress(i as f32 / a.frames.len() as f32, "encode");
            let cur = &f.image;
            let delay = (f.delay_ms.div_ceil(10)).min(u16::MAX as u32) as u16;
            // pixels that turn transparent cannot be drawn over the previous frame: restart
            // from a cleared canvas
            let clears =
                shown.as_ref().is_some_and(|p| p.pixels().zip(cur.pixels()).any(|(a, b)| b.0[3] == 0 && a.0[3] != 0));
            if clears {
                if let Some(p) = pending.as_mut() {
                    p.dispose = gif::DisposalMethod::Background;
                }
                shown = None;
            }
            let rect = match &shown {
                Some(s) => changed_rect(s, cur, o.tolerance),
                None => Some((0, 0, w, h)),
            };
            let Some((x0, y0, rw, rh)) = rect else {
                // nothing visible changes: show the previous frame longer
                if let Some(p) = pending.as_mut() {
                    p.delay = p.delay.saturating_add(delay)
                }
                continue;
            };
            let canvas = shown.get_or_insert_with(|| image::RgbaImage::new(w, h));
            let frame = index_rect(cur, canvas, x0, y0, rw, rh, o)?;
            let gf = gif::Frame {
                left: x0 as u16,
                top: y0 as u16,
                width: rw as u16,
                height: rh as u16,
                delay,
                dispose: gif::DisposalMethod::Keep,
                transparent: frame.transparent,
                palette: Some(frame.palette),
                buffer: Cow::Owned(frame.indices),
                ..Default::default()
            };
            if let Some(p) = pending.replace(gf) {
                enc.write_frame(&p).map_err(enc_err)?;
            }
        }
        if let Some(p) = pending {
            enc.write_frame(&p).map_err(enc_err)?;
        }
    }
    Ok(out)
}

fn close(a: &[u8; 4], b: &[u8; 4], tol: u8) -> bool {
    a[3] == b[3] && (0..3).all(|i| a[i].abs_diff(b[i]) <= tol)
}

/// Bounding box of the pixels that differ beyond `tol`, or None when nothing does.
fn changed_rect(shown: &image::RgbaImage, cur: &image::RgbaImage, tol: u8) -> Option<(u32, u32, u32, u32)> {
    let (w, h) = cur.dimensions();
    let (mut x0, mut y0, mut x1, mut y1) = (w, h, 0, 0);
    for y in 0..h {
        for x in 0..w {
            if !close(&shown.get_pixel(x, y).0, &cur.get_pixel(x, y).0, tol) {
                x0 = x0.min(x);
                y0 = y0.min(y);
                x1 = x1.max(x);
                y1 = y1.max(y);
            }
        }
    }
    (x0 <= x1).then(|| (x0, y0, x1 - x0 + 1, y1 - y0 + 1))
}

struct IndexedRect {
    palette: Vec<u8>,
    indices: Vec<u8>,
    transparent: Option<u8>,
}

/// Indexes a rectangle of `cur` and paints the result onto `canvas` (what the viewer will see).
/// Pixels close to the canvas, and fully transparent pixels, share the transparent index.
fn index_rect(
    cur: &image::RgbaImage,
    canvas: &mut image::RgbaImage,
    x0: u32,
    y0: u32,
    rw: u32,
    rh: u32,
    o: &DiffOptions,
) -> Result<IndexedRect> {
    use std::collections::HashMap;
    let n = (rw * rh) as usize;
    let mut skip = vec![false; n];
    let mut px = Vec::with_capacity(n);
    for y in 0..rh {
        for x in 0..rw {
            let p = cur.get_pixel(x0 + x, y0 + y).0;
            let on_screen = canvas.get_pixel(x0 + x, y0 + y).0;
            skip[(y * rw + x) as usize] = p[3] == 0 || (on_screen[3] != 0 && close(&on_screen, &p, o.tolerance));
            px.push(p);
        }
    }
    let any_transparent = skip.iter().any(|m| *m);
    let cap = o.colors.clamp(2, 256) as usize - any_transparent as usize;
    let mut colours: HashMap<[u8; 3], u8> = HashMap::new();
    let mut exact = true;
    for (p, m) in px.iter().zip(&skip) {
        if !*m && !colours.contains_key(&[p[0], p[1], p[2]]) {
            if colours.len() == cap {
                exact = false;
                break;
            }
            let idx = colours.len() as u8;
            colours.insert([p[0], p[1], p[2]], idx);
        }
    }
    let (palette, indices, transparent) = if exact {
        let t = colours.len() as u8;
        let mut palette = vec![0u8; (colours.len() + any_transparent as usize).max(1) * 3];
        for (c, i) in &colours {
            palette[*i as usize * 3..*i as usize * 3 + 3].copy_from_slice(c);
        }
        let indices: Vec<u8> =
            px.iter().zip(&skip).map(|(p, m)| if *m { t } else { colours[&[p[0], p[1], p[2]]] }).collect();
        (palette, indices, any_transparent.then_some(t))
    } else {
        // too many colours: quantise the drawn pixels, transparent for the rest
        let rgba: Vec<imagequant::RGBA> = px
            .iter()
            .zip(&skip)
            .map(
                |(p, m)| {
                    if *m { imagequant::RGBA::new(0, 0, 0, 0) } else { imagequant::RGBA::new(p[0], p[1], p[2], 255) }
                },
            )
            .collect();
        let liq = |e: imagequant::Error| EngineError::encode(format!("imagequant: {e}"));
        let mut attr = imagequant::new();
        attr.set_max_colors(o.colors.clamp(2, 256)).map_err(liq)?;
        attr.set_quality(0, o.quality.clamp(1, 100)).map_err(liq)?;
        attr.set_speed(3).map_err(liq)?;
        let mut img = attr.new_image(rgba, rw as usize, rh as usize, 0.0).map_err(liq)?;
        let mut res = attr.quantize(&mut img).map_err(liq)?;
        res.set_dithering_level(o.dither.clamp(0.0, 1.0)).map_err(liq)?;
        let (pal, mut indices) = res.remapped(&mut img).map_err(liq)?;
        let transparent = pal.iter().position(|c| c.a == 0).map(|i| i as u8);
        if let Some(t) = transparent {
            for (ix, m) in indices.iter_mut().zip(&skip) {
                if *m {
                    *ix = t;
                }
            }
        }
        (pal.iter().flat_map(|c| [c.r, c.g, c.b]).collect(), indices, transparent)
    };
    for y in 0..rh {
        for x in 0..rw {
            let ix = indices[(y * rw + x) as usize];
            if Some(ix) != transparent {
                let c = &palette[ix as usize * 3..ix as usize * 3 + 3];
                canvas.put_pixel(x0 + x, y0 + y, image::Rgba([c[0], c[1], c[2], 255]));
            }
        }
    }
    Ok(IndexedRect { palette, indices, transparent })
}
