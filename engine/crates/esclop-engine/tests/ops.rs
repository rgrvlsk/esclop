// SPDX-License-Identifier: GPL-3.0-or-later
//! Every op, driven through the one-shot CLI on generated fixtures. Byte-size goldens are ranges
//! so that a dependency bump that changes output by a few percent shows up as a deliberate
//! update rather than noise; determinism is checked separately and exactly.

mod common;
use common::*;
use esclop_engine::meta;
use image::GenericImageView;
use serde_json::json;

#[test]
fn hello_lists_every_op() {
    let r = one_shot("hello", json!({}));
    let r = ok(&r);
    let ops: Vec<&str> = r["ops"].as_array().unwrap().iter().map(|v| v.as_str().unwrap()).collect();
    assert_eq!(ops, esclop_engine::protocol::OPS);
    assert_eq!(r["protocol"], json!(1));
    assert_eq!(r["features"]["jpeg_codec"], json!("mozjpeg"));
    assert_eq!(r["features"]["compression_normal"], json!(30));
    assert_eq!(r["features"]["compression_aggressive"], json!(64));
}

#[test]
fn probe_reports_format_metadata_and_frames() {
    let d = Dir::new();
    let jpg = d.write("p.jpg", &jpeg_with_metadata(&photo_jpeg(400, 300, 92), 6));
    let r = one_shot("probe", json!({"input": jpg}));
    let r = ok(&r);
    assert_eq!(r["format"], json!("jpeg"));
    assert_eq!((r["width"].as_u64(), r["height"].as_u64()), (Some(400), Some(300)));
    let p = &r["probe"];
    assert_eq!(p["orientation"], json!(6));
    assert_eq!((p["display_width"].as_u64(), p["display_height"].as_u64()), (Some(300), Some(400)));
    assert_eq!(p["has_exif"], json!(true));
    assert_eq!(p["has_icc"], json!(true));
    assert_eq!(p["has_xmp"], json!(true));
    assert_eq!(p["jpeg_quality"], json!(92));
    assert_eq!(p["progressive"], json!(false));

    let gif = d.write("a.gif", &anim_gif(64, 48, 5));
    let r = one_shot("probe", json!({"input": gif}));
    assert_eq!(ok(&r)["probe"]["frames"], json!(5));
    assert_eq!(ok(&r)["probe"]["animated"], json!(true));

    let png = d.write("a.png", &alpha_png(50, 40));
    let r = one_shot("probe", json!({"input": png}));
    assert_eq!(ok(&r)["probe"]["has_alpha"], json!(true));

    // recognised but decoded by ImageIO, not the engine
    let heic = d.write("x.heic", b"\0\0\0\x18ftypheic\0\0\0\0mif1heic");
    let r = one_shot("probe", json!({"input": heic}));
    assert_eq!(ok(&r)["format"], json!("heic"));
    assert_eq!(ok(&r)["probe"]["decodable"], json!(false));
}

#[test]
fn png_lossy_matches_golden_and_is_deterministic() {
    let d = Dir::new();
    let src = d.write("s.png", &screenshot_png(1440, 900));
    let (a, b) = (d.path("a.png"), d.path("b.png"));
    let ra = one_shot("png.optimise", req(&src, &a, json!({})));
    let rb = one_shot("png.optimise", req(&src, &b, json!({})));
    let r = ok(&ra);
    assert_eq!(r["lossy"], json!(true));
    assert_eq!(r["format"], json!("png"));
    assert_eq!(std::fs::read(&a).unwrap(), std::fs::read(&b).unwrap(), "same input and params, same bytes");
    assert_eq!(ra["result"]["bytes_after"], rb["result"]["bytes_after"]);
    let before = size(&src);
    let after = size(&a);
    assert!(after < before / 2, "screenshot palette saves at least half: {before} -> {after}");
    assert!((14_000..=16_500).contains(&after), "golden range for the 1440x900 screenshot at oxipng level 0: {after}");
    assert_eq!(decode(&a).dimensions(), (1440, 900));
}

