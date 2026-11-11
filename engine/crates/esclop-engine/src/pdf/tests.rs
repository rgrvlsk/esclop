// SPDX-License-Identifier: GPL-3.0-or-later
//! `rewrite` on small crafted files: shapes that once hung, exhausted memory or broke what the
//! file must keep.

use super::*;
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// A PDF from object bodies: object `n` is `objs[n - 1]`; object 1 must be the catalog.
pub fn build(objs: &[Vec<u8>]) -> Vec<u8> {
    let mut out = b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n".to_vec();
    let mut offsets = Vec::new();
    for (i, o) in objs.iter().enumerate() {
        offsets.push(out.len());
        out.extend(format!("{} 0 obj\n", i + 1).as_bytes());
        out.extend(o);
        out.extend(b"\nendobj\n");
    }
    let xref = out.len();
    out.extend(format!("xref\n0 {}\n0000000000 65535 f \n", objs.len() + 1).as_bytes());
    for o in offsets {
        out.extend(format!("{o:010} 00000 n \n").as_bytes());
    }
    out.extend(format!("trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n", objs.len() + 1).as_bytes());
    out
}

pub fn obj(s: &str) -> Vec<u8> {
    s.as_bytes().to_vec()
}

/// A stream object: `dict` without `/Length`, the data Flate-compressed when `flate`.
pub fn stream(dict: &str, data: &[u8], flate: bool) -> Vec<u8> {
    let (data, filter) = if flate { (deflate::zlib(data, 6), " /Filter /FlateDecode") } else { (data.to_vec(), "") };
    let mut o = format!("<< {dict}{filter} /Length {} >>\nstream\n", data.len()).into_bytes();
    o.extend(&data);
    o.extend(b"\nendstream");
    o
}

/// Catalog, page tree and one page with `resources` and `content` (objects 1 to 4).
pub fn one_page(resources: &str, content: &[u8]) -> Vec<Vec<u8>> {
    vec![
        obj("<< /Type /Catalog /Pages 2 0 R >>"),
        obj("<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
        obj(&format!("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources {resources} /Contents 4 0 R >>")),
        stream("", content, true),
    ]
}

/// A gray image `w` x `h` with some detail, Flate-compressed.
pub fn gray_image(w: usize, h: usize) -> Vec<u8> {
    let px: Vec<u8> = (0..w * h).map(|i| ((i % w) * 255 / w.max(1)) as u8 ^ ((i / w) as u8 & 0x10)).collect();
    stream(
        &format!("/Type /XObject /Subtype /Image /Width {w} /Height {h} /ColorSpace /DeviceGray /BitsPerComponent 8"),
        &px,
        true,
    )
}

/// Runs `rewrite` with default settings on another thread; `None` when it outlives `limit`.
pub fn rewrite_within(pdf: Vec<u8>, dpi: Option<f64>, limit: Duration) -> Option<(Result<(Vec<u8>, bool)>, Duration)> {
    rewrite_with(pdf, Settings::new(30, dpi, false), limit)
}

pub fn rewrite_with(pdf: Vec<u8>, settings: Settings, limit: Duration) -> Option<(Result<(Vec<u8>, bool)>, Duration)> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let t = Instant::now();
        let r = rewrite(&pdf, &settings, &Ctx::silent());
        let _ = tx.send((r, t.elapsed()));
    });
    rx.recv_timeout(limit).ok()
}

#[test]
fn a_form_drawn_a_million_times_finishes() {
    let content = b"/F0 Do\n".repeat(1_000_000);
    let mut objs = one_page("<< /XObject << /F0 5 0 R >> >>", &content);
    objs.push(stream(
        "/Type /XObject /Subtype /Form /BBox [0 0 1 1] /Resources << /XObject << /Im0 6 0 R >> >>",
        b"q 1 0 0 1 0 0 cm /Im0 Do Q",
        true,
    ));
    objs.push(gray_image(64, 64));
    let (r, t) = rewrite_within(build(&objs), Some(150.0), Duration::from_secs(5)).expect("over 5 s");
    assert!(r.is_ok(), "{:?}", r.err());
    eprintln!("a million draws: {t:?}");
}

