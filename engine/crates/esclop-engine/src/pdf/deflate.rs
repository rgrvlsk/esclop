// SPDX-License-Identifier: GPL-3.0-or-later
//! Flate for PDF streams: libdeflate at its strongest level, and PNG row predictors for images
//! (`/DecodeParms << /Predictor 15 >>`), choosing each row's filter by the minimum sum of
//! absolute differences, as PNG encoders do.

use libdeflater::{CompressionLvl, Compressor};

/// zlib-wrapped deflate, what `/FlateDecode` reads, at libdeflate level 1..=12.
pub fn zlib(data: &[u8], level: i32) -> Vec<u8> {
    let lvl = CompressionLvl::new(level).unwrap_or_else(|_| CompressionLvl::best());
    let mut c = Compressor::new(lvl);
    let mut out = vec![0u8; c.zlib_compress_bound(data.len())];
    let n = c.zlib_compress(data, &mut out).expect("bound is large enough");
    out.truncate(n);
    out
}

/// Rows of `bytes_per_row`, each prefixed with its PNG filter type. `bpp` is bytes per pixel
/// (at least 1), the distance the Sub, Average and Paeth filters look back.
pub fn png_filter(data: &[u8], bytes_per_row: usize, bpp: usize) -> Vec<u8> {
    let rows = data.len() / bytes_per_row.max(1);
    let mut out = Vec::with_capacity(rows * (bytes_per_row + 1));
    let zero = vec![0u8; bytes_per_row];
    let mut cand = [
        vec![0u8; bytes_per_row],
        vec![0u8; bytes_per_row],
        vec![0u8; bytes_per_row],
        vec![0u8; bytes_per_row],
        vec![0u8; bytes_per_row],
    ];
    for r in 0..rows {
        let row = &data[r * bytes_per_row..(r + 1) * bytes_per_row];
        let up = if r == 0 { &zero[..] } else { &data[(r - 1) * bytes_per_row..r * bytes_per_row] };
        for i in 0..bytes_per_row {
            let a = if i >= bpp { row[i - bpp] } else { 0 };
            let b = up[i];
            let c = if i >= bpp { up[i - bpp] } else { 0 };
            let x = row[i];
            cand[0][i] = x;
            cand[1][i] = x.wrapping_sub(a);
            cand[2][i] = x.wrapping_sub(b);
            cand[3][i] = x.wrapping_sub(((a as u16 + b as u16) / 2) as u8);
            cand[4][i] = x.wrapping_sub(paeth(a, b, c));
        }
        let cost = |v: &Vec<u8>| v.iter().map(|&b| (b as i8).unsigned_abs() as u64).sum::<u64>();
        let best = (0..5).min_by_key(|&k| cost(&cand[k])).unwrap_or(0);
        out.push(best as u8);
        out.extend_from_slice(&cand[best]);
    }
    out
}

fn paeth(a: u8, b: u8, c: u8) -> u8 {
    let p = a as i16 + b as i16 - c as i16;
    let (pa, pb, pc) = ((p - a as i16).abs(), (p - b as i16).abs(), (p - c as i16).abs());
    if pa <= pb && pa <= pc {
        a
    } else if pb <= pc {
        b
    } else {
        c
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn png_filter_round_trips() {
        let (w, h, bpp) = (37usize, 11usize, 3usize);
        let data: Vec<u8> = (0..w * h * bpp).map(|i| ((i * 7) ^ (i / 5)) as u8).collect();
        let f = png_filter(&data, w * bpp, bpp);
        // undo the filters
        let mut out = vec![0u8; data.len()];
        for r in 0..h {
            let t = f[r * (w * bpp + 1)];
            let src = &f[r * (w * bpp + 1) + 1..(r + 1) * (w * bpp + 1)];
            for i in 0..w * bpp {
                let a = if i >= bpp { out[r * w * bpp + i - bpp] } else { 0 };
                let b = if r > 0 { out[(r - 1) * w * bpp + i] } else { 0 };
                let c = if r > 0 && i >= bpp { out[(r - 1) * w * bpp + i - bpp] } else { 0 };
                let pred = match t {
                    0 => 0,
                    1 => a,
                    2 => b,
                    3 => ((a as u16 + b as u16) / 2) as u8,
                    _ => paeth(a, b, c),
                };
                out[r * w * bpp + i] = src[i].wrapping_add(pred);
            }
        }
        assert_eq!(out, data);
    }
}
