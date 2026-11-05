// SPDX-License-Identifier: GPL-3.0-or-later
//! The compression factor and how it maps onto each encoder.
//!
//! The protocol exposes one `compression` factor, 0..=100, where higher means smaller files:
//! 30 is L'Esclop's "normal" (visually lossless for the usual screenshot or photo) and 64 is
//! "aggressive". These are the anchors Clop 3.5 uses, and the per-encoder curves below reproduce
//! its observable behaviour so that the same factor yields comparable files:
//!
//! | factor | JPEG max quality | PNG quality (min-max) | PNG speed | GIF                          | WebP q |
//! |-------:|-----------------:|-----------------------|----------:|------------------------------|-------:|
//! | 30     | 85               | 0-100                 | 4         | -O2 --lossy=30               | 60     |
//! | 64     | 58               | 0-64                  | 2         | -O3 --lossy=80 --colors=202  | 43     |
//! | 100    | 18               | 0-25, 64 colours      | 1         | -O3 --lossy=2000 --colors=64 | 15     |
//!
//! Explicit encoder params (`quality`, `lossy`, `colors`, `speed`) always win over the factor.
//! The table is repeated, with AVIF, in `engine/PROTOCOL.md`.

/// L'Esclop "normal".
pub const NORMAL: u8 = 30;
/// L'Esclop "aggressive".
pub const AGGRESSIVE: u8 = 64;

fn clamp(v: f64, lo: i64, hi: i64) -> i64 {
    (v.round() as i64).clamp(lo, hi)
}

/// Whether a factor counts as aggressive (the threshold Clop's UI uses).
pub fn is_aggressive(f: u8) -> bool {
    f >= 50
}

/// JPEG re-encode ceiling (jpegoptim `--max` semantics): files whose estimated quality is above
/// this are re-encoded at it, the rest are only recompressed losslessly.
pub fn jpeg_max_quality(f: u8) -> u8 {
    let f = f as f64;
    if f <= 70.0 {
        clamp(85.0 - (f - 30.0) * (55.0 / 70.0), 25, 95) as u8
    } else {
        clamp(54.0 - (f - 70.0) * (36.0 / 30.0), 18, 95) as u8
    }
}

/// imagequant `(minimum, target)` quality.
pub fn png_quality(f: u8) -> (u8, u8) {
    let f = f as f64;
    (0, clamp(100.0 - (f - 30.0) * (75.0 / 70.0), 25, 100) as u8)
}

/// Palette size cap; `None` means the full 256 colours.
pub fn png_colors(f: u8) -> Option<u32> {
    if f < 80 {
        return None;
    }
    Some((224 - (f as i64 - 80) * 8).clamp(64, 256) as u32)
}

/// imagequant speed, 1 (slowest, best) to 10. More effort the harder we compress.
pub fn png_speed(f: u8) -> u8 {
    match f {
        0..40 => 4,
        40..60 => 3,
        60..85 => 2,
        _ => 1,
    }
}

/// oxipng effort after quantisation. Clop's pngquant output gets no lossless pass at all; level 0
/// already beats it on size at a lower total time, and higher factors buy smaller files with
/// more effort (the same ramp as `png_speed`).
pub fn png_level(f: u8) -> u8 {
    match f {
        0..50 => 0,
        50..85 => 1,
        _ => 2,
    }
}

/// gifsicle optimisation level, lossiness and palette cap.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GifSettings {
    pub level: u8,
    pub lossy: u32,
    pub colors: Option<u32>,
}

pub fn gif(f: u8) -> GifSettings {
    let level = if f >= 50 {
        3
    } else if f >= 20 {
        2
    } else {
        1
    };
    let ff = f as f64;
    let lossy = if f <= 70 {
        clamp(30.0 + (ff - 30.0) * (50.0 / 34.0), 0, 200) as u32
    } else {
        (89.0 * (2000.0f64 / 89.0).powf((ff - 70.0) / 30.0)).round() as u32
    };
    let colors = (f >= 50).then(|| clamp(256.0 - (ff - 50.0) * (192.0 / 50.0), 32, 256) as u32);
    GifSettings { level, lossy, colors }
}