#[test]
fn forms_nested_ten_wide_twelve_deep_finish() {
    // Form k draws form k + 1 ten times; the last one draws an image: 10^12 draws in all.
    let mut objs = one_page("<< /XObject << /X 5 0 R >> >>", b"/X Do");
    let depth = 12;
    for k in 0..depth {
        let next = 5 + k + 1;
        let (res, body) = if k + 1 < depth {
            (format!("<< /XObject << /X {next} 0 R >> >>"), b"/X Do\n".repeat(10))
        } else {
            (format!("<< /XObject << /Im {next} 0 R >> >>"), b"/Im Do".to_vec())
        };
        objs.push(stream(&format!("/Type /XObject /Subtype /Form /BBox [0 0 1 1] /Resources {res}"), &body, true));
    }
    objs.push(gray_image(64, 64));
    let (r, t) = rewrite_within(build(&objs), Some(150.0), Duration::from_secs(5)).expect("over 5 s");
    assert!(r.is_ok(), "{:?}", r.err());
    eprintln!("10 x 12 nested forms: {t:?}");
}

fn resolutions(pdf: &[u8]) -> HashMap<ObjectId, placement::Placed> {
    let doc = Document::load_mem(pdf).unwrap();
    placement::image_resolutions(&doc, &std::sync::atomic::AtomicBool::new(false)).unwrap()
}

#[test]
fn a_form_places_its_images_at_their_drawn_size() {
    // A 144 px image, drawn 1 x 1 in a form scaled by 2 (its /Matrix), rotated 90 degrees and
    // scaled by 36 on the page: 72 pt wide, so 144 dpi; drawn again directly at 144 pt: 72 dpi.
    let mut objs = one_page(
        "<< /XObject << /F 5 0 R /Im 6 0 R >> >>",
        b"q 0 36 -36 0 0 0 cm /F Do Q q 144 0 0 144 0 0 cm /Im Do Q",
    );
    objs.push(stream(
        "/Type /XObject /Subtype /Form /BBox [0 0 1 1] /Matrix [2 0 0 2 0 0] /Resources << /XObject << /Im 6 0 R >> >>",
        b"/Im Do",
        true,
    ));
    objs.push(gray_image(144, 144));
    let r = resolutions(&build(&objs));
    assert!((r[&(6, 0)].dpi - 72.0).abs() < 1e-6, "{:?}", r);
    // Only through the form: 144 dpi.
    let mut objs = one_page("<< /XObject << /F 5 0 R >> >>", b"q 0 36 -36 0 0 0 cm /F Do Q");
    objs.push(stream(
        "/Type /XObject /Subtype /Form /BBox [0 0 1 1] /Matrix [2 0 0 2 0 0] /Resources << /XObject << /Im 6 0 R >> >>",
        b"/Im Do",
        true,
    ));
    objs.push(gray_image(144, 144));
    let r = resolutions(&build(&objs));
    assert!((r[&(6, 0)].dpi - 144.0).abs() < 1e-6, "{:?}", r);
}

#[test]
fn past_the_operator_cap_no_image_is_placed() {
    // A form placing 1000 images, drawn 100,000 times: 10^8 placements, over `MAX_OPS`.
    let images = 1000;
    let names: String = (0..images).map(|i| format!("/I{i} {} 0 R ", 6 + i)).collect();
    let body: String = (0..images).map(|i| format!("/I{i} Do\n")).collect();
    let mut objs = one_page("<< /XObject << /F 5 0 R >> >>", &b"/F Do\n".repeat(100_000));
    objs.push(stream(
        &format!("/Type /XObject /Subtype /Form /BBox [0 0 1 1] /Resources << /XObject << {names}>> >>"),
        body.as_bytes(),
        true,
    ));
    for _ in 0..images {
        objs.push(gray_image(2, 2));
    }
    let pdf = build(&objs);
    let t = Instant::now();
    assert!(resolutions(&pdf).is_empty());
    assert!(t.elapsed() < Duration::from_secs(5));
    // The file is still rewritten, its images at full size.
    let (r, _) = rewrite_within(pdf, Some(72.0), Duration::from_secs(20)).expect("over 20 s");
    assert!(r.is_ok(), "{:?}", r.err());
}