#[test]
fn png_lossless_keeps_every_pixel_and_metadata() {
    let d = Dir::new();
    let src = d.write("s.png", &png_with_metadata(&alpha_png(300, 200)));
    let out = d.path("o.png");
    let r = one_shot("png.optimise", req(&src, &out, json!({"lossy": false})));
    assert_eq!(ok(&r)["lossy"], json!(false));
    assert_eq!(decode(&src).to_rgba8().as_raw(), decode(&out).to_rgba8().as_raw());
    let data = std::fs::read(&out).unwrap();
    let names: Vec<[u8; 4]> = meta::png_chunks(&data).unwrap().iter().map(|c| c.name).collect();
    assert!(
        names.contains(b"tEXt") && names.contains(b"iCCP") && names.contains(b"eXIf"),
        "metadata kept when not stripping"
    );

    let stripped = d.path("st.png");
    let r = one_shot("png.optimise", req(&src, &stripped, json!({"lossy": false, "strip": true})));
    ok(&r);
    let data = std::fs::read(&stripped).unwrap();
    let names: Vec<[u8; 4]> = meta::png_chunks(&data).unwrap().iter().map(|c| c.name).collect();
    assert!(!names.contains(b"tEXt") && !names.contains(b"eXIf"));
    assert!(names.contains(b"iCCP"), "strip keeps the colour profile by default");
}

#[test]
fn png_already_optimised_answers_already_smaller() {
    let d = Dir::new();
    let src = d.write("s.png", &screenshot_png(400, 300));
    let r = one_shot("png.optimise", json!({"input": src, "params": {"in_place": true}}));
    let first = ok(&r)["bytes_after"].as_u64().unwrap();
    assert_eq!(size(&src), first);
    let r = one_shot("png.optimise", json!({"input": src, "params": {"in_place": true}}));
    assert_eq!(err_code(&r), "already_smaller");
    assert_eq!(size(&src), first, "nothing written on already_smaller");
}

#[test]
fn png_falls_back_to_lossless_when_quality_floor_is_missed() {
    let d = Dir::new();
    let src = d.write(
        "p.png",
        &esclop_engine::synth::encode_png(&image::DynamicImage::ImageRgb8(esclop_engine::synth::photo(300, 200, 1))),
    );
    let out = d.path("o.png");
    let r = one_shot("png.optimise", req(&src, &out, json!({"quality": [99, 100], "colors": 8})));
    assert_eq!(ok(&r)["lossy"], json!(false));
    assert_eq!(decode(&src).to_rgb8().as_raw(), decode(&out).to_rgb8().as_raw());
}

#[test]
fn jpeg_reencodes_above_the_ceiling_and_is_idempotent() {
    let d = Dir::new();
    let src = d.write("p.jpg", &photo_jpeg(1200, 900, 95));
    let out = d.path("o.jpg");
    let r = one_shot("jpeg.optimise", req(&src, &out, json!({})));
    let r1 = ok(&r);
    assert_eq!(r1["quality"], json!(85), "normal = quality ceiling 85");
    assert_eq!(r1["lossy"], json!(true));
    let (before, after) = (size(&src), size(&out));
    assert!(after * 100 / before <= 60, "q95 -> q85 mozjpeg saves 40%+: {before} -> {after}");
    let parts_data = std::fs::read(&out).unwrap();
    let parts = meta::JpegParts::parse(&parts_data).unwrap();
    assert!(parts.progressive());

    // optimising the result again never re-encodes it
    let again = d.path("again.jpg");
    let r = one_shot("jpeg.optimise", req(&out, &again, json!({})));
    if r["ok"] == json!(true) {
        assert_eq!(r["result"]["lossy"], json!(false));
    } else {
        assert_eq!(err_code(&r), "already_smaller");
    }

    // aggressive ceiling
    let agg = d.path("agg.jpg");
    let r = one_shot("jpeg.optimise", req(&src, &agg, json!({"compression": 64})));
    assert_eq!(ok(&r)["quality"], json!(58));
    assert!(size(&agg) < after);
}

#[test]
fn jpeg_lossless_recompress_keeps_pixels_and_metadata() {
    let d = Dir::new();
    let src = d.write("p.jpg", &jpeg_with_metadata(&photo_jpeg(640, 480, 80), 6));
    let out = d.path("o.jpg");
    let r = one_shot("jpeg.optimise", req(&src, &out, json!({"quality": null})));
    let r1 = ok(&r);
    assert_eq!(r1["lossy"], json!(false));
    assert!(r1.get("quality").is_none());
    assert!(size(&out) < size(&src));
    assert_eq!(decode(&src).to_rgb8().as_raw(), decode(&out).to_rgb8().as_raw(), "lossless recompression");
    let data = std::fs::read(&out).unwrap();
    let parts = meta::JpegParts::parse(&data).unwrap();
    assert_eq!(parts.orientation(), 6);
    assert!(parts.has_xmp() && parts.icc().is_some());
    assert!(parts.exif().unwrap().windows(7).any(|w| w == b"TestCam"));
}

