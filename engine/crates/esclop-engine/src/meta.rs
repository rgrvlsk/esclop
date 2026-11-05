// SPDX-License-Identifier: GPL-3.0-or-later
//! Container-level metadata, byte for byte: JPEG segments, PNG chunks, WebP RIFF chunks, GIF
//! blocks, and the EXIF orientation tag. Nothing here touches pixels, so `metadata.strip` is
//! lossless and the encoders can carry metadata across.

use crate::error::{EngineError, Result};
use crate::protocol::Keep;

// MARK: EXIF orientation

/// The orientation tag (0x0112) of a TIFF/EXIF block (without the `Exif\0\0` prefix).
pub fn exif_orientation(tiff: &[u8]) -> Option<u8> {
    let (off, _) = orientation_entry(tiff)?;
    let v = read_u16(tiff, off + 8, tiff.get(0..2)? == b"II")?;
    (1..=8).contains(&v).then_some(v as u8)
}

/// Rewrites the orientation tag in place. Returns false when there is none.
pub fn exif_set_orientation(tiff: &mut [u8], value: u8) -> bool {
    let Some((off, le)) = orientation_entry(tiff) else { return false };
    let b = if le { (value as u16).to_le_bytes() } else { (value as u16).to_be_bytes() };
    tiff[off + 8] = b[0];
    tiff[off + 9] = b[1];
    true
}

/// A TIFF block holding only the orientation tag.
pub fn minimal_exif(orientation: u8) -> Vec<u8> {
    let mut v = Vec::with_capacity(26);
    v.extend_from_slice(b"MM\0\x2a\0\0\0\x08"); // big endian, IFD0 at 8
    v.extend_from_slice(&1u16.to_be_bytes()); // one entry
    v.extend_from_slice(&0x0112u16.to_be_bytes()); // Orientation
    v.extend_from_slice(&3u16.to_be_bytes()); // SHORT
    v.extend_from_slice(&1u32.to_be_bytes()); // count
    v.extend_from_slice(&(orientation as u16).to_be_bytes());
    v.extend_from_slice(&[0, 0]);
    v.extend_from_slice(&0u32.to_be_bytes()); // no next IFD
    v
}

fn read_u16(b: &[u8], off: usize, le: bool) -> Option<u16> {
    let s: [u8; 2] = b.get(off..off + 2)?.try_into().ok()?;
    Some(if le { u16::from_le_bytes(s) } else { u16::from_be_bytes(s) })
}

fn read_u32(b: &[u8], off: usize, le: bool) -> Option<u32> {
    let s: [u8; 4] = b.get(off..off + 4)?.try_into().ok()?;
    Some(if le { u32::from_le_bytes(s) } else { u32::from_be_bytes(s) })
}

/// Offset of the orientation entry in IFD0 and the byte order.
fn orientation_entry(tiff: &[u8]) -> Option<(usize, bool)> {
    let le = match tiff.get(0..4)? {
        b"II\x2a\0" => true,
        b"MM\0\x2a" => false,
        _ => return None,
    };
    let ifd = read_u32(tiff, 4, le)? as usize;
    let n = read_u16(tiff, ifd, le)? as usize;
    (0..n.min(512)).map(|i| ifd + 2 + i * 12).find_map(|e| {
        (read_u16(tiff, e, le)? == 0x0112 && read_u16(tiff, e + 2, le)? == 3 && tiff.len() >= e + 12).then_some((e, le))
    })
}

/// Strips the `Exif\0\0` prefix JPEG and WebP writers sometimes include.
pub fn tiff_payload(exif: &[u8]) -> &[u8] {
    exif.strip_prefix(b"Exif\0\0").unwrap_or(exif)
}

// MARK: JPEG

pub const SOS: u8 = 0xDA;
pub const APP0: u8 = 0xE0;
pub const APP1: u8 = 0xE1;
pub const APP2: u8 = 0xE2;
pub const APP13: u8 = 0xED;
pub const APP14: u8 = 0xEE;
pub const COM: u8 = 0xFE;

const EXIF_ID: &[u8] = b"Exif\0\0";
const XMP_ID: &[u8] = b"http://ns.adobe.com/xap/1.0/\0";
const XMP_EXT_ID: &[u8] = b"http://ns.adobe.com/xmp/extension/\0";
const ICC_ID: &[u8] = b"ICC_PROFILE\0";
const MPF_ID: &[u8] = b"MPF\0";