/// gifski quality (1..=100) for the built-in GIF encoder, from a gifsicle-style lossiness.
/// gifski has no lossy LZW here (that code is gifsicle's), so lossiness becomes palette quality.
pub fn gifski_quality_from_lossy(lossy: u32) -> u8 {
    (100.0 - (lossy.min(200) as f64) / 4.0).round().clamp(30.0, 100.0) as u8
}

/// WebP quality (cwebp `-q`).
pub fn webp_quality(f: u8) -> u8 {
    let f = f as f64;
    if f <= 70.0 { clamp(75.0 - f * 0.5, 20, 90) as u8 } else { clamp(40.0 - (f - 70.0) * (25.0 / 30.0), 15, 90) as u8 }
}

/// AVIF quality on heif-enc's 0..=100 scale: Clop gives `heif-enc --avif -q` its WebP conversion
/// quality, so the value carries over unchanged. Each AVIF codec translates it to its own scale
/// (`codec/avif_aom.rs`, `codec/avif_rav1e.rs`).
pub fn avif_quality(f: u8) -> u8 {
    webp_quality(f)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn anchors_match_the_reference_presets() {
        assert_eq!(jpeg_max_quality(NORMAL), 85);
        assert_eq!(jpeg_max_quality(AGGRESSIVE), 58);
        assert_eq!(jpeg_max_quality(100), 18);
        assert_eq!(png_quality(NORMAL), (0, 100));
        assert_eq!(png_quality(AGGRESSIVE), (0, 64));
        assert_eq!(png_quality(100), (0, 25));
        assert_eq!(png_speed(NORMAL), 4);
        assert_eq!(png_speed(AGGRESSIVE), 2);
        assert_eq!(png_colors(NORMAL), None);
        assert_eq!((png_level(NORMAL), png_level(AGGRESSIVE), png_level(100)), (0, 1, 2));
        assert_eq!(png_colors(100), Some(64));
        assert_eq!(gif(NORMAL), GifSettings { level: 2, lossy: 30, colors: None });
        assert_eq!(gif(AGGRESSIVE), GifSettings { level: 3, lossy: 80, colors: Some(202) });
        assert_eq!(gif(100).lossy, 2000);
        assert_eq!(webp_quality(NORMAL), 60);
        assert_eq!(webp_quality(AGGRESSIVE), 43);
        assert!(!is_aggressive(NORMAL) && is_aggressive(AGGRESSIVE));
    }

    /// The table in engine/PROTOCOL.md, row by row.
    #[test]
    fn protocol_table() {
        let row = |f: u8| {
            let g = gif(f);
            (
                jpeg_max_quality(f),
                png_quality(f).1,
                png_speed(f),
                png_colors(f).unwrap_or(256),
                g.level,
                g.lossy,
                g.colors,
                webp_quality(f),
                avif_quality(f),
            )
        };
        assert_eq!(row(0), (95, 100, 4, 256, 1, 0, None, 75, 75));
        assert_eq!(row(30), (85, 100, 4, 256, 2, 30, None, 60, 60));
        assert_eq!(row(50), (69, 79, 3, 256, 3, 59, Some(256), 50, 50));
        assert_eq!(row(64), (58, 64, 2, 256, 3, 80, Some(202), 43, 43));
        assert_eq!(row(80), (42, 46, 2, 224, 3, 251, Some(141), 32, 32));
        assert_eq!(row(100), (18, 25, 1, 64, 3, 2000, Some(64), 15, 15));
    }

    #[test]
    fn curves_are_monotonic() {
        for f in 1..=100u8 {
            assert!(jpeg_max_quality(f) <= jpeg_max_quality(f - 1));
            assert!(png_quality(f).1 <= png_quality(f - 1).1);
            assert!(webp_quality(f) <= webp_quality(f - 1));
            assert!(avif_quality(f) <= avif_quality(f - 1));
            assert!(gif(f).lossy >= gif(f - 1).lossy);
        }
    }
}
