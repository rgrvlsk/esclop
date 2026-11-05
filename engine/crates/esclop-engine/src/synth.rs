// SPDX-License-Identifier: GPL-3.0-or-later
//! Deterministic synthetic images for tests and the benchmark corpus. No personal media is ever
//! needed: these cover the cases that matter for an optimiser (smooth photo-like texture with
//! grain, flat-colour UI with text-like detail, transparency, animation).

use image::{Rgb, RgbImage, Rgba, RgbaImage};

/// xorshift64*: small, fast, reproducible everywhere.
pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Self {
        Self(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1)
    }
    pub fn next_u64(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
    pub fn unit(&mut self) -> f32 {
        (self.next_u64() >> 40) as f32 / (1u64 << 24) as f32
    }
}

fn hash2(x: i32, y: i32, seed: u32) -> f32 {
    let mut h =
        (x as u32).wrapping_mul(0x8DA6_B343) ^ (y as u32).wrapping_mul(0xD816_3841) ^ seed.wrapping_mul(0xCB1A_B31F);
    h ^= h >> 13;
    h = h.wrapping_mul(0x5bd1_e995);
    h ^= h >> 15;
    (h & 0xFFFF) as f32 / 65535.0
}

/// Smoothly interpolated value noise in 0..1.
fn value_noise(x: f32, y: f32, seed: u32) -> f32 {
    let (xi, yi) = (x.floor() as i32, y.floor() as i32);
    let (fx, fy) = (x - xi as f32, y - yi as f32);
    let s = |t: f32| t * t * (3.0 - 2.0 * t);
    let (u, v) = (s(fx), s(fy));
    let a = hash2(xi, yi, seed);
    let b = hash2(xi + 1, yi, seed);
    let c = hash2(xi, yi + 1, seed);
    let d = hash2(xi + 1, yi + 1, seed);
    a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v
}

fn fractal(x: f32, y: f32, seed: u32, octaves: u32) -> f32 {
    let (mut sum, mut amp, mut freq, mut norm) = (0.0, 1.0, 1.0, 0.0);
    for o in 0..octaves {
        sum += amp * value_noise(x * freq, y * freq, seed + o);
        norm += amp;
        amp *= 0.5;
        freq *= 2.0;
    }
    sum / norm
}

/// A photo-like image: lit landscape-ish colour fields, fractal texture, a few hard-edged
/// objects, sensor grain. JPEG and AVIF behave on it the way they do on real photos.
pub fn photo(w: u32, h: u32, seed: u64) -> RgbImage {
    let mut rng = Rng::new(seed);
    let s = seed as u32;
    let discs: Vec<(f32, f32, f32, [f32; 3])> = (0..6)
        .map(|_| {
            (
                rng.unit() * w as f32,
                rng.unit() * h as f32,
                (0.05 + rng.unit() * 0.12) * w.min(h) as f32,
                [rng.unit(), rng.unit(), rng.unit()],
            )
        })
        .collect();
    let scale = 6.0 / w.max(h) as f32;
    RgbImage::from_fn(w, h, |x, y| {
        let (fx, fy) = (x as f32 * scale, y as f32 * scale);
        let sky = y as f32 / h as f32;
        let t = fractal(fx, fy, s, 6);
        let t2 = fractal(fx * 3.0 + 7.0, fy * 3.0, s + 17, 4);
        let mut c =
            [0.25 + 0.5 * t + 0.15 * (1.0 - sky), 0.30 + 0.45 * t2 * (0.6 + 0.4 * sky), 0.45 + 0.4 * (1.0 - sky) * t];
        for (dx, dy, r, col) in &discs {
            let d = ((x as f32 - dx).powi(2) + (y as f32 - dy).powi(2)).sqrt();
            let edge = ((r - d) / 1.5).clamp(0.0, 1.0);
            let shade = 0.75 + 0.25 * ((dx - x as f32 + dy - y as f32) / r).clamp(-1.0, 1.0);
            for i in 0..3 {
                c[i] = c[i] * (1.0 - edge) + col[i] * shade * edge;
            }
        }
        let grain = (hash2(x as i32, y as i32, s ^ 0xABCD) - 0.5) * 0.06;
        Rgb(c.map(|v| ((v + grain).clamp(0.0, 1.0) * 255.0).round() as u8))
    })
}