/// `n` small stream objects written without `endobj`, which lopdf reads all the same.
fn streams_without_endobj(n: usize) -> Vec<u8> {
    let mut out = b"%PDF-1.7\n".to_vec();
    let mut offsets = Vec::new();
    let mut add = |out: &mut Vec<u8>, body: &[u8], end: bool| {
        offsets.push(out.len());
        out.extend(format!("{} 0 obj\n", offsets.len()).as_bytes());
        out.extend(body);
        out.extend(if end { &b"\nendobj\n"[..] } else { b"\n" });
    };
    add(&mut out, b"<< /Type /Catalog /Pages 2 0 R >>", true);
    add(&mut out, b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>", true);
    add(&mut out, b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 10 10] >>", true);
    for _ in 0..n {
        add(&mut out, b"<< /Length 4 >>\nstream\nabcd\nendstream", false);
    }
    let xref = out.len();
    out.extend(format!("xref\n0 {}\n0000000000 65535 f \n", offsets.len() + 1).as_bytes());
    for o in &offsets {
        out.extend(format!("{o:010} 00000 n \n").as_bytes());
    }
    out.extend(
        format!("trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n", offsets.len() + 1).as_bytes(),
    );
    out
}

#[test]
fn the_integrity_check_is_linear() {
    let pdf = streams_without_endobj(100_000);
    let doc = Document::load_mem(&pdf).unwrap();
    assert!(doc.objects.len() > 100_000);
    let t = Instant::now();
    let r = integrity::check(&pdf, &doc, &std::sync::atomic::AtomicBool::new(false));
    assert!(t.elapsed() < Duration::from_secs(5), "{:?}", t.elapsed());
    assert!(r.is_ok(), "{r:?}");
}

#[test]
fn every_stage_stops_when_cancelled() {
    use std::sync::Arc;
    use std::sync::atomic::AtomicBool;
    let cancelled = || Arc::new(AtomicBool::new(true));
    let is_cancel = |r: &Result<_>| matches!(r, Err(e) if e.code == crate::error::ErrorCode::Cancelled);
    let pdf = streams_without_endobj(10_000);
    let doc = Document::load_mem(&pdf).unwrap();
    assert!(is_cancel(&integrity::check(&pdf, &doc, &cancelled()).map(|_| 0)));
    // Content with more than 4096 operators reaches the font walk's check.
    let mut objs = one_page("<< /XObject << /Im 5 0 R >> >>", &b"q 1 0 0 1 0 0 cm /Im Do Q\n".repeat(70_000));
    objs.push(gray_image(8, 8));
    let pdf = build(&objs);
    let mut doc = Document::load_mem(&pdf).unwrap();
    assert!(is_cancel(&fonts::subset_fonts(&mut doc, &cancelled(), &Arc::new(budget::Held::new(0)))));
    assert!(is_cancel(&inline::move_inline_images(&mut doc, &cancelled())));
    assert!(is_cancel(&placement::image_resolutions(&doc, &cancelled()).map(|_| 0)));
    let mut w = budget::CappedWriter::new(1 << 20, cancelled());
    assert!(std::io::Write::write_all(&mut w, b"x").is_err());
    let ctx = Ctx::new(cancelled(), Arc::new(|_, _| {}));
    assert!(is_cancel(&rewrite(&pdf, &Settings::new(30, None, false), &ctx).map(|_| 0)));
}

fn is_unsupported<T>(r: &Result<T>) -> bool {
    matches!(r, Err(e) if e.code == crate::error::ErrorCode::Unsupported)
}

#[test]
fn fonts_that_inflate_past_the_budget_are_refused() {
    // 100 TrueType fonts, each drawn, whose programs inflate to 200 MB of zeros.
    let n = 100;
    let zeros = deflate::zlib(&vec![0u8; 200 << 20], 9);
    let fonts: String = (0..n).map(|i| format!("/F{i} {} 0 R ", 5 + i)).collect();
    let content: String = (0..n).map(|i| format!("BT /F{i} 12 Tf (abc) Tj ET\n")).collect();
    let mut objs = one_page(&format!("<< /Font << {fonts}>> >>"), content.as_bytes());
    for i in 0..n {
        objs.push(obj(&format!(
            "<< /Type /Font /Subtype /TrueType /BaseFont /X{i} /FontDescriptor {} 0 R >>",
            5 + n + i
        )));
    }
    for i in 0..n {
        objs.push(obj(&format!(
            "<< /Type /FontDescriptor /FontName /X{i} /Flags 32 /FontBBox [0 0 1 1] /ItalicAngle 0 /Ascent 1 /Descent 0 /CapHeight 1 /StemV 1 /FontFile2 {} 0 R >>",
            5 + 2 * n + i
        )));
    }
    for _ in 0..n {
        let mut o = format!("<< /Filter /FlateDecode /Length {} >>\nstream\n", zeros.len()).into_bytes();
        o.extend(&zeros);
        o.extend(b"\nendstream");
        objs.push(o);
    }
    let (r, _) = rewrite_within(build(&objs), None, Duration::from_secs(30)).expect("over 30 s");
    assert!(is_unsupported(&r), "{:?}", r.map(|r| r.0.len()));
}

#[test]
fn object_streams_that_parse_past_the_budget_are_refused() {
    // 20 object streams of 15 MB, each one array of references (parsed, several times that).
    let body = format!("[{}]", "1 0 R ".repeat((15 << 20) / 6));
    let mut objs = one_page("<< >>", b"");
    for i in 0..20 {
        let head = format!("{} 0 ", 1000 + i);
        let data = format!("{head}{body}");
        objs.push(stream(&format!("/Type /ObjStm /N 1 /First {}", head.len()), data.as_bytes(), true));
    }
    let (r, _) = rewrite_within(build(&objs), None, Duration::from_secs(30)).expect("over 30 s");
    assert!(is_unsupported(&r), "{:?}", r.map(|r| r.0.len()));
    // One over `MAX_LOAD_STREAM` is refused before it is parsed.
    let body = format!("[{}]", "1 0 R ".repeat((40 << 20) / 6));
    let mut objs = one_page("<< >>", b"");
    objs.push(stream("/Type /ObjStm /N 1 /First 7", format!("1000 0 {body}").as_bytes(), true));
    let (r, _) = rewrite_within(build(&objs), None, Duration::from_secs(30)).expect("over 30 s");
    assert!(is_unsupported(&r), "{:?}", r.map(|r| r.0.len()));
}

/// A noisy RGB JPEG at quality `q`.
pub fn jpeg(w: u32, h: u32, q: u8) -> Vec<u8> {
    let img = image::RgbImage::from_fn(w, h, |x, y| {
        let n = (x.wrapping_mul(2654435761) ^ y.wrapping_mul(40503)) >> 7;
        image::Rgb([(x * 255 / w) as u8, (y * 255 / h) as u8, n as u8])
    });
    let mut out = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, q).encode_image(&img).unwrap();
    out
}