#[test]
fn jpeg_strip_keeps_only_icc_and_orientation() {
    let d = Dir::new();
    let src = d.write("p.jpg", &jpeg_with_metadata(&photo_jpeg(640, 480, 95), 6));
    let out = d.path("o.jpg");
    let r = one_shot("jpeg.optimise", req(&src, &out, json!({"strip": true})));
    ok(&r);
    let data = std::fs::read(&out).unwrap();
    let parts = meta::JpegParts::parse(&data).unwrap();
    assert_eq!(parts.orientation(), 6);
    assert!(parts.icc().is_some());
    assert!(!parts.has_xmp());
    assert!(!parts.exif().unwrap().windows(7).any(|w| w == b"TestCam"), "camera make removed");
    assert!(parts.segments.iter().all(|s| s.marker != meta::COM));

    let none = d.path("none.jpg");
    let r = one_shot("jpeg.optimise", req(&src, &none, json!({"strip": true, "keep": []})));
    ok(&r);
    let data = std::fs::read(&none).unwrap();
    let parts = meta::JpegParts::parse(&data).unwrap();
    assert!(parts.exif().is_none() && parts.icc().is_none());
}

#[test]
fn metadata_strip_is_lossless_for_every_container() {
    let d = Dir::new();
    let jpg = d.write("p.jpg", &jpeg_with_metadata(&photo_jpeg(320, 240, 90), 3));
    let out = d.path("o.jpg");
    let r = one_shot("metadata.strip", req(&jpg, &out, json!({})));
    assert_eq!(ok(&r)["lossy"], json!(false));
    let parts_src = std::fs::read(&jpg).unwrap();
    let parts_out = std::fs::read(&out).unwrap();
    let (a, b) = (meta::JpegParts::parse(&parts_src).unwrap(), meta::JpegParts::parse(&parts_out).unwrap());
    assert_eq!(a.scan, b.scan, "entropy-coded data untouched");
    assert_eq!(b.orientation(), 3);
    assert!(!b.has_xmp());

    let png = d.write("p.png", &png_with_metadata(&screenshot_png(200, 100)));
    let out = d.path("o.png");
    ok(&one_shot("metadata.strip", req(&png, &out, json!({"keep": []}))));
    let data = std::fs::read(&out).unwrap();
    let names: Vec<[u8; 4]> = meta::png_chunks(&data).unwrap().iter().map(|c| c.name).collect();
    assert_eq!(names, vec![*b"IHDR", *b"IDAT", *b"IEND"]);
    assert_eq!(decode(&png).to_rgb8().as_raw(), decode(&out).to_rgb8().as_raw());

    let gif = d.write("a.gif", &anim_gif(40, 30, 3));
    let out = d.path("o.gif");
    ok(&one_shot("metadata.strip", req(&gif, &out, json!({}))));
    assert!(size(&out) <= size(&gif));
}

#[test]
fn webp_and_avif_encode_from_png_and_jpeg() {
    let d = Dir::new();
    let src = d.write("s.png", &png_with_metadata(&alpha_png(400, 300)));
    let out = d.path("o.webp");
    let r = one_shot("webp.encode", req(&src, &out, json!({})));
    let r1 = ok(&r);
    assert_eq!(r1["quality"], json!(60));
    let data = std::fs::read(&out).unwrap();
    let w = meta::WebpChunks::parse(&data).unwrap();
    assert!(w.has_alpha());
    assert_eq!(w.get(b"ICCP").map(|c| c.len()), Some(fake_icc().len()), "ICC carried");
    assert_eq!(decode(&out).dimensions(), (400, 300));

    let lossless = d.path("l.webp");
    ok(&one_shot("webp.encode", req(&src, &lossless, json!({"lossless": true}))));
    assert_eq!(decode(&src).to_rgba8().as_raw(), decode(&lossless).to_rgba8().as_raw());

    let jpg = d.write("p.jpg", &photo_jpeg(640, 480, 92));
    let avif = d.path("o.avif");
    let r = one_shot("avif.encode", req(&jpg, &avif, json!({"speed": 8})));
    ok(&r);
    let data = std::fs::read(&avif).unwrap();
    assert_eq!(esclop_engine::format::sniff(&data), Some(esclop_engine::protocol::Format::Avif));
    assert!(size(&avif) < size(&jpg));
}