/// A marker segment before the first scan; `data` excludes the length bytes.
#[derive(Debug, Clone)]
pub struct Segment<'a> {
    pub marker: u8,
    pub data: &'a [u8],
}

impl Segment<'_> {
    pub fn is_exif(&self) -> bool {
        self.marker == APP1 && self.data.starts_with(EXIF_ID)
    }
    pub fn is_xmp(&self) -> bool {
        self.marker == APP1 && (self.data.starts_with(XMP_ID) || self.data.starts_with(XMP_EXT_ID))
    }
    pub fn is_icc(&self) -> bool {
        self.marker == APP2 && self.data.starts_with(ICC_ID)
    }
    pub fn is_mpf(&self) -> bool {
        self.marker == APP2 && self.data.starts_with(MPF_ID)
    }
    pub fn is_jfif(&self) -> bool {
        self.marker == APP0 && (self.data.starts_with(b"JFIF\0") || self.data.starts_with(b"JFXX\0"))
    }
    pub fn is_adobe(&self) -> bool {
        self.marker == APP14 && self.data.starts_with(b"Adobe")
    }
    /// Metadata a person may want removed (as opposed to decoding parameters).
    pub fn is_metadata(&self) -> bool {
        matches!(self.marker, 0xE0..=0xEF | COM) && !self.is_jfif() && !self.is_adobe()
    }
}

/// A JPEG split into its header segments and the rest (first scan to end of file).
#[derive(Debug)]
pub struct JpegParts<'a> {
    pub segments: Vec<Segment<'a>>,
    /// From the first SOS marker to the end of the file.
    pub scan: &'a [u8],
}

impl<'a> JpegParts<'a> {
    pub fn parse(b: &'a [u8]) -> Result<Self> {
        if !b.starts_with(&[0xFF, 0xD8]) {
            return Err(EngineError::unsupported("not a JPEG"));
        }
        let mut pos = 2;
        let mut segments = Vec::new();
        loop {
            // markers may be preceded by any number of 0xFF fill bytes
            while b.get(pos) == Some(&0xFF) && b.get(pos + 1) == Some(&0xFF) {
                pos += 1;
            }
            if b.get(pos) != Some(&0xFF) {
                return Err(EngineError::decode("corrupt JPEG: expected a marker"));
            }
            let marker = *b.get(pos + 1).ok_or_else(|| EngineError::decode("truncated JPEG"))?;
            if marker == SOS {
                return Ok(Self { segments, scan: &b[pos..] });
            }
            if matches!(marker, 0x01 | 0xD0..=0xD7) {
                pos += 2;
                continue;
            }
            if marker == 0xD9 {
                return Err(EngineError::decode("JPEG has no image data"));
            }
            let len = read_u16(b, pos + 2, false).ok_or_else(|| EngineError::decode("truncated JPEG"))? as usize;
            if len < 2 || pos + 2 + len > b.len() {
                return Err(EngineError::decode("truncated JPEG segment"));
            }
            segments.push(Segment { marker, data: &b[pos + 4..pos + 2 + len] });
            pos += 2 + len;
        }
    }

