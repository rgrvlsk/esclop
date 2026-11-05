// SPDX-License-Identifier: GPL-3.0-or-later
//! Writes the synthetic benchmark corpus: `cargo run --release --example make-corpus -- <dir> [--big]`.
//! `--big` adds a 24-megapixel JPEG for the memory target.

use esclop_engine::synth;
use image::DynamicImage;
use std::path::Path;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let dir = Path::new(args.first().map(String::as_str).unwrap_or("corpus"));
    std::fs::create_dir_all(dir).unwrap();
    let w = |name: &str, data: Vec<u8>| {
        std::fs::write(dir.join(name), data).unwrap();
        println!("{name}");
    };
    for (i, (pw, ph)) in [(1600, 1200), (2400, 1600), (1200, 1600), (3000, 2000)].into_iter().enumerate() {
        let img = synth::photo(pw, ph, 100 + i as u64);
        w(&format!("photo-{i}-q92.jpg"), synth::encode_jpeg(&img, 92));
        if i < 2 {
            w(&format!("photo-{i}.png"), synth::encode_png(&DynamicImage::ImageRgb8(img)));
        }
    }
    for (i, (sw, sh)) in [(1440, 900), (2880, 1800), (1280, 800)].into_iter().enumerate() {
        let img = synth::screenshot(sw, sh, 200 + i as u64);
        w(&format!("screenshot-{i}.png"), synth::encode_png(&DynamicImage::ImageRgb8(img.clone())));
        if i == 0 {
            w("screenshot-0-q95.jpg", synth::encode_jpeg(&img, 95));
        }
    }
    for i in 0..2 {
        let img = synth::alpha_art(900, 700, 300 + i);
        w(&format!("alpha-{i}.png"), synth::encode_png(&DynamicImage::ImageRgba8(img)));
    }
    w("anim-0.gif", synth::encode_gif(&synth::animation(320, 240, 16), 8));
    w("anim-1.gif", synth::encode_gif(&synth::animation(480, 270, 24), 5));
    if args.iter().any(|a| a == "--big") {
        let img = synth::photo(6000, 4000, 999);
        std::fs::write(dir.join("../big-24mp.jpg"), synth::encode_jpeg(&img, 92)).unwrap();
        println!("../big-24mp.jpg");
    }
}