/// One page drawing one image (object 5) full width.
fn image_page(image: Vec<u8>) -> Vec<Vec<u8>> {
    let mut objs = one_page("<< /XObject << /Im 5 0 R >> >>", b"q 612 0 0 612 0 90 cm /Im Do Q");
    objs.push(image);
    objs
}

fn jpeg_image(jpg: &[u8], w: u32, h: u32, extra: &str) -> Vec<u8> {
    let mut o = format!(
        "<< /Type /XObject /Subtype /Image /Width {w} /Height {h} /ColorSpace /DeviceRGB /BitsPerComponent 8 {extra} /Filter /DCTDecode /Length {} >>\nstream\n",
        jpg.len()
    )
    .into_bytes();
    o.extend(jpg);
    o.extend(b"\nendstream");
    o
}

#[test]
fn an_impossible_bit_depth_keeps_the_image() {
    let jpg = jpeg(600, 600, 95);
    let mut o = format!(
        "<< /Type /XObject /Subtype /Image /Width 600 /Height 600 /ColorSpace /DeviceRGB /BitsPerComponent 4611686018427387904 /Filter /DCTDecode /Length {} >>\nstream\n",
        jpg.len()
    )
    .into_bytes();
    o.extend(&jpg);
    o.extend(b"\nendstream");
    let (r, _) = rewrite_within(build(&image_page(o)), Some(150.0), Duration::from_secs(20)).expect("over 20 s");
    let (_, lossy) = r.unwrap();
    assert!(!lossy, "an image with a crafted depth was re-encoded");
    // The same image at depth 8 is re-encoded.
    let (r, _) =
        rewrite_within(build(&image_page(jpeg_image(&jpg, 600, 600, ""))), Some(150.0), Duration::from_secs(20))
            .expect("over 20 s");
    assert!(r.unwrap().1);
}

