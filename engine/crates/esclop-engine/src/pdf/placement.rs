// SPDX-License-Identifier: GPL-3.0-or-later
//! How large each image is drawn: walks every page's content (and the form XObjects it draws)
//! tracking the transformation matrix, and records each image's lowest effective resolution
//! over all the places it is painted. An image that is never found this way (only in a pattern,
//! an annotation appearance or a soft mask) gets no entry and is never downsampled.

use lopdf::content::Content;
use lopdf::{Dictionary, Document, Object, ObjectId};
use std::collections::HashMap;

type Matrix = [f64; 6];
const IDENTITY: Matrix = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0];
const MAX_DEPTH: usize = 12;

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

/// Lowest effective resolution (pixels per inch along the image's less dense axis) of every
/// image drawn by page content, keyed by the image's object id.
pub fn image_resolutions(doc: &Document) -> HashMap<ObjectId, f64> {
    let mut out = HashMap::new();
    for page in doc.page_iter() {
        let Ok(content) = doc.get_page_content_with_limit(page, 256 << 20) else { continue };
        let resources = page_resources(doc, page);
        walk(doc, &content, resources.as_ref(), IDENTITY, 0, &mut Vec::new(), &mut out);
    }
    out
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

fn walk(
    doc: &Document,
    content: &[u8],
    resources: Option<&Dictionary>,
    base: Matrix,
    depth: usize,
    stack: &mut Vec<ObjectId>,
    out: &mut HashMap<ObjectId, f64>,
) {
    if depth > MAX_DEPTH {
        return;
    }
    let Ok(ops) = Content::decode(content) else { return };
    let xobjects = resources.and_then(|r| r.get(b"XObject").ok()).and_then(|x| dict(doc, x));
    let mut ctm = base;
    let mut saved: Vec<Matrix> = Vec::new();
    for op in &ops.operations {
        match op.operator.as_str() {
            "q" => saved.push(ctm),
            "Q" => ctm = saved.pop().unwrap_or(base),
            "cm" => {
                if let Some(m) = matrix(&op.operands) {
                    ctm = mul(&m, &ctm);
                }
            }
            "Do" => {
                let Some(name) = op.operands.first().and_then(|o| o.as_name().ok()) else { continue };
                let Some(Ok(id)) = xobjects.and_then(|x| x.get(name).ok()).map(|o| o.as_reference()) else { continue };
                let Ok(stream) = doc.get_object(id).and_then(|o| o.as_stream()) else { continue };
                match stream.dict.get(b"Subtype").and_then(|s| s.as_name()) {
                    Ok(b"Image") => record(&stream.dict, id, &ctm, out),
                    Ok(b"Form") if !stack.contains(&id) => {
                        let m = stream.dict.get(b"Matrix").ok().and_then(|m| m.as_array().ok()).and_then(|a| matrix(a));
                        let local = mul(&m.unwrap_or(IDENTITY), &ctm);
                        let res = stream.dict.get(b"Resources").ok().and_then(|r| dict(doc, r)).or(resources);
                        let Ok(data) = stream.decompressed_content_with_limit(256 << 20) else { continue };
                        stack.push(id);
                        walk(doc, &data, res, local, depth + 1, stack, out);
                        stack.pop();
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }
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