fn gif_frames(p: &std::path::Path) -> Vec<image::RgbaImage> {
    use image::AnimationDecoder;
    let f = std::fs::File::open(p).unwrap();
    image::codecs::gif::GifDecoder::new(std::io::BufReader::new(f))
        .unwrap()
        .into_frames()
        .map(|f| f.unwrap().into_buffer())
        .collect()
}

#[test]
fn gif_optimise_builtin_and_gifsicle() {
    let d = Dir::new();
    // full frames over a global palette: the built-in optimiser must shrink them without
    // changing a pixel
    let src = d.write("a.gif", &anim_gif_global(320, 240, 12));
    let out = d.path("b.gif");
    let r = one_shot("gif.optimise", req(&src, &out, json!({"backend": "builtin", "lossy": 0})));
    let r1 = ok(&r);
    assert_eq!(r1["backend"], json!("builtin"));
    assert_eq!(r1["frames"], json!(12));
    assert!(size(&out) * 2 < size(&src), "frame differencing halves a naive GIF: {} -> {}", size(&src), size(&out));
    let (a, b) = (gif_frames(&src), gif_frames(&out));
    assert_eq!(a.len(), b.len());
    for (x, y) in a.iter().zip(&b) {
        assert_eq!(x.as_raw(), y.as_raw(), "lossless built-in path keeps every frame");
    }

    // per-frame palettes (the hard case): aggressive still shrinks it
    let hard = d.write("h.gif", &anim_gif(320, 240, 12));
    let out = d.path("h-o.gif");
    let r = one_shot("gif.optimise", req(&hard, &out, json!({"backend": "builtin", "compression": 64})));
    ok(&r);
    assert!(size(&out) * 100 < size(&hard) * 85, "{} -> {}", size(&hard), size(&out));

    let hidden = one_shot_env(
        "gif.optimise",
        req(&src, &d.path("c.gif"), json!({"backend": "gifsicle"})),
        &[("ESCLOP_NO_GIFSICLE", "1")],
    );
    assert_eq!(err_code(&hidden), "unsupported");

    if esclop_engine::codec::gif::find_gifsicle().is_some() {
        let out = d.path("g.gif");
        let r = one_shot("gif.optimise", req(&src, &out, json!({"backend": "gifsicle"})));
        assert_eq!(ok(&r)["backend"], json!("gifsicle"));
        assert!(size(&out) < size(&src));
        let data = std::fs::read(&out).unwrap();
        assert_eq!(meta::gif_filter(&data, |_, _| true).unwrap().1, 12);
    }
}

#[test]
fn gif_from_frames_streams_a_folder() {
    let d = Dir::new();
    let frames = d.path("frames");
    std::fs::create_dir(&frames).unwrap();
    for (i, f) in esclop_engine::synth::animation(160, 120, 8).into_iter().enumerate() {
        f.save(frames.join(format!("frame_{i:04}.png"))).unwrap();
    }
    let out = d.path("o.gif");
    let r =
        one_shot("gif.from_frames", json!({"output": out, "params": {"frames_dir": frames, "fps": 12.5, "width": 80}}));
    let r1 = ok(&r);
    assert_eq!(r1["frames"], json!(8));
    assert_eq!(r1["width"], json!(80));
    let data = std::fs::read(&out).unwrap();
    assert_eq!(meta::gif_filter(&data, |_, _| true).unwrap().1, 8);
}