/// A UI-screenshot-like image: flat panels, a gradient bar, rows of anti-aliased "text".
pub fn screenshot(w: u32, h: u32, seed: u64) -> RgbImage {
    let mut rng = Rng::new(seed);
    let mut img = RgbImage::from_pixel(w, h, Rgb([246, 246, 248]));
    let sidebar = w / 5;
    for y in 0..h {
        for x in 0..sidebar {
            img.put_pixel(x, y, Rgb([232, 233, 238]));
        }
    }
    for x in 0..w {
        let t = x as f32 / w as f32;
        for y in 0..(h / 16).max(4) {
            img.put_pixel(x, y, Rgb([(40.0 + 60.0 * t) as u8, (90.0 + 40.0 * t) as u8, (200.0 - 50.0 * t) as u8]));
        }
    }
    let palette = [[30u8, 30, 34], [90, 92, 100], [10, 100, 220], [200, 60, 50]];
    let line_h = 14.max(h / 40);
    let mut y = h / 16 + line_h;
    while y + line_h < h {
        let mut x = sidebar + 16;
        let col = palette[(rng.next_u64() % 4) as usize];
        let line_end = sidebar + 16 + ((w - sidebar - 32) as f32 * (0.4 + 0.6 * rng.unit())) as u32;
        while x + 8 < line_end.min(w - 8) {
            let gw = 4 + (rng.next_u64() % 6) as u32;
            let gh = line_h / 2 + (rng.next_u64() % (line_h as u64 / 3 + 1)) as u32;
            for gy in 0..gh {
                for gx in 0..gw {
                    let edge = (gx == 0 || gx + 1 == gw || gy == 0) as u8;
                    let (px, py) = (x + gx, y + line_h - gh + gy);
                    if px < w && py < h {
                        let bg = img.get_pixel(px, py).0;
                        let a = if edge == 1 { 0.45 } else { 1.0 };
                        let mix = |i: usize| (bg[i] as f32 * (1.0 - a) + col[i] as f32 * a) as u8;
                        img.put_pixel(px, py, Rgb([mix(0), mix(1), mix(2)]));
                    }
                }
            }
            x += gw + 1 + if rng.next_u64().is_multiple_of(6) { 6 } else { 0 };
        }
        y += line_h + line_h / 2;
        if rng.next_u64().is_multiple_of(7) {
            // a panel
            let ph = (line_h * 3).min(h - y);
            for py in y..y + ph {
                for px in sidebar + 12..w - 12 {
                    img.put_pixel(px, py, Rgb([255, 255, 255]));
                }
            }
            y += ph + line_h / 2;
        }
    }
    img
}

/// An illustration on a transparent background with soft shadows (exercises alpha).
pub fn alpha_art(w: u32, h: u32, seed: u64) -> RgbaImage {
    let mut rng = Rng::new(seed);
    let shapes: Vec<(f32, f32, f32, [u8; 3])> = (0..5)
        .map(|_| {
            (
                rng.unit() * w as f32,
                rng.unit() * h as f32,
                (0.1 + rng.unit() * 0.2) * w.min(h) as f32,
                [(rng.next_u64() % 256) as u8, (rng.next_u64() % 256) as u8, (rng.next_u64() % 256) as u8],
            )
        })
        .collect();
    RgbaImage::from_fn(w, h, |x, y| {
        let mut px = [0f32; 4];
        for (cx, cy, r, col) in &shapes {
            let d = ((x as f32 - cx).powi(2) + (y as f32 - cy).powi(2)).sqrt();
            let shadow = (1.0 - ((d - r * 0.9) / (r * 0.5)).clamp(0.0, 1.0)) * 0.35;
            let body = ((r - d) / 1.2).clamp(0.0, 1.0);
            let a = body + shadow * (1.0 - body);
            if a <= 0.0 {
                continue;
            }
            let c = [
                col[0] as f32 * body / a.max(1e-3),
                col[1] as f32 * body / a.max(1e-3),
                col[2] as f32 * body / a.max(1e-3),
            ];
            let out_a = a + px[3] * (1.0 - a);
            for i in 0..3 {
                px[i] = (c[i] * a + px[i] * px[3] * (1.0 - a)) / out_a.max(1e-3);
            }
            px[3] = out_a;
        }
        Rgba([px[0] as u8, px[1] as u8, px[2] as u8, (px[3] * 255.0).round() as u8])
    })
}

