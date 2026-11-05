// SPDX-License-Identifier: GPL-3.0-or-later
//! Format detection from magic bytes (never from the file name).

use crate::protocol::Format;

pub fn sniff(b: &[u8]) -> Option<Format> {
    if b.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Some(Format::Png);
    }
    if b.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return Some(Format::Jpeg);
    }
    if b.starts_with(b"GIF87a") || b.starts_with(b"GIF89a") {
        return Some(Format::Gif);
    }
    if b.len() >= 12 && &b[0..4] == b"RIFF" && &b[8..12] == b"WEBP" {
        return Some(Format::Webp);
    }
    if b.starts_with(b"II*\0") || b.starts_with(b"MM\0*") {
        return Some(Format::Tiff);
    }
    if b.starts_with(b"BM") && b.len() > 26 {
        return Some(Format::Bmp);
    }
    if b.starts_with(&[0xFF, 0x0A]) || b.starts_with(b"\0\0\0\x0cJXL \r\n\x87\n") {
        return Some(Format::Jxl);
    }
    if b.len() >= 16 && &b[4..8] == b"ftyp" {
        let size = (u32::from_be_bytes(b[0..4].try_into().unwrap()) as usize).clamp(16, b.len().min(256));
        let brands: Vec<&[u8]> =
            std::iter::once(&b[8..12]).chain(b[16..size].as_chunks::<4>().0.iter().map(|c| &c[..])).collect();
        if brands.iter().any(|x| *x == b"avif" || *x == b"avis") {
            return Some(Format::Avif);
        }
        if brands
            .iter()
            .any(|x| matches!(*x, b"heic" | b"heix" | b"hevc" | b"hevx" | b"heim" | b"heis" | b"mif1" | b"msf1"))
        {
            return Some(Format::Heic);
        }
    }
    None
}

/// Formats `image` decodes for us.
pub const DECODABLE: &[Format] = &[Format::Png, Format::Jpeg, Format::Gif, Format::Webp, Format::Tiff, Format::Bmp];
pub const ENCODABLE: &[Format] = &[Format::Png, Format::Jpeg, Format::Webp, Format::Avif, Format::Gif];

pub fn decodable(f: Format) -> bool {
    DECODABLE.contains(&f)
}