    pub fn exif(&self) -> Option<&'a [u8]> {
        self.segments.iter().find(|s| s.is_exif()).map(|s| &s.data[EXIF_ID.len()..])
    }

    pub fn orientation(&self) -> u8 {
        self.exif().and_then(exif_orientation).unwrap_or(1)
    }

    /// The ICC profile, reassembled from its APP2 chunks in sequence order.
    pub fn icc(&self) -> Option<Vec<u8>> {
        let mut parts: Vec<(u8, &[u8])> = self
            .segments
            .iter()
            .filter(|s| s.is_icc() && s.data.len() >= ICC_ID.len() + 2)
            .map(|s| (s.data[ICC_ID.len()], &s.data[ICC_ID.len() + 2..]))
            .collect();
        if parts.is_empty() {
            return None;
        }
        parts.sort_by_key(|p| p.0);
        Some(parts.into_iter().flat_map(|p| p.1.iter().copied()).collect())
    }

    pub fn has_xmp(&self) -> bool {
        self.segments.iter().any(|s| s.is_xmp())
    }

    pub fn has_mpf(&self) -> bool {
        self.segments.iter().any(|s| s.is_mpf())
    }

    /// The start-of-frame segment.
    pub fn sof(&self) -> Option<&Segment<'a>> {
        self.segments.iter().find(|s| matches!(s.marker, 0xC0..=0xCF) && !matches!(s.marker, 0xC4 | 0xC8 | 0xCC))
    }

    pub fn progressive(&self) -> bool {
        self.sof().is_some_and(|s| matches!(s.marker, 0xC2 | 0xC6 | 0xCA | 0xCE))
    }

    pub fn components(&self) -> u8 {
        self.sof().and_then(|s| s.data.get(5).copied()).unwrap_or(3)
    }

    /// Luminance quantisation table (table 0) in natural order.
    pub fn luma_qtable(&self) -> Option<[u16; 64]> {
        for s in self.segments.iter().filter(|s| s.marker == 0xDB) {
            let mut d = s.data;
            while let Some(&pq_tq) = d.first() {
                let sixteen = pq_tq >> 4 != 0;
                let n = if sixteen { 128 } else { 64 };
                let body = d.get(1..1 + n)?;
                if pq_tq & 0x0F == 0 {
                    let mut t = [0u16; 64];
                    for (i, &z) in ZIGZAG.iter().enumerate() {
                        t[z] =
                            if sixteen { u16::from_be_bytes([body[2 * i], body[2 * i + 1]]) } else { body[i] as u16 };
                    }
                    return Some(t);
                }
                d = &d[1 + n..];
            }
        }
        None
    }
}

/// Zigzag index → natural index.
const ZIGZAG: [usize; 64] = [
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21,
    28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54,
    47, 55, 62, 63,
];

/// APP markers a re-encoded JPEG should carry from its source.
///
/// JFIF and Adobe segments describe the old encoding and are written fresh by the encoder; MPF
/// indexes secondary images (gain maps) that a re-encode does not keep. With `strip`, only the
/// ICC chunks and a minimal orientation block survive (as `keep` allows).
pub fn jpeg_markers_to_carry(
    parts: &JpegParts,
    strip: bool,
    keep: &[Keep],
    orientation_override: Option<u8>,
) -> Vec<(u8, Vec<u8>)> {
    let mut out = Vec::new();
    let keep_icc = keep.contains(&Keep::Icc);
    let keep_orientation = keep.contains(&Keep::Orientation);
    for s in &parts.segments {
        if !matches!(s.marker, 0xE0..=0xEF | COM) || s.is_jfif() || s.is_adobe() || s.is_mpf() {
            continue;
        }
        if strip {
            if s.is_icc() && keep_icc {
                out.push((s.marker, s.data.to_vec()));
            }
            continue;
        }
        if s.is_exif() {
            let mut d = s.data.to_vec();
            if let Some(o) = orientation_override {
                exif_set_orientation(&mut d[EXIF_ID.len()..], o);
            }
            out.push((s.marker, d));
        } else {
            out.push((s.marker, s.data.to_vec()));
        }
    }
    if strip && keep_orientation {
        let o = orientation_override.unwrap_or_else(|| parts.orientation());
        if o != 1 {
            out.insert(0, (APP1, exif_app1(&minimal_exif(o))));
        }
    }
    out
}

/// An APP1 payload for a TIFF/EXIF block.
pub fn exif_app1(tiff: &[u8]) -> Vec<u8> {
    let mut d = EXIF_ID.to_vec();
    d.extend_from_slice(tiff);
    d
}

/// APP2 payloads for an ICC profile (split in chunks of at most 65519 bytes).
pub fn icc_app2(icc: &[u8]) -> Vec<Vec<u8>> {
    const MAX: usize = 65533 - 14;
    let n = icc.len().div_ceil(MAX).max(1);
    if n > 255 {
        return Vec::new();
    }
    icc.chunks(MAX)
        .enumerate()
        .map(|(i, c)| {
            let mut d = ICC_ID.to_vec();
            d.push(i as u8 + 1);
            d.push(n as u8);
            d.extend_from_slice(c);
            d
        })
        .collect()
}