#[test]
fn resize_applies_orientation_and_keeps_format() {
    let d = Dir::new();
    let src = d.write("p.jpg", &jpeg_with_metadata(&photo_jpeg(400, 300, 92), 6));
    let out = d.path("o.jpg");
    let r = one_shot("resize", req(&src, &out, json!({"scale": 0.5})));
    let r1 = ok(&r);
    assert_eq!(
        (r1["width"].as_u64(), r1["height"].as_u64()),
        (Some(150), Some(200)),
        "upright: stored 400x300 at orientation 6 is 300x400"
    );
    assert_eq!(r1["format"], json!("jpeg"));
    let data = std::fs::read(&out).unwrap();
    assert_eq!(meta::JpegParts::parse(&data).unwrap().orientation(), 1);

    let png = d.write("s.png", &screenshot_png(1000, 500));
    let out = d.path("o.webp");
    let r = one_shot("resize", req(&png, &out, json!({"long_edge": 250, "format": "webp", "filter": "catmull_rom"})));
    assert_eq!((ok(&r)["width"].as_u64(), ok(&r)["height"].as_u64()), (Some(250), Some(125)));
    assert_eq!(decode(&out).dimensions(), (250, 125));

    let gif = d.write("a.gif", &anim_gif(200, 100, 4));
    let out = d.path("o.gif");
    let r = one_shot("resize", req(&gif, &out, json!({"width": 100})));
    assert_eq!(ok(&r)["frames"], json!(4));
    assert_eq!(decode(&out).dimensions(), (100, 50));

    let r = one_shot("resize", req(&png, &d.path("x.png"), json!({"scale": 0.5, "width": 10})));
    assert_eq!(err_code(&r), "invalid_params");
}

#[test]
fn crop_rect_aspect_and_to_size() {
    let d = Dir::new();
    let src = d.write("s.png", &screenshot_png(800, 600));
    let a = d.path("a.png");
    let r = one_shot("crop", req(&src, &a, json!({"x": 10, "y": 20, "width": 300, "height": 200, "lossy": false})));
    ok(&r);
    let full = decode(&src).to_rgb8();
    let cut = decode(&a).to_rgb8();
    assert_eq!(cut.dimensions(), (300, 200));
    assert_eq!(cut.get_pixel(0, 0), full.get_pixel(10, 20), "lossless crop is exact");

    let b = d.path("b.png");
    let r = one_shot(
        "crop",
        req(&src, &b, json!({"aspect": "1:1", "smart": {"x": 700, "y": 0, "width": 100, "height": 100}})),
    );
    ok(&r);
    assert_eq!(decode(&b).dimensions(), (600, 600));

    let c = d.path("c.jpg");
    let r = one_shot("crop", req(&src, &c, json!({"width": 160, "height": 90, "format": "jpeg"})));
    assert_eq!(ok(&r)["format"], json!("jpeg"));
    assert_eq!(decode(&c).dimensions(), (160, 90));

    let r = one_shot("crop", req(&src, &d.path("x.png"), json!({"x": 700, "y": 0, "width": 200, "height": 10})));
    assert_eq!(err_code(&r), "invalid_params");
}

#[test]
fn convert_between_formats() {
    let d = Dir::new();
    let src = d.write("s.png", &alpha_png(300, 200));
    let jpg = d.path("o.jpg");
    let r = one_shot("convert", req(&src, &jpg, json!({"format": "jpeg", "quality": 90})));
    assert_eq!(ok(&r)["quality"], json!(90));
    let px = decode(&jpg).to_rgb8();
    assert!(px.get_pixel(0, 0).0.iter().all(|&c| c > 240), "transparent corners flatten to white");

    let gif = d.write("a.gif", &anim_gif(120, 90, 6));
    let webp = d.path("a.webp");
    let r = one_shot("convert", req(&gif, &webp, json!({"format": "webp"})));
    assert_eq!(ok(&r)["frames"], json!(6));
    let data = std::fs::read(&webp).unwrap();
    assert!(meta::WebpChunks::parse(&data).unwrap().is_animated());

    let png = d.path("b.png");
    ok(&one_shot("convert", req(&jpg, &png, json!({"format": "png", "lossy": false}))));
    assert_eq!(decode(&png).dimensions(), (300, 200));

    let r = one_shot("convert", req(&src, &d.path("x"), json!({})));
    assert_eq!(err_code(&r), "invalid_params");
}