#[test]
fn signed_and_reader_extended_pdfs_are_left_as_they_are() {
    let image = || jpeg_image(&jpeg(300, 300, 95), 300, 300, "");
    // A signature field whose value carries a /ByteRange.
    let mut signed = image_page(image());
    signed[0] = obj("<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [6 0 R] /SigFlags 3 >> >>");
    signed.push(obj("<< /FT /Sig /T (Sig1) /V 7 0 R /Type /Annot /Subtype /Widget /Rect [0 0 0 0] /P 3 0 R >>"));
    signed.push(obj("<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /ByteRange [0 100 200 300] /Contents <00> >>"));
    // DocMDP, and Reader usage rights (UR3), in the catalog's /Perms.
    let mut mdp = image_page(image());
    mdp[0] = obj("<< /Type /Catalog /Pages 2 0 R /Perms << /DocMDP 6 0 R >> >>");
    mdp.push(obj("<< /Type /Sig /Filter /Adobe.PPKLite /ByteRange [0 1 2 3] /Contents <00> >>"));
    let mut ur3 = image_page(image());
    ur3[0] = obj("<< /Type /Catalog /Pages 2 0 R /Perms << /UR3 6 0 R >> >>");
    ur3.push(obj("<< /Type /Sig /Filter /Adobe.PPKLite /ByteRange [0 1 2 3] /Contents <00> >>"));
    for (name, objs) in [("signature field", signed), ("DocMDP", mdp), ("UR3", ur3)] {
        let (r, _) = rewrite_within(build(&objs), Some(72.0), Duration::from_secs(20)).expect("over 20 s");
        match r {
            Err(e) => assert!(
                e.code == crate::error::ErrorCode::Unsupported && e.message.contains("signatures stay valid"),
                "{name}: {e:?}"
            ),
            Ok(_) => panic!("{name}: rewritten"),
        }
    }
    // An unsigned signature field (no value) is rewritten as usual.
    let mut empty = image_page(image());
    empty[0] = obj("<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [6 0 R] >> >>");
    empty.push(obj("<< /FT /Sig /T (Sig1) /Type /Annot /Subtype /Widget /Rect [0 0 0 0] /P 3 0 R >>"));
    let (r, _) = rewrite_within(build(&empty), Some(72.0), Duration::from_secs(20)).expect("over 20 s");
    assert!(r.is_ok(), "{r:?}");
}

/// The image streams of a rewritten file, by their `/Width`.
fn images_of(pdf: &[u8]) -> Vec<Stream> {
    let doc = Document::load_mem(pdf).unwrap();
    doc.objects
        .values()
        .filter_map(|o| o.as_stream().ok())
        .filter(|s| s.dict.get(b"Subtype").and_then(|t| t.as_name()).ok() == Some(b"Image"))
        .cloned()
        .collect()
}