/// Rebuilds a JPEG with only the segments `keep_segment` accepts, then the scan data verbatim.
/// Anything after the end-of-image marker (MPF secondary images) is dropped with the index.
pub fn jpeg_rebuild(
    parts: &JpegParts,
    extra_app: &[(u8, Vec<u8>)],
    keep_segment: impl Fn(&Segment) -> bool,
) -> Vec<u8> {
    let mut out = Vec::with_capacity(parts.scan.len() + 4096);
    out.extend_from_slice(&[0xFF, 0xD8]);
    let mut wrote_extra = extra_app.is_empty();
    for s in &parts.segments {
        // extras go right after JFIF/Adobe, before everything else
        if !wrote_extra && !s.is_jfif() {
            for (m, d) in extra_app {
                push_segment(&mut out, *m, d);
            }
            wrote_extra = true;
        }
        if keep_segment(s) {
            push_segment(&mut out, s.marker, s.data);
        }
    }
    if !wrote_extra {
        for (m, d) in extra_app {
            push_segment(&mut out, *m, d);
        }
    }
    out.extend_from_slice(scan_until_eoi(parts.scan));
    out
}

fn push_segment(out: &mut Vec<u8>, marker: u8, data: &[u8]) {
    out.extend_from_slice(&[0xFF, marker]);
    out.extend_from_slice(&((data.len() + 2) as u16).to_be_bytes());
    out.extend_from_slice(data);
}

/// The scan data up to and including the first EOI that ends the primary image.
fn scan_until_eoi(scan: &[u8]) -> &[u8] {
    // Inside entropy-coded data 0xFF is always followed by 0x00 or a restart marker, so the
    // first FFD9 is the end of the primary image.
    let mut i = 0;
    while i + 1 < scan.len() {
        if scan[i] == 0xFF && scan[i + 1] == 0xD9 {
            return &scan[..i + 2];
        }
        i += 1;
    }
    scan
}

// MARK: PNG

pub const PNG_SIG: &[u8] = b"\x89PNG\r\n\x1a\n";

#[derive(Debug, Clone)]
pub struct Chunk<'a> {
    pub name: [u8; 4],
    pub data: &'a [u8],
}

impl Chunk<'_> {
    pub fn is_colour(&self) -> bool {
        matches!(&self.name, b"iCCP" | b"sRGB" | b"gAMA" | b"cHRM" | b"cICP" | b"mDCV" | b"cLLI")
    }
    /// Text, EXIF, timestamps, provenance and private chunks.
    pub fn is_metadata(&self) -> bool {
        let critical = self.name[0].is_ascii_uppercase();
        let structural = matches!(
            &self.name,
            b"tRNS" | b"bKGD" | b"sBIT" | b"hIST" | b"sPLT" | b"pHYs" | b"acTL" | b"fcTL" | b"fdAT"
        );
        !critical && !structural && !self.is_colour()
    }
}

pub fn png_chunks(b: &[u8]) -> Result<Vec<Chunk<'_>>> {
    if !b.starts_with(PNG_SIG) {
        return Err(EngineError::unsupported("not a PNG"));
    }
    let mut pos = PNG_SIG.len();
    let mut out = Vec::new();
    while pos + 8 <= b.len() {
        let len = read_u32(b, pos, false).unwrap_or(0) as usize;
        let name: [u8; 4] = b[pos + 4..pos + 8].try_into().unwrap();
        let end = pos + 8 + len + 4;
        if end > b.len() {
            return Err(EngineError::decode("truncated PNG chunk"));
        }
        out.push(Chunk { name, data: &b[pos + 8..pos + 8 + len] });
        pos = end;
        if &name == b"IEND" {
            break;
        }
    }
    if out.first().map(|c| &c.name) != Some(b"IHDR") {
        return Err(EngineError::decode("PNG without IHDR"));
    }
    Ok(out)
}

pub fn png_write(chunks: &[(&[u8; 4], &[u8])]) -> Vec<u8> {
    let mut out = PNG_SIG.to_vec();
    for (name, data) in chunks {
        push_png_chunk(&mut out, name, data);
    }
    out
}

fn push_png_chunk(out: &mut Vec<u8>, name: &[u8; 4], data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(name);
    out.extend_from_slice(data);
    let mut h = crc32fast::Hasher::new();
    h.update(name);
    h.update(data);
    out.extend_from_slice(&h.finalize().to_be_bytes());
}

