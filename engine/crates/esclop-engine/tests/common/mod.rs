// SPDX-License-Identifier: GPL-3.0-or-later
//! Test helpers: generated fixtures and a way to drive the binary.

#![allow(dead_code)]

use esclop_engine::meta;
use esclop_engine::synth;
use image::DynamicImage;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::Command;

pub fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_esclop-engine")
}

pub struct Dir(pub tempfile::TempDir);

impl Dir {
    pub fn new() -> Self {
        Dir(tempfile::tempdir().unwrap())
    }
    pub fn path(&self, name: &str) -> PathBuf {
        self.0.path().join(name)
    }
    pub fn write(&self, name: &str, data: &[u8]) -> PathBuf {
        let p = self.path(name);
        std::fs::write(&p, data).unwrap();
        p
    }
}

/// Runs `esclop-engine <op> --json <req>` and returns the parsed response.
pub fn one_shot(op: &str, req: Value) -> Value {
    one_shot_env(op, req, &[])
}

pub fn one_shot_env(op: &str, req: Value, env: &[(&str, &str)]) -> Value {
    let mut c = Command::new(bin());
    c.arg(op).arg("--json").arg(req.to_string());
    for (k, v) in env {
        c.env(k, v);
    }
    let out = c.output().unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    let v: Value = serde_json::from_str(stdout.trim())
        .unwrap_or_else(|e| panic!("bad response {stdout:?}: {e}; stderr {}", String::from_utf8_lossy(&out.stderr)));
    assert_eq!(out.status.success(), v["ok"] == json!(true), "exit status follows ok: {v}");
    v
}

pub fn ok(v: &Value) -> &Value {
    assert_eq!(v["ok"], json!(true), "expected success, got {v}");
    &v["result"]
}

pub fn err_code(v: &Value) -> &str {
    assert_eq!(v["ok"], json!(false), "expected an error, got {v}");
    v["error"]["code"].as_str().unwrap()
}

pub fn req(input: &Path, output: &Path, params: Value) -> Value {
    json!({"input": input, "output": output, "params": params})
}

pub fn size(p: &Path) -> u64 {
    std::fs::metadata(p).unwrap().len()
}

pub fn decode(p: &Path) -> DynamicImage {
    image::open(p).unwrap_or_else(|e| panic!("{} does not decode: {e}", p.display()))
}

// MARK: fixtures

pub fn photo_jpeg(w: u32, h: u32, q: u8) -> Vec<u8> {
    synth::encode_jpeg(&synth::photo(w, h, 7), q)
}

pub fn screenshot_png(w: u32, h: u32) -> Vec<u8> {
    synth::encode_png(&DynamicImage::ImageRgb8(synth::screenshot(w, h, 3)))
}

pub fn alpha_png(w: u32, h: u32) -> Vec<u8> {
    synth::encode_png(&DynamicImage::ImageRgba8(synth::alpha_art(w, h, 5)))
}

pub fn anim_gif_global(w: u32, h: u32, frames: u32) -> Vec<u8> {
    synth::encode_gif_global(&synth::animation(w, h, frames), 8)
}

pub fn anim_gif(w: u32, h: u32, frames: u32) -> Vec<u8> {
    synth::encode_gif(&synth::animation(w, h, frames), 8)
}

/// A fake but well-formed-looking ICC profile (header with the `acsp` signature).
pub fn fake_icc() -> Vec<u8> {
    let mut icc = vec![0u8; 300];
    icc[0..4].copy_from_slice(&300u32.to_be_bytes());
    icc[36..40].copy_from_slice(b"acsp");
    for (i, b) in icc.iter_mut().enumerate().skip(128) {
        *b = (i * 7) as u8;
    }
    icc
}

/// TIFF/EXIF with a camera make (personal-ish data that strip must remove) and an orientation.
pub fn exif_with_make(orientation: u16) -> Vec<u8> {
    let mut t = b"MM\0\x2a\0\0\0\x08".to_vec();
    t.extend_from_slice(&2u16.to_be_bytes());
    // Make, ASCII, 8 bytes at offset 38
    t.extend_from_slice(&0x010Fu16.to_be_bytes());
    t.extend_from_slice(&2u16.to_be_bytes());
    t.extend_from_slice(&8u32.to_be_bytes());
    t.extend_from_slice(&38u32.to_be_bytes());
    // Orientation
    t.extend_from_slice(&0x0112u16.to_be_bytes());
    t.extend_from_slice(&3u16.to_be_bytes());
    t.extend_from_slice(&1u32.to_be_bytes());
    t.extend_from_slice(&orientation.to_be_bytes());
    t.extend_from_slice(&[0, 0]);
    t.extend_from_slice(&0u32.to_be_bytes());
    t.extend_from_slice(b"TestCam\0");
    t
}

/// Adds EXIF, XMP, a comment and an ICC profile to a JPEG.
pub fn jpeg_with_metadata(jpeg: &[u8], orientation: u16) -> Vec<u8> {
    let parts = meta::JpegParts::parse(jpeg).unwrap();
    let mut extra = vec![(meta::APP1, meta::exif_app1(&exif_with_make(orientation)))];
    let mut xmp = b"http://ns.adobe.com/xap/1.0/\0".to_vec();
    xmp.extend_from_slice(b"<x:xmpmeta>synthetic</x:xmpmeta>");
    extra.push((meta::APP1, xmp));
    extra.extend(meta::icc_app2(&fake_icc()).into_iter().map(|d| (meta::APP2, d)));
    extra.push((meta::COM, b"synthetic comment".to_vec()));
    meta::jpeg_rebuild(&parts, &extra, |_| true)
}

/// Adds tEXt, eXIf and iCCP chunks to a PNG.
pub fn png_with_metadata(png: &[u8]) -> Vec<u8> {
    let chunks = meta::png_chunks(png).unwrap();
    let mut iccp = b"fake\0\0".to_vec();
    iccp.extend_from_slice(&miniz_oxide::deflate::compress_to_vec_zlib(&fake_icc(), 6));
    let exif = exif_with_make(1);
    let mut list: Vec<(&[u8; 4], &[u8])> =
        vec![(&chunks[0].name, chunks[0].data), (b"iCCP", &iccp), (b"eXIf", &exif), (b"tEXt", b"Comment\0synthetic")];
    for c in &chunks[1..] {
        list.push((&c.name, c.data));
    }
    meta::png_write(&list)
}
