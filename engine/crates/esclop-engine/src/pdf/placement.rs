// SPDX-License-Identifier: GPL-3.0-or-later
//! How large each image is drawn: walks every page's content (and the form XObjects it draws)
//! tracking the transformation matrix, and records each image's lowest effective resolution
//! over all the places it is painted, and how much of the page its page's images cover. An
//! image that is never found this way (only in a pattern, an annotation appearance or a soft
//! mask) gets no entry and is never downsampled.

use lopdf::content::Content;
use lopdf::{Dictionary, Document, Object, ObjectId};
use std::collections::HashMap;

type Matrix = [f64; 6];
const IDENTITY: Matrix = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0];
const MAX_DEPTH: usize = 12;
/// Largest decoded content stream walked: lopdf's operator list takes about fifteen times the
/// bytes (28.8 MB of content on one page took the engine to 590 MB, pdf.js issue21089). Pages
/// are walked stream by stream; a stream over this leaves the walk incomplete.
pub const MAX_CONTENT: usize = 8 << 20;

fn mul(m: &Matrix, n: &Matrix) -> Matrix {
    [
        m[0] * n[0] + m[1] * n[2],
        m[0] * n[1] + m[1] * n[3],
        m[2] * n[0] + m[3] * n[2],
        m[2] * n[1] + m[3] * n[3],
        m[4] * n[0] + m[5] * n[2] + n[4],
        m[4] * n[1] + m[5] * n[3] + n[5],
    ]
}

fn number(o: &Object) -> Option<f64> {
    o.as_float().ok().map(|v| v as f64)
}

fn matrix(o: &[Object]) -> Option<Matrix> {
    if o.len() != 6 {
        return None;
    }
    let mut m = [0.0; 6];
    for (i, v) in o.iter().enumerate() {
        m[i] = number(v)?;
    }
    Some(m)
}

fn dict<'a>(doc: &'a Document, o: &'a Object) -> Option<&'a Dictionary> {
    match o {
        Object::Reference(id) => doc.get_object(*id).ok().and_then(|o| dict(doc, o)),
        Object::Dictionary(d) => Some(d),
        Object::Stream(s) => Some(&s.dict),
        _ => None,
    }
}

/// Where an image is drawn.
#[derive(Debug, Clone, Copy)]
pub struct Placed {
    /// Lowest effective resolution, pixels per inch along the image's less dense axis.
    pub dpi: f64,
    /// Page area over the area all images on the page are drawn at, on the page where that is
    /// smallest, and at least 1: how much of a page-wide SSIM loss this image's own SSIM may
    /// show (page SSIM is a mean over the page; areas without images keep it at 1).
    pub allowance: f64,
}

/// Every image drawn by page content, keyed by the image's object id.
/// When some content cannot be walked within `MAX_CONTENT`, the map is empty: a draw left
/// unseen could be larger than the ones found, so no image is downsampled.
pub fn image_resolutions(doc: &Document) -> HashMap<ObjectId, Placed> {
    let mut dpi = HashMap::new();
    let mut allowance: HashMap<ObjectId, f64> = HashMap::new();
    for page in doc.page_iter() {
        let resources = page_resources(doc, page);
        let mut draws = Vec::new();
        let mut gs = State { ctm: IDENTITY, saved: Vec::new() };
        for id in doc.get_page_contents(page) {
            let Ok(s) = doc.get_object(id).and_then(|o| o.as_stream()) else { return HashMap::new() };
            let Ok(data) = s.decompressed_content_with_limit(MAX_CONTENT) else { return HashMap::new() };
            if !walk(doc, &data, resources.as_ref(), &mut gs, 0, &mut Vec::new(), &mut dpi, &mut draws) {
                return HashMap::new();
            }
        }
        let covered: f64 = draws.iter().map(|(_, a)| a).sum();
        let factor = page_area(doc, page).map_or(1.0, |p| (p / covered.max(1e-6)).max(1.0));
        for (id, _) in draws {
            let e = allowance.entry(id).or_insert(f64::INFINITY);
            *e = e.min(factor);
        }
    }
    dpi.into_iter()
        .map(|(id, d)| (id, Placed { dpi: d, allowance: allowance.get(&id).copied().unwrap_or(1.0).min(1e3) }))
        .collect()
}

/// The page's crop box (or media box) area, in square points, inherited through the page tree.
fn page_area(doc: &Document, page: ObjectId) -> Option<f64> {
    let mut node = doc.get_dictionary(page).ok()?;
    for _ in 0..64 {
        for key in [&b"CropBox"[..], b"MediaBox"] {
            if let Some(Object::Array(a)) = node.get(key).ok().map(|o| match o {
                Object::Reference(r) => doc.get_object(*r).unwrap_or(o),
                o => o,
            }) && a.len() == 4
            {
                let v: Vec<f64> = a.iter().filter_map(number).collect();
                if v.len() == 4 {
                    return Some(((v[2] - v[0]) * (v[3] - v[1])).abs());
                }
            }
        }
        node = doc.get_dictionary(node.get(b"Parent").ok()?.as_reference().ok()?).ok()?;
    }
    None
}

