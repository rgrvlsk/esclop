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
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let t = Instant::now();
        let r = rewrite(&pdf, dpi, 66, 0.98, false, &Ctx::silent());
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
    assert!(is_cancel(&rewrite(&pdf, None, 66, 0.98, false, &ctx).map(|_| 0)));
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
