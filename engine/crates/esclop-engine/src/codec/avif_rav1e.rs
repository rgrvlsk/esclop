// SPDX-License-Identifier: GPL-3.0-or-later
//! AVIF through ravif/rav1e (pure Rust). Selected with `--no-default-features --features avif-rav1e`.

use super::avif::{AvifCodec, AvifOptions, interpolate};
use crate::error::{EngineError, Result};
use image::DynamicImage;
use imgref::Img;

/// heif-enc quality -> the lowest ravif quality reaching the same SSIMULACRA2, median
/// over the calibration corpus (`bench/calibrate_avif.py`). Linear between rows.
const HEIF_TO_RAVIF: &[(u8, u8)] = &[(0, 10), (15, 23), (32, 46), (43, 66), (50, 77), (60, 84), (75, 88), (100, 100)];

pub struct Ravif;

impl AvifCodec for Ravif {
    fn describe(&self) -> String {
        "rav1e (ravif, 4:4:4)".into()
    }

    fn encode(&self, img: &DynamicImage, o: &AvifOptions, _icc: Option<&[u8]>, exif: Option<&[u8]>) -> Result<Vec<u8>> {
        use rgb::FromSlice;
        let (w, h) = (img.width() as usize, img.height() as usize);
        let mut enc = ravif::Encoder::new()
            .with_quality(interpolate(HEIF_TO_RAVIF, o.quality).clamp(1, 100) as f32)
            .with_alpha_quality(interpolate(HEIF_TO_RAVIF, o.alpha_quality).clamp(1, 100) as f32)
            .with_speed(o.speed.clamp(1, 10));
        if let Some(e) = exif {
            enc = enc.with_exif(e.to_vec());
        }
        // borrowed, never copied: a 24-megapixel image is 72-96 MB per copy
        let res = match img {
            DynamicImage::ImageRgba8(rgba) => enc.encode_rgba(Img::new(rgba.as_raw().as_rgba(), w, h)),
            DynamicImage::ImageRgb8(rgb) => enc.encode_rgb(Img::new(rgb.as_raw().as_rgb(), w, h)),
            other => {
                let rgb = other.to_rgb8();
                enc.encode_rgb(Img::new(rgb.as_raw().as_rgb(), w, h))
            }
        };
        res.map(|r| r.avif_file).map_err(|e| EngineError::encode(format!("ravif: {e}")))
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn mapping_is_monotonic() {
        for q in 1..=100u8 {
            assert!(
                super::super::avif::interpolate(super::HEIF_TO_RAVIF, q)
                    >= super::super::avif::interpolate(super::HEIF_TO_RAVIF, q - 1)
            );
        }
    }
}