/// The page's resource dictionary, inherited through the page tree when the page has none.
fn page_resources(doc: &Document, page: ObjectId) -> Option<Dictionary> {
    let mut node = doc.get_dictionary(page).ok()?;
    for _ in 0..64 {
        if let Ok(r) = node.get(b"Resources")
            && let Some(d) = dict(doc, r)
        {
            return Some(d.clone());
        }
        node = doc.get_dictionary(node.get(b"Parent").ok()?.as_reference().ok()?).ok()?;
    }
    None
}

/// The graphics state the walk tracks, carried from one content stream of a page to the next.
struct State {
    ctm: Matrix,
    saved: Vec<Matrix>,
}

/// Walks one content stream; false when it, or a form it draws, cannot be read.
#[allow(clippy::too_many_arguments)]
fn walk(
    doc: &Document,
    content: &[u8],
    resources: Option<&Dictionary>,
    gs: &mut State,
    depth: usize,
    stack: &mut Vec<ObjectId>,
    out: &mut HashMap<ObjectId, f64>,
    draws: &mut Vec<(ObjectId, f64)>,
) -> bool {
    if depth > MAX_DEPTH {
        return false;
    }
    let Ok(ops) = Content::decode(content) else { return false };
    let xobjects = resources.and_then(|r| r.get(b"XObject").ok()).and_then(|x| dict(doc, x));
    let base = gs.ctm;
    for op in &ops.operations {
        let ctm = gs.ctm;
        match op.operator.as_str() {
            "q" => gs.saved.push(ctm),
            "Q" => gs.ctm = gs.saved.pop().unwrap_or(base),
            "cm" => {
                if let Some(m) = matrix(&op.operands) {
                    gs.ctm = mul(&m, &ctm);
                }
            }
            "Do" => {
                let Some(name) = op.operands.first().and_then(|o| o.as_name().ok()) else { continue };
                let Some(Ok(id)) = xobjects.and_then(|x| x.get(name).ok()).map(|o| o.as_reference()) else { continue };
                let Ok(stream) = doc.get_object(id).and_then(|o| o.as_stream()) else { continue };
                match stream.dict.get(b"Subtype").and_then(|s| s.as_name()) {
                    Ok(b"Image") => {
                        record(&stream.dict, id, &ctm, out);
                        draws.push((id, (ctm[0] * ctm[3] - ctm[1] * ctm[2]).abs()));
                    }
                    Ok(b"Form") if !stack.contains(&id) => {
                        let m = stream.dict.get(b"Matrix").ok().and_then(|m| m.as_array().ok()).and_then(|a| matrix(a));
                        let local = mul(&m.unwrap_or(IDENTITY), &ctm);
                        let res = stream.dict.get(b"Resources").ok().and_then(|r| dict(doc, r)).or(resources);
                        let Ok(data) = stream.decompressed_content_with_limit(MAX_CONTENT) else { return false };
                        stack.push(id);
                        let mut inner = State { ctm: local, saved: Vec::new() };
                        let ok = walk(doc, &data, res, &mut inner, depth + 1, stack, out, draws);
                        stack.pop();
                        if !ok {
                            return false;
                        }
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }
    true
}

fn record(d: &Dictionary, id: ObjectId, ctm: &Matrix, out: &mut HashMap<ObjectId, f64>) {
    let (Ok(w), Ok(h)) = (d.get(b"Width").and_then(|o| o.as_i64()), d.get(b"Height").and_then(|o| o.as_i64())) else {
        return;
    };
    // The image fills the unit square; its sides end up this long, in points.
    let wp = ctm[0].hypot(ctm[1]);
    let hp = ctm[2].hypot(ctm[3]);
    if wp < 1e-3 || hp < 1e-3 {
        return;
    }
    let dpi = (w as f64 / (wp / 72.0)).min(h as f64 / (hp / 72.0));
    let e = out.entry(id).or_insert(f64::INFINITY);
    *e = e.min(dpi);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matrices_compose_like_pdf() {
        // scale then translate: a point (1,1) goes to (2+5, 3+7)
        let m = mul(&[2.0, 0.0, 0.0, 3.0, 0.0, 0.0], &[1.0, 0.0, 0.0, 1.0, 5.0, 7.0]);
        assert_eq!(m, [2.0, 0.0, 0.0, 3.0, 5.0, 7.0]);
    }
}