/// PNG ancillary chunks a re-encoded PNG should carry: colour, density and (unless `strip`)
/// text and EXIF. Palette-dependent and encoding-dependent chunks are never carried.
pub fn png_chunks_to_carry(
    chunks: &[Chunk],
    strip: bool,
    keep: &[Keep],
    orientation_override: Option<u8>,
) -> Vec<([u8; 4], Vec<u8>)> {
    let keep_icc = !strip || keep.contains(&Keep::Icc);
    let mut out = Vec::new();
    let mut orientation = 1;
    for c in chunks {
        if &c.name == b"eXIf" {
            orientation = exif_orientation(c.data).unwrap_or(1);
        }
        let carry = if c.is_colour() {
            keep_icc
        } else if &c.name == b"pHYs" {
            true
        } else if c.is_metadata() {
            !strip && &c.name != b"iDOT" && &c.name != b"caBX"
        } else {
            false
        };
        if carry {
            let mut d = c.data.to_vec();
            if &c.name == b"eXIf"
                && let Some(o) = orientation_override
            {
                exif_set_orientation(&mut d, o);
            }
            out.push((c.name, d));
        }
    }
    if strip && keep.contains(&Keep::Orientation) {
        let o = orientation_override.unwrap_or(orientation);
        if o != 1 {
            out.push((*b"eXIf", minimal_exif(o)));
        }
    }
    out
}

/// `metadata.strip` for PNG: drop metadata chunks (and Apple's iDOT, whose IDAT offsets would
/// no longer hold), keep pixels and structure byte for byte.
pub fn png_strip(b: &[u8], keep: &[Keep]) -> Result<Vec<u8>> {
    let chunks = png_chunks(b)?;
    let keep_icc = keep.contains(&Keep::Icc);
    let mut orientation = 1;
    let mut kept: Vec<(&[u8; 4], &[u8])> = Vec::new();
    let extra = keep.contains(&Keep::Orientation).then_some(());
    for c in &chunks {
        if &c.name == b"eXIf" {
            orientation = exif_orientation(c.data).unwrap_or(1);
        }
    }
    let min_exif = (extra.is_some() && orientation != 1).then(|| minimal_exif(orientation));
    for c in &chunks {
        let keep_it = if c.is_colour() { keep_icc } else { !c.is_metadata() };
        if (&c.name == b"IDAT" || &c.name == b"acTL")
            && let Some(e) = &min_exif
            && !kept.iter().any(|k| k.0 == b"eXIf")
        {
            kept.push((b"eXIf", e));
        }
        if keep_it {
            kept.push((&c.name, c.data));
        }
    }
    Ok(png_write(&kept))
}

pub fn png_is_animated(chunks: &[Chunk]) -> bool {
    chunks.iter().take_while(|c| &c.name != b"IDAT").any(|c| &c.name == b"acTL")
}

// MARK: WebP

/// RIFF chunks of a WebP file, in order.
#[derive(Debug, Clone)]
pub struct WebpChunks<'a> {
    pub chunks: Vec<([u8; 4], &'a [u8])>,
}

impl<'a> WebpChunks<'a> {
    pub fn parse(b: &'a [u8]) -> Result<Self> {
        if b.len() < 12 || &b[0..4] != b"RIFF" || &b[8..12] != b"WEBP" {
            return Err(EngineError::unsupported("not a WebP"));
        }
        let end = (read_u32(b, 4, true).unwrap_or(0) as usize + 8).min(b.len());
        let mut pos = 12;
        let mut chunks = Vec::new();
        while pos + 8 <= end {
            let id: [u8; 4] = b[pos..pos + 4].try_into().unwrap();
            let len = read_u32(b, pos + 4, true).unwrap_or(0) as usize;
            let data_end = pos + 8 + len;
            if data_end > end {
                return Err(EngineError::decode("truncated WebP chunk"));
            }
            chunks.push((id, &b[pos + 8..data_end]));
            pos = data_end + (len & 1);
        }
        Ok(Self { chunks })
    }

