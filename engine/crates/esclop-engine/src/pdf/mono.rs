// SPDX-License-Identifier: GPL-3.0-or-later
//! 1-bit images: CCITT Group 4 (the `fax` crate) and downsampling by area coverage. Samples are
//! one byte per pixel holding the PDF sample value (0 or 1), so `/Decode` keeps its meaning.

use fax::{Color, VecWriter, decoder, encoder::Encoder};

/// Decodes Group 4 data as a PDF reader does for `/K -1`: with `black_is_1` false, black runs
/// are samples of 0.
pub fn decode_g4(data: &[u8], width: u32, height: u32, black_is_1: bool) -> Option<Vec<u8>> {
    let (w, h) = (u16::try_from(width).ok()?, u16::try_from(height).ok()?);
    let (black, white) = if black_is_1 { (1u8, 0u8) } else { (0, 1) };
    let mut out = Vec::with_capacity(width as usize * height as usize);
    decoder::decode_g4(data.iter().copied(), w, Some(h), |line| {
        out.extend(decoder::pels(line, w).map(|c| if c == Color::Black { black } else { white }));
    })?;
    (out.len() == width as usize * height as usize).then_some(out)
}

/// Group 4 with `/BlackIs1 false`: samples of 0 are coded as black.
pub fn encode_g4(samples: &[u8], width: u32, height: u32) -> Option<Vec<u8>> {
    let w = u16::try_from(width).ok()?;
    let mut enc = Encoder::new(VecWriter::new());
    for row in samples.chunks_exact(width as usize).take(height as usize) {
        enc.encode_line(row.iter().map(|&s| if s == 0 { Color::Black } else { Color::White }), w).ok()?;
    }
    Some(enc.finish().ok()?.finish())
}

/// Unpacks rows of 1-bit samples (each row padded to a byte).
pub fn unpack(packed: &[u8], width: u32, height: u32) -> Vec<u8> {
    let row = (width as usize).div_ceil(8);
    let mut out = Vec::with_capacity(width as usize * height as usize);
    for r in packed.chunks_exact(row).take(height as usize) {
        out.extend((0..width as usize).map(|x| (r[x / 8] >> (7 - x % 8)) & 1));
    }
    out
}

/// Packs one-byte samples back into rows of bits.
pub fn pack(samples: &[u8], width: u32) -> Vec<u8> {
    let row = (width as usize).div_ceil(8);
    let mut out = Vec::with_capacity(row * samples.len() / width.max(1) as usize);
    for r in samples.chunks_exact(width as usize) {
        let mut bytes = vec![0u8; row];
        for (x, &s) in r.iter().enumerate() {
            bytes[x / 8] |= (s & 1) << (7 - x % 8);
        }
        out.extend_from_slice(&bytes);
    }
    out
}

/// Downsamples by area: each new pixel is 1 when at least half of the area it covers is 1.
pub fn downsample(samples: &[u8], width: u32, height: u32, nw: u32, nh: u32) -> Vec<u8> {
    let (w, h) = (width as usize, height as usize);
    // Integral image of the 1 samples.
    let mut sum = vec![0u32; (w + 1) * (h + 1)];
    for y in 0..h {
        let mut run = 0u32;
        for x in 0..w {
            run += samples[y * w + x] as u32;
            sum[(y + 1) * (w + 1) + x + 1] = sum[y * (w + 1) + x + 1] + run;
        }
    }
    let mut out = Vec::with_capacity(nw as usize * nh as usize);
    for ny in 0..nh as usize {
        let y0 = ny * h / nh as usize;
        let y1 = ((ny + 1) * h / nh as usize).max(y0 + 1);
        for nx in 0..nw as usize {
            let x0 = nx * w / nw as usize;
            let x1 = ((nx + 1) * w / nw as usize).max(x0 + 1);
            let ones =
                sum[y1 * (w + 1) + x1] + sum[y0 * (w + 1) + x0] - sum[y0 * (w + 1) + x1] - sum[y1 * (w + 1) + x0];
            let area = ((y1 - y0) * (x1 - x0)) as u32;
            out.push((ones * 2 >= area) as u8);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn page(w: u32, h: u32) -> Vec<u8> {
        (0..w * h).map(|i| !((i % w) / 7 + (i / w) / 5).is_multiple_of(3) as u8).collect()
    }

    #[test]
    fn g4_round_trips() {
        let (w, h) = (203, 77);
        let px = page(w, h);
        let enc = encode_g4(&px, w, h).unwrap();
        assert_eq!(decode_g4(&enc, w, h, false).unwrap(), px);
        let inverted: Vec<u8> = px.iter().map(|s| 1 - s).collect();
        assert_eq!(decode_g4(&enc, w, h, true).unwrap(), inverted);
    }

    #[test]
    fn packing_round_trips() {
        let (w, h) = (13, 4);
        let px = page(w, h);
        assert_eq!(unpack(&pack(&px, w), w, h), px);
    }

    #[test]
    fn downsampling_keeps_solid_areas() {
        let mut px = vec![1u8; 40 * 40];
        for y in 0..20 {
            for x in 0..40 {
                px[y * 40 + x] = 0;
            }
        }
        let d = downsample(&px, 40, 40, 20, 20);
        assert!(d[..200].iter().all(|&s| s == 0) && d[200..].iter().all(|&s| s == 1));
    }
}