#[test]
fn fit_lands_under_target() {
    let d = Dir::new();
    let src = d.write("p.jpg", &photo_jpeg(1600, 1200, 92));
    let before = size(&src);
    let target = before * 35 / 100;
    let out = d.path("o.jpg");
    let r = one_shot("fit", req(&src, &out, json!({"target_bytes": target})));
    let r1 = ok(&r);
    assert_eq!(r1["fitted"], json!(true));
    assert!(size(&out) <= target, "{} > {target}", size(&out));
    assert!(size(&out) >= target * 70 / 100, "uses the budget: {} vs {target}", size(&out));
    assert_eq!(r1["scale"], json!(1.0));
    assert!(r1["quality"].as_u64().unwrap() >= 10);

    // a target only a downscale can reach
    let tiny = d.path("t.webp");
    let r = one_shot("fit", req(&src, &tiny, json!({"target_bytes": 6000, "format": "webp"})));
    let r1 = ok(&r);
    assert_eq!(r1["fitted"], json!(true));
    assert!(size(&tiny) <= 6000);
    assert!(size(&tiny) >= 6000 * 70 / 100, "the downscale path uses the budget too: {}", size(&tiny));
    assert!(r1["scale"].as_f64().unwrap() < 1.0);

    // JPEG through the downscale path: probes must predict the final (progressive) size
    let small = d.path("s.jpg");
    let r = one_shot("fit", req(&src, &small, json!({"target_bytes": 5000})));
    assert_eq!(ok(&r)["fitted"], json!(true));
    assert!(ok(&r)["scale"].as_f64().unwrap() < 1.0);
    assert!((3_500..=5_000).contains(&size(&small)), "{} for a 5000-byte target", size(&small));

    // no resizing allowed: best effort, flagged
    let r = one_shot("fit", req(&src, &d.path("n.jpg"), json!({"target_bytes": 2000, "allow_resize": false})));
    assert_eq!(ok(&r)["fitted"], json!(false));

    let r = one_shot("fit", req(&src, &d.path("x.jpg"), json!({"target_bytes": before * 2})));
    assert_eq!(err_code(&r), "already_smaller");
}

#[test]
fn in_place_keeps_mode_and_creation_date_and_refuses_without_flag() {
    use std::os::unix::fs::PermissionsExt;
    let d = Dir::new();
    let src = d.write("s.png", &screenshot_png(500, 400));
    std::fs::set_permissions(&src, std::fs::Permissions::from_mode(0o640)).unwrap();
    let created = std::fs::metadata(&src).unwrap().created().unwrap();
    std::thread::sleep(std::time::Duration::from_millis(1100));

    let r = one_shot("png.optimise", req(&src, &src, json!({})));
    assert_eq!(err_code(&r), "invalid_params");

    let r = one_shot("png.optimise", req(&src, &src, json!({"in_place": true})));
    ok(&r);
    let m = std::fs::metadata(&src).unwrap();
    assert_eq!(m.permissions().mode() & 0o777, 0o640);
    assert_eq!(m.created().unwrap(), created);
    assert!(
        std::fs::read_dir(d.0.path()).unwrap().all(|e| !e
            .unwrap()
            .file_name()
            .to_string_lossy()
            .ends_with(".esclop-tmp")),
        "no temp file left"
    );
}

#[test]
fn errors_use_the_documented_codes() {
    let d = Dir::new();
    let jpg = d.write("p.jpg", &photo_jpeg(64, 64, 90));
    let r = one_shot("png.optimise", req(&jpg, &d.path("o.png"), json!({})));
    assert_eq!(err_code(&r), "unsupported");
    let r = one_shot("probe", json!({"input": d.path("missing.png")}));
    assert_eq!(err_code(&r), "not_found");
    let r = one_shot("jpeg.optimise", req(&jpg, &d.path("o.jpg"), json!({"quality": 300})));
    assert_eq!(err_code(&r), "invalid_params");
    let mut png = screenshot_png(300, 300);
    png.truncate(png.len() / 2);
    let bad = d.write("bad.png", &png);
    let r = one_shot("png.optimise", req(&bad, &d.path("o2.png"), json!({})));
    assert_eq!(err_code(&r), "decode");
    let r = one_shot("webp.encode", req(&jpg, &d.path("nodir/o.webp"), json!({})));
    assert_eq!(err_code(&r), "not_found");
    let r = one_shot("teleport", json!({}));
    assert_eq!(err_code(&r), "unsupported");
    let r = one_shot("probe", json!({"input": jpg, "params": {"bogus": 1}}));
    assert_eq!(ok(&r)["ignored_params"], json!(["bogus"]));
}

