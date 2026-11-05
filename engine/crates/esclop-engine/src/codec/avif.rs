// SPDX-License-Identifier: GPL-3.0-or-later
//! AVIF encoding behind a trait, so the encoder is a build choice.
//!
//! - `avif-aom` (default): libaom through libavif, `tune=iq`, 4:2:0, grids for large images.
//!   Built against the libaom `Scripts/build-libaom.sh` produces (3.15, pinned and checksummed);
//!   with the older libaom the libaom-sys crate bundles, `tune=iq` is unavailable and libaom's
//!   default tuning is used; `hello` says which.
//! - `avif-rav1e`: ravif/rav1e, pure Rust, 4:4:4 only; larger files at the same quality.
//!
//! The protocol's AVIF quality is heif-enc's (libheif's) 0..=100 scale, the one Clop passes to
//! `heif-enc -q`. Each codec maps it to its own.

use crate::error::Result;
use image::DynamicImage;

/// Piecewise-linear lookup in a table of (x, y) rows sorted by x.
#[cfg(any(feature = "avif-aom", feature = "avif-rav1e"))]
pub(crate) fn interpolate(table: &[(u8, u8)], x: u8) -> u8 {
    let i = table.iter().position(|r| r.0 >= x).unwrap_or(table.len() - 1);
    if i == 0 || table[i].0 == x {
        return table[i].1;
    }
    let ((a, ya), (b, yb)) = (table[i - 1], table[i]);
    (ya as f64 + (x - a) as f64 / (b - a) as f64 * (yb as f64 - ya as f64)).round() as u8
}

#[derive(Debug, Clone, Copy)]
pub struct AvifOptions {
    /// 0..=100 on heif-enc's scale.
    pub quality: u8,
    pub alpha_quality: u8,
    /// 1..=10.
    pub speed: u8,
}

pub trait AvifCodec: Send + Sync {
    /// For `hello`, e.g. "libaom 3.15.3 (tune=iq)".
    fn describe(&self) -> String;
    /// `icc` and `exif` (TIFF payload) are embedded when the codec can.
    fn encode(&self, img: &DynamicImage, o: &AvifOptions, icc: Option<&[u8]>, exif: Option<&[u8]>) -> Result<Vec<u8>>;
}

/// The AVIF codec of this build, if any.
pub fn codec() -> Option<&'static dyn AvifCodec> {
    #[cfg(feature = "avif-aom")]
    {
        static C: super::avif_aom::Libaom = super::avif_aom::Libaom;
        return Some(&C);
    }
    #[cfg(all(feature = "avif-rav1e", not(feature = "avif-aom")))]
    {
        static C: super::avif_rav1e::Ravif = super::avif_rav1e::Ravif;
        return Some(&C);
    }
    #[allow(unreachable_code)]
    None
}
