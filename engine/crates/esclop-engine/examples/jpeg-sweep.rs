// SPDX-License-Identifier: GPL-3.0-or-later
//! For bench/calibrate_jpeg.py: writes `<outdir>/m<q>.jpg` for every native mozjpeg quality
//! 10..=98, with exactly the engine's encoder settings, from one input image.
//! `cargo run --release --example jpeg-sweep -- <input> <outdir>`

use esclop_engine::codec::jpeg::{EncodeOptions, Layout, Mozjpeg};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (input, out) = (&args[0], std::path::Path::new(&args[1]));
    std::fs::create_dir_all(out).unwrap();
    let img = image::open(input).unwrap().into_rgb8();
    let (w, h) = img.dimensions();
    for q in 10..=98u8 {
        let opts = EncodeOptions { quality: q, progressive: true, fast_scans: false, chroma_full: false, markers: &[] };
        let data = Mozjpeg.encode_native(img.as_raw(), w, h, Layout::Rgb, &opts).unwrap();
        std::fs::write(out.join(format!("m{q}.jpg")), data).unwrap();
    }
}