    pub fn get(&self, id: &[u8; 4]) -> Option<&'a [u8]> {
        self.chunks.iter().find(|c| &c.0 == id).map(|c| c.1)
    }

    pub fn is_animated(&self) -> bool {
        self.chunks.iter().any(|c| &c.0 == b"ANIM")
    }

    pub fn frames(&self) -> u32 {
        let n = self.chunks.iter().filter(|c| &c.0 == b"ANMF").count() as u32;
        n.max(1)
    }

    /// Canvas size.
    pub fn dimensions(&self) -> Option<(u32, u32)> {
        if let Some(x) = self.get(b"VP8X") {
            let w = u32::from_le_bytes([*x.get(4)?, x[5], x[6], 0]) + 1;
            let h = u32::from_le_bytes([*x.get(7)?, x[8], x[9], 0]) + 1;
            return Some((w, h));
        }
        if let Some(l) = self.get(b"VP8L") {
            let bits = u32::from_le_bytes(l.get(1..5)?.try_into().ok()?);
            return Some(((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1));
        }
        let v = self.get(b"VP8 ")?;
        let w = u16::from_le_bytes([*v.get(6)?, v[7]]) as u32 & 0x3FFF;
        let h = u16::from_le_bytes([*v.get(8)?, v[9]]) as u32 & 0x3FFF;
        Some((w, h))
    }

    pub fn has_alpha(&self) -> bool {
        if let Some(x) = self.get(b"VP8X")
            && x.first().is_some_and(|f| f & 0x10 != 0)
        {
            return true;
        }
        if self.get(b"ALPH").is_some() {
            return true;
        }
        self.get(b"VP8L")
            .and_then(|l| l.get(1..5))
            .is_some_and(|h| (u32::from_le_bytes(h.try_into().unwrap()) >> 28) & 1 == 1)
    }
}

/// Builds a WebP file from image chunks (VP8/VP8L/ALPH or ANIM/ANMF) plus optional ICC, EXIF
/// and XMP, writing a correct VP8X header whenever anything beyond a plain bitstream is present.
pub fn webp_build(
    image: &[([u8; 4], &[u8])],
    icc: Option<&[u8]>,
    exif: Option<&[u8]>,
    xmp: Option<&[u8]>,
) -> Result<Vec<u8>> {
    let src = WebpChunks { chunks: image.to_vec() };
    let (w, h) = src.dimensions().ok_or_else(|| EngineError::encode("WebP without dimensions"))?;
    let animated = src.is_animated();
    let alpha = src.has_alpha() || image.iter().any(|c| &c.0 == b"ANMF" && anmf_has_alpha(c.1));
    let extended = icc.is_some() || exif.is_some() || xmp.is_some() || animated || src.get(b"ALPH").is_some();
    let mut body: Vec<u8> = Vec::new();
    let mut push = |id: &[u8; 4], d: &[u8]| {
        body.extend_from_slice(id);
        body.extend_from_slice(&(d.len() as u32).to_le_bytes());
        body.extend_from_slice(d);
        if d.len() & 1 == 1 {
            body.push(0);
        }
    };
    if extended {
        let mut flags = 0u8;
        if icc.is_some() {
            flags |= 0x20;
        }
        if alpha {
            flags |= 0x10;
        }
        if exif.is_some() {
            flags |= 0x08;
        }
        if xmp.is_some() {
            flags |= 0x04;
        }
        if animated {
            flags |= 0x02;
        }
        let mut x = vec![flags, 0, 0, 0];
        x.extend_from_slice(&(w - 1).to_le_bytes()[..3]);
        x.extend_from_slice(&(h - 1).to_le_bytes()[..3]);
        push(b"VP8X", &x);
        if let Some(icc) = icc {
            push(b"ICCP", icc);
        }
    }
    for (id, d) in image.iter().filter(|c| &c.0 != b"VP8X" && &c.0 != b"ICCP" && &c.0 != b"EXIF" && &c.0 != b"XMP ") {
        push(id, d);
    }
    if extended {
        if let Some(e) = exif {
            push(b"EXIF", e);
        }
        if let Some(x) = xmp {
            push(b"XMP ", x);
        }
    }
    let mut out = Vec::with_capacity(body.len() + 12);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&((body.len() + 4) as u32).to_le_bytes());
    out.extend_from_slice(b"WEBP");
    out.extend_from_slice(&body);
    Ok(out)
}

fn anmf_has_alpha(anmf: &[u8]) -> bool {
    // ANMF: 16 bytes of frame header, then sub-chunks
    let mut pos = 16;
    while pos + 8 <= anmf.len() {
        let id = &anmf[pos..pos + 4];
        let len = read_u32(anmf, pos + 4, true).unwrap_or(0) as usize;
        if id == b"ALPH" {
            return true;
        }
        if id == b"VP8L"
            && let Some(h) = anmf.get(pos + 9..pos + 13)
        {
            return (u32::from_le_bytes(h.try_into().unwrap()) >> 28) & 1 == 1;
        }
        pos += 8 + len + (len & 1);
    }
    false
}