/// Output sizes of each encoder on fixed fixtures. Ranges, so that a dependency bump that moves
/// output by a few percent is a deliberate update and not noise; exact bytes are covered by the
/// determinism test.
#[test]
fn golden_sizes() {
    let d = Dir::new();
    let photo = d.write("p.jpg", &photo_jpeg(1200, 900, 95));
    let small = d.write("s.jpg", &photo_jpeg(640, 480, 92));
    let gif = d.write("a.gif", &anim_gif_global(320, 240, 12));
    let cases: Vec<(&str, &str, serde_json::Value, &std::path::Path, std::ops::RangeInclusive<u64>)> = vec![
        ("jpeg.optimise", "o.jpg", json!({}), &photo, GOLDEN_JPEG),
        ("webp.encode", "o.webp", json!({}), &small, 12_500..=15_000),
        ("avif.encode", "o.avif", json!({}), &small, golden_avif()),
        ("gif.optimise", "o.gif", json!({"backend": "builtin", "lossy": 0}), &gif, 10_400..=12_500),
    ];
    let mut report = Vec::new();
    for (op, name, params, src, range) in cases {
        let out = d.path(name);
        ok(&one_shot(op, req(src, &out, params)));
        report.push((op, size(&out), range));
    }
    let frames = d.path("frames");
    std::fs::create_dir(&frames).unwrap();
    for (i, f) in esclop_engine::synth::animation(160, 120, 8).into_iter().enumerate() {
        f.save(frames.join(format!("f{i:03}.png"))).unwrap();
    }
    let out = d.path("f.gif");
    ok(&one_shot("gif.from_frames", json!({"output": out, "params": {"frames_dir": frames}})));
    report.push(("gif.from_frames", size(&out), 33_000..=39_500));
    let bad: Vec<_> = report.iter().filter(|(_, s, r)| !r.contains(s)).collect();
    assert!(bad.is_empty(), "outside golden ranges: {bad:?} (all: {report:?})");
}

/// q95 photo at the normal ceiling (libjpeg 85, mozjpeg 90 after calibration).
const GOLDEN_JPEG: std::ops::RangeInclusive<u64> = 150_000..=175_000;

/// AVIF golden for the 640x480 photo at normal: depends on the linked libaom (3.15 with
/// tune=iq in release builds, libaom-sys's bundled 3.11 with default tuning in a plain
/// `cargo build`) or on rav1e.
fn golden_avif() -> std::ops::RangeInclusive<u64> {
    match esclop_engine::codec::avif::codec().map(|c| c.describe()) {
        Some(d) if d.contains("tune=iq") => GOLDEN_AVIF_IQ,
        Some(d) if d.contains("libaom") => GOLDEN_AVIF_DEFAULT_TUNE,
        _ => 1..=u64::MAX,
    }
}

const GOLDEN_AVIF_IQ: std::ops::RangeInclusive<u64> = 29_500..=34_500;
const GOLDEN_AVIF_DEFAULT_TUNE: std::ops::RangeInclusive<u64> = 34_000..=41_500;

#[test]
fn avif_is_deterministic_carries_icc_and_grids_large_images() {
    if esclop_engine::codec::avif::codec().is_none() {
        return;
    }
    let d = Dir::new();
    let src = d.write("s.png", &png_with_metadata(&alpha_png(400, 300)));
    let (a, b) = (d.path("a.avif"), d.path("b.avif"));
    ok(&one_shot("avif.encode", req(&src, &a, json!({}))));
    ok(&one_shot("avif.encode", req(&src, &b, json!({}))));
    let data = std::fs::read(&a).unwrap();
    assert_eq!(data, std::fs::read(&b).unwrap(), "same input and params, same bytes");
    let has = |hay: &[u8], needle: &[u8]| hay.windows(needle.len()).any(|w| w == needle);
    if esclop_engine::codec::avif::codec().unwrap().describe().contains("libaom") {
        assert!(has(&data, &fake_icc()[128..200]), "ICC profile embedded");
        assert!(!has(&data, b"grid"), "small images are one image");
        // above 12 megapixels: a grid of cells
        let big = d.write(
            "big.png",
            &esclop_engine::synth::encode_png(&image::DynamicImage::ImageRgb8(esclop_engine::synth::screenshot(
                4200, 3000, 9,
            ))),
        );
        let out = d.path("big.avif");
        let r = one_shot("avif.encode", req(&big, &out, json!({"speed": 9})));
        assert_eq!((ok(&r)["width"].as_u64(), ok(&r)["height"].as_u64()), (Some(4200), Some(3000)));
        assert!(has(&std::fs::read(&out).unwrap(), b"grid"), "12.6 MP is written as a grid");
    }
    let h = one_shot("hello", json!({}));
    assert!(ok(&h)["features"]["avif_encoder"].is_string());
}