#[test]
fn without_downsampling_a_jpeg_keeps_its_pixels() {
    let jpg = jpeg(600, 600, 95);
    let original = image::load_from_memory(&jpg).unwrap().to_rgb8();
    // No dpi (300 in the app): the JPEG is only re-coded losslessly.
    let (r, _) = rewrite_with(
        build(&image_page(jpeg_image(&jpg, 600, 600, ""))),
        Settings::new(64, None, false),
        Duration::from_secs(20),
    )
    .expect("over 20 s");
    let (out, lossy) = r.unwrap();
    assert!(!lossy);
    let im = &images_of(&out)[0];
    assert_eq!(image::load_from_memory(&im.content).unwrap().to_rgb8(), original);
    // Compression 0 (strip only): no image is touched, JPEG or Flate.
    let flate = gray_image(300, 300);
    let mut objs = one_page(
        "<< /XObject << /Im 5 0 R /G 6 0 R >> >>",
        b"q 300 0 0 300 0 0 cm /Im Do Q q 300 0 0 300 300 0 cm /G Do Q",
    );
    objs.push(jpeg_image(&jpg, 600, 600, ""));
    objs.push(flate.clone());
    let before = images_of(&build(&objs));
    let (r, _) = rewrite_with(build(&objs), Settings::new(0, None, true), Duration::from_secs(20)).expect("over 20 s");
    let (out, lossy) = r.unwrap();
    assert!(!lossy);
    let mut after: Vec<Vec<u8>> = images_of(&out).into_iter().map(|s| s.content).collect();
    let mut before: Vec<Vec<u8>> = before.into_iter().map(|s| s.content).collect();
    after.sort();
    before.sort();
    assert_eq!(after, before);
}

#[test]
fn a_small_image_keeps_the_floor() {
    // An image drawn over 4 % of the page may lose 25 times the page's share, but not below the
    // floor (0.5 before there was one).
    let mut objs = one_page("<< /XObject << /Im 5 0 R >> >>", b"q 139 0 0 139 0 0 cm /Im Do Q");
    objs.push(gray_image(64, 64));
    let placed = resolutions(&build(&objs))[&(5, 0)];
    assert!((placed.allowance - 612.0 * 792.0 / (139.0 * 139.0)).abs() < 1e-6, "{placed:?}");
    let default = Settings::new(30, Some(150.0), false);
    let aggressive = Settings::new(64, Some(150.0), false);
    assert_eq!(image_gate(default.min_ssim, default.image_floor, Some(placed.allowance)), 0.90);
    assert_eq!(image_gate(aggressive.min_ssim, aggressive.image_floor, Some(placed.allowance)), 0.85);
    // A page-wide image keeps the page gate; one over half the page, twice its loss.
    assert_eq!(image_gate(0.98, 0.90, Some(1.0)), 0.98);
    assert!((image_gate(0.98, 0.90, Some(2.0)) - 0.96).abs() < 1e-12);
}

/// Whether the glyph a character maps to in a TrueType program has an outline.
fn has_outline(program: &[u8], c: char) -> bool {
    use read_fonts::{FontRef, TableProvider};
    let f = FontRef::new(program).unwrap();
    let gid = f.cmap().unwrap().map_codepoint(c).unwrap();
    let loca = f.loca(None).unwrap();
    let glyf = f.glyf().unwrap();
    loca.get_glyf(gid, &glyf).unwrap().is_some()
}

#[test]
fn a_form_inherits_the_font_set_before_it_is_drawn() {
    let Ok(ttf) = std::fs::read("/System/Library/Fonts/Supplemental/Andale Mono.ttf") else { return };
    let mut objs =
        one_page("<< /Font << /F1 5 0 R >> /XObject << /Fm 7 0 R >> >>", b"BT /F1 9 Tf 10 10 Td (A) Tj ET /Fm Do");
    objs.push(obj(
        "<< /Type /Font /Subtype /TrueType /BaseFont /AndaleMono /Encoding /WinAnsiEncoding /FontDescriptor 6 0 R >>",
    ));
    objs.push(obj("<< /Type /FontDescriptor /FontName /AndaleMono /Flags 32 /FontBBox [0 0 1000 1000] /ItalicAngle 0 /Ascent 900 /Descent -200 /CapHeight 700 /StemV 80 /FontFile2 8 0 R >>"));
    // The form shows text without a Tf of its own: it draws with /F1.
    objs.push(stream("/Type /XObject /Subtype /Form /BBox [0 0 612 792]", b"BT 10 40 Td (xyz) Tj ET", true));
    objs.push(stream(&format!("/Length1 {}", ttf.len()), &ttf, true));
    let mut doc = Document::load_mem(&build(&objs)).unwrap();
    let held = std::sync::Arc::new(budget::Held::new(0));
    assert_eq!(fonts::subset_fonts(&mut doc, &Ctx::silent().cancel_flag(), &held).unwrap(), 1);
    let program = doc.get_object((8, 0)).unwrap().as_stream().unwrap().decompressed_content().unwrap();
    for c in ['A', 'x', 'y', 'z'] {
        assert!(has_outline(&program, c), "{c} lost its outline");
    }
    assert!(!has_outline(&program, 'q'), "the font was not subset");
}