/// `metadata.strip` for WebP.
pub fn webp_strip(b: &[u8], keep: &[Keep]) -> Result<Vec<u8>> {
    let w = WebpChunks::parse(b)?;
    let icc = if keep.contains(&Keep::Icc) { w.get(b"ICCP") } else { None };
    let orientation = w.get(b"EXIF").map(tiff_payload).and_then(exif_orientation).unwrap_or(1);
    let min = (keep.contains(&Keep::Orientation) && orientation != 1).then(|| minimal_exif(orientation));
    webp_build(&w.chunks, icc, min.as_deref(), None)
}

// MARK: GIF

/// Walks a GIF's blocks. `f` gets each extension (label, whole block bytes) and returns whether to
/// keep it; image descriptors and the header are always kept. Returns the rebuilt file and the
/// frame count.
pub fn gif_filter(b: &[u8], mut keep_ext: impl FnMut(u8, &[u8]) -> bool) -> Result<(Vec<u8>, u32)> {
    if !(b.starts_with(b"GIF87a") || b.starts_with(b"GIF89a")) {
        return Err(EngineError::unsupported("not a GIF"));
    }
    let bad = || EngineError::decode("truncated GIF");
    let mut out = Vec::with_capacity(b.len());
    let flags = *b.get(10).ok_or_else(bad)?;
    let mut pos = 13 + if flags & 0x80 != 0 { 3 << ((flags & 7) + 1) } else { 0 };
    out.extend_from_slice(b.get(..pos).ok_or_else(bad)?);
    let mut frames = 0;
    let skip_sub_blocks = |mut p: usize| -> Result<usize> {
        loop {
            let n = *b.get(p).ok_or_else(bad)? as usize;
            p += 1 + n;
            if n == 0 {
                return Ok(p);
            }
        }
    };
    loop {
        match b.get(pos) {
            Some(0x21) => {
                let label = *b.get(pos + 1).ok_or_else(bad)?;
                let end = skip_sub_blocks(pos + 2)?;
                let block = b.get(pos..end).ok_or_else(bad)?;
                if keep_ext(label, block) {
                    out.extend_from_slice(block);
                }
                pos = end;
            }
            Some(0x2C) => {
                let flags = *b.get(pos + 9).ok_or_else(bad)?;
                let lct = if flags & 0x80 != 0 { 3 << ((flags & 7) + 1) } else { 0 };
                let data = pos + 10 + lct + 1; // + LZW minimum code size
                let end = skip_sub_blocks(data)?;
                out.extend_from_slice(b.get(pos..end).ok_or_else(bad)?);
                frames += 1;
                pos = end;
            }
            Some(0x3B) | None => {
                out.push(0x3B);
                return Ok((out, frames));
            }
            Some(_) => return Err(EngineError::decode("corrupt GIF block")),
        }
    }
}

/// Whether an application extension is the loop-count block every browser reads.
pub fn gif_is_loop_ext(block: &[u8]) -> bool {
    block.len() >= 14 && block[1] == 0xFF && (&block[3..14] == b"NETSCAPE2.0" || &block[3..14] == b"ANIMEXTS1.0")
}

/// `metadata.strip` for GIF: drops comments and application extensions other than looping.
pub fn gif_strip(b: &[u8]) -> Result<Vec<u8>> {
    gif_filter(b, |label, block| match label {
        0xFE => false,
        0xFF => gif_is_loop_ext(block),
        _ => true,
    })
    .map(|r| r.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn orientation_roundtrip() {
        let mut t = minimal_exif(6);
        assert_eq!(exif_orientation(&t), Some(6));
        assert!(exif_set_orientation(&mut t, 1));
        assert_eq!(exif_orientation(&t), Some(1));
        assert_eq!(exif_orientation(b"nonsense"), None);
    }

    #[test]
    fn icc_split_and_join() {
        let icc: Vec<u8> = (0..150_000u32).map(|i| i as u8).collect();
        let app2 = icc_app2(&icc);
        assert_eq!(app2.len(), 3);
        let segs: Vec<Segment> = app2.iter().map(|d| Segment { marker: APP2, data: d }).collect();
        let parts = JpegParts { segments: segs, scan: &[] };
        assert_eq!(parts.icc().unwrap(), icc);
    }
}