/// Frames of a ball crossing a gradient, for GIF tests.
pub fn animation(w: u32, h: u32, frames: u32) -> Vec<RgbaImage> {
    (0..frames)
        .map(|i| {
            let cx = w as f32 * (0.15 + 0.7 * i as f32 / frames.max(1) as f32);
            let cy = h as f32 * 0.5;
            let r = h as f32 * 0.2;
            RgbaImage::from_fn(w, h, |x, y| {
                let d = ((x as f32 - cx).powi(2) + (y as f32 - cy).powi(2)).sqrt();
                if d < r {
                    Rgba([230, (120.0 + 100.0 * (y as f32 / h as f32)) as u8, 40, 255])
                } else {
                    Rgba([(x * 255 / w) as u8, 60, (y * 255 / h) as u8, 255])
                }
            })
        })
        .collect()
}

/// Encodes frames as a plain GIF (gif crate, full frames, NeuQuant palettes, no optimisation):
/// the kind of GIF people actually receive, with room to optimise.
pub fn encode_gif(frames: &[RgbaImage], delay_cs: u16) -> Vec<u8> {
    let (w, h) = frames[0].dimensions();
    let mut out = Vec::new();
    {
        let mut enc = gif::Encoder::new(&mut out, w as u16, h as u16, &[]).unwrap();
        enc.set_repeat(gif::Repeat::Infinite).unwrap();
        for f in frames {
            let mut px = f.as_raw().clone();
            let mut frame = gif::Frame::from_rgba_speed(w as u16, h as u16, &mut px, 10);
            frame.delay = delay_cs;
            enc.write_frame(&frame).unwrap();
        }
    }
    out
}

/// Encodes frames as full frames over one global 6x6x6 colour-cube palette, the way naive screen
/// recorders export: lots of redundancy for an optimiser to remove.
pub fn encode_gif_global(frames: &[RgbaImage], delay_cs: u16) -> Vec<u8> {
    let (w, h) = frames[0].dimensions();
    let palette: Vec<u8> =
        (0..216u32).flat_map(|i| [(i / 36 * 51) as u8, (i / 6 % 6 * 51) as u8, (i % 6 * 51) as u8]).collect();
    let q = |v: u8| ((v as u32 + 25) / 51).min(5);
    let mut out = Vec::new();
    {
        let mut enc = gif::Encoder::new(&mut out, w as u16, h as u16, &palette).unwrap();
        enc.set_repeat(gif::Repeat::Infinite).unwrap();
        for f in frames {
            let idx: Vec<u8> = f.pixels().map(|p| (q(p.0[0]) * 36 + q(p.0[1]) * 6 + q(p.0[2])) as u8).collect();
            let mut frame = gif::Frame::from_indexed_pixels(w as u16, h as u16, idx, None);
            frame.delay = delay_cs;
            enc.write_frame(&frame).unwrap();
        }
    }
    out
}

pub fn encode_png(img: &image::DynamicImage) -> Vec<u8> {
    let mut out = Vec::new();
    img.write_to(&mut std::io::Cursor::new(&mut out), image::ImageFormat::Png).unwrap();
    out
}

/// A baseline libjpeg-style JPEG at `quality` (what cameras and most apps write).
pub fn encode_jpeg(img: &RgbImage, quality: u8) -> Vec<u8> {
    let mut out = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, quality).encode_image(img).unwrap();
    out
}