#[test]
fn an_image_also_drawn_outside_page_content_keeps_its_size() {
    // The page draws the image small; an annotation's appearance, a tiling pattern, a soft mask
    // group or a Type 3 glyph draws it too, at a size the walk does not see.
    let page = |resources: &str, extra: &str| {
        vec![
            obj("<< /Type /Catalog /Pages 2 0 R >>"),
            obj("<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            obj(&format!(
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources {resources} /Contents 4 0 R {extra} >>"
            )),
            stream("", b"q 50 0 0 50 0 0 cm /Im Do Q", true),
            gray_image(600, 600),
            stream(
                "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources << /XObject << /Im 5 0 R >> >>",
                b"q 600 0 0 600 0 0 cm /Im Do Q",
                true,
            ),
        ]
    };
    let cases = [
        (
            "annotation",
            page(
                "<< /XObject << /Im 5 0 R >> >>",
                "/Annots [<< /Type /Annot /Subtype /Stamp /Rect [0 0 600 600] /AP << /N 6 0 R >> >>]",
            ),
        ),
        ("pattern", page("<< /XObject << /Im 5 0 R >> /Pattern << /P 7 0 R >> >>", "")),
        (
            "soft mask",
            page("<< /XObject << /Im 5 0 R >> /ExtGState << /G << /SMask << /S /Luminosity /G 6 0 R >> >> >> >>", ""),
        ),
    ];
    for (name, mut objs) in cases {
        objs.push(stream("/PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 600 600] /XStep 600 /YStep 600 /Resources << /XObject << /Im 5 0 R >> >>", b"q 600 0 0 600 0 0 cm /Im Do Q", true));
        assert!(!resolutions(&build(&objs)).contains_key(&(5, 0)), "{name}: the image would be downsampled");
    }
    // Drawn by page content only, it is placed.
    let objs = page("<< /XObject << /Im 5 0 R >> >>", "");
    assert!(resolutions(&build(&objs)).contains_key(&(5, 0)));
}

#[test]
fn an_image_with_a_matte_soft_mask_keeps_the_mask_size() {
    // Drawn at 150 pt, 600 px is 288 dpi: downsampled at 72 dpi, unless its soft mask has /Matte
    // (pre-multiplied colour: image and mask must keep the same size).
    for (matte, keeps) in [("/Matte [0]", true), ("", false)] {
        let mut objs = one_page("<< /XObject << /Im 5 0 R >> >>", b"q 150 0 0 150 0 0 cm /Im Do Q");
        let mut im = gray_image(600, 600);
        let at = im.windows(2).position(|w| w == b"<<").unwrap() + 2;
        im.splice(at..at, b" /SMask 6 0 R".iter().copied());
        objs.push(im);
        let mut mask = gray_image(600, 600);
        mask.splice(at..at, format!(" {matte}").bytes());
        objs.push(mask);
        let (r, _) = rewrite_with(build(&objs), Settings::new(30, Some(72.0), false), Duration::from_secs(20))
            .expect("over 20 s");
        let out = r.unwrap().0;
        let widths: Vec<i64> =
            images_of(&out).iter().map(|s| s.dict.get(b"Width").unwrap().as_i64().unwrap()).collect();
        assert_eq!(widths.iter().all(|w| *w == 600), keeps, "{matte:?}: {widths:?}");
    }
}
