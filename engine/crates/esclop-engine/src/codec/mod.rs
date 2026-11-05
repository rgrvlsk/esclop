// SPDX-License-Identifier: GPL-3.0-or-later
//! Encoders. Each takes pixels (or bytes) and returns bytes; files are written by `fsio`.

pub mod avif;
#[cfg(feature = "avif-aom")]
pub mod avif_aom;
#[cfg(feature = "avif-rav1e")]
pub mod avif_rav1e;
pub mod gif;
pub mod jpeg;
pub mod png;
pub mod webp;
