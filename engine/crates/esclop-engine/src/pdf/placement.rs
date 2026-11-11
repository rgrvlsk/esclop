// SPDX-License-Identifier: GPL-3.0-or-later
//! How large each image is drawn: walks every page's content (and the form XObjects it draws)
//! tracking the transformation matrix, and records each image's lowest effective resolution
//! over all the places it is painted, and how much of the page its page's images cover. Each
//! form is walked once and its images placed through a summary on every draw (see `Walker`). An
//! image that is never found this way (only in a pattern, an annotation appearance or a soft
//! mask) gets no entry and is never downsampled.

use crate::error::{EngineError, Result};
use lopdf::content::Content;
use lopdf::{Dictionary, Document, Object, ObjectId, Stream};
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};

type Matrix = [f64; 6];
const IDENTITY: Matrix = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0];
const MAX_DEPTH: usize = 12;
/// Largest decoded page content (all its streams joined) or form walked: lopdf's operator list
/// takes about fifteen times the bytes (28.8 MB of content on one page took the engine to 590
/// MB, pdf.js issue21089). Pages are not walked stream by stream: an operator may span two of a
/// page's streams (pdf.js issue2856 splits a `TJ`), and a stream parsed alone loses it.
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

/// Operators walked per document, form draws counted once per image they place. Past it no
/// image is downsampled.
pub const MAX_OPS: usize = 20_000_000;

/// How one stream draws an image, in that stream's space: the longest the image's two sides
/// get (points, over all its draws) and the area all its draws cover.
#[derive(Debug, Clone, Copy, Default)]
struct Use {
    w: f64,
    h: f64,
    area: f64,
}

type Uses = HashMap<ObjectId, Use>;

/// Every image drawn by page content, keyed by the image's object id.
/// When some content cannot be walked within `MAX_CONTENT`, or the document needs more than
/// `MAX_OPS`, the map is empty: a draw left unseen could be larger than the ones found, so no
/// image is downsampled. `Err` only when cancelled.
pub fn image_resolutions(doc: &Document, cancel: &AtomicBool) -> Result<HashMap<ObjectId, Placed>> {
    let mut walker = Walker { doc, memo: HashMap::new(), stack: Vec::new(), ops: 0, cancel, stop: None };
    let mut dpi: HashMap<ObjectId, f64> = HashMap::new();
    let mut allowance: HashMap<ObjectId, f64> = HashMap::new();
    for page in doc.page_iter() {
        let resources = page_resources(doc, page);
        // The page's streams joined, as viewers read them: an operator may span two streams.
        let Ok(content) = doc.get_page_content_with_limit(page, MAX_CONTENT) else { return Ok(HashMap::new()) };
        let uses = walker.walk(&content, resources.as_ref(), 0);
        let uses = match (uses, walker.stop) {
            (_, Some(Stop::Cancelled)) => return Err(EngineError::cancelled()),
            (Some(u), None) => u,
            _ => return Ok(HashMap::new()),
        };
        let covered: f64 = uses.values().map(|u| u.area).sum();
        let factor = page_area(doc, page).map_or(1.0, |p| (p / covered.max(1e-6)).max(1.0));
        for (id, u) in uses {
            let Some(d) = resolution(doc, id, &u) else { continue };
            let e = dpi.entry(id).or_insert(f64::INFINITY);
            *e = e.min(d);
            let e = allowance.entry(id).or_insert(f64::INFINITY);
            *e = e.min(factor);
        }
    }
    Ok(dpi
        .into_iter()
        .map(|(id, d)| (id, Placed { dpi: d, allowance: allowance.get(&id).copied().unwrap_or(1.0).min(1e3) }))
        .collect())
}

/// The image's resolution at its largest draw: pixels per inch along its less dense side.
fn resolution(doc: &Document, id: ObjectId, u: &Use) -> Option<f64> {
    let d = doc.get_object(id).ok()?.as_stream().ok().map(|s| &s.dict)?;
    let (w, h) = (d.get(b"Width").and_then(|o| o.as_i64()).ok()?, d.get(b"Height").and_then(|o| o.as_i64()).ok()?);
    if u.w < 1e-3 || u.h < 1e-3 {
        return None;
    }
    Some((w as f64 / (u.w / 72.0)).min(h as f64 / (u.h / 72.0)))
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

/// The largest factor a matrix stretches any length by (its larger singular value).
fn stretch(m: &Matrix) -> f64 {
    let s = m[0] * m[0] + m[1] * m[1] + m[2] * m[2] + m[3] * m[3];
    let det = m[0] * m[3] - m[1] * m[2];
    ((s + (s * s - 4.0 * det * det).max(0.0).sqrt()) / 2.0).sqrt()
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Stop {
    Cancelled,
    /// Unreadable content, too deep, or past `MAX_OPS`.
    Failed,
}

/// Walks content streams. A form is walked once per resource dictionary it is drawn with; each
/// draw places its images through the form's summary (`Uses` in form space), the sides
/// stretched by the draw's matrix. Exact when that matrix scales evenly (with any rotation or
/// flip), and never smaller than the true size otherwise.
struct Walker<'a> {
    doc: &'a Document,
    memo: HashMap<(ObjectId, usize), Rc<Uses>>,
    stack: Vec<ObjectId>,
    ops: usize,
    cancel: &'a AtomicBool,
    stop: Option<Stop>,
}

impl<'a> Walker<'a> {
    /// The images one content stream draws, in its own space; `None` once `stop` is set.
    fn walk(&mut self, content: &[u8], resources: Option<&Dictionary>, depth: usize) -> Option<Uses> {
        if depth > MAX_DEPTH {
            self.stop = Some(Stop::Failed);
            return None;
        }
        let Ok(ops) = Content::decode(content) else {
            self.stop = Some(Stop::Failed);
            return None;
        };
        let doc = self.doc;
        let xobjects = resources.and_then(|r| r.get(b"XObject").ok()).and_then(|x| dict(doc, x));
        let mut uses = Uses::new();
        let mut ctm = IDENTITY;
        let mut saved: Vec<Matrix> = Vec::new();
        for op in &ops.operations {
            if !self.count(1) {
                return None;
            }
            match op.operator.as_str() {
                "q" => saved.push(ctm),
                "Q" => ctm = saved.pop().unwrap_or(IDENTITY),
                "cm" => {
                    if let Some(m) = matrix(&op.operands) {
                        ctm = mul(&m, &ctm);
                    }
                }
                "Do" => {
                    let Some(name) = op.operands.first().and_then(|o| o.as_name().ok()) else { continue };
                    let Some(Ok(id)) = xobjects.and_then(|x| x.get(name).ok()).map(|o| o.as_reference()) else {
                        continue;
                    };
                    let Ok(stream) = doc.get_object(id).and_then(|o| o.as_stream()) else { continue };
                    match stream.dict.get(b"Subtype").and_then(|s| s.as_name()) {
                        Ok(b"Image") => {
                            let u = uses.entry(id).or_default();
                            u.w = u.w.max(ctm[0].hypot(ctm[1]));
                            u.h = u.h.max(ctm[2].hypot(ctm[3]));
                            u.area += (ctm[0] * ctm[3] - ctm[1] * ctm[2]).abs();
                        }
                        Ok(b"Form") if !self.stack.contains(&id) => {
                            let m =
                                stream.dict.get(b"Matrix").ok().and_then(|m| m.as_array().ok()).and_then(|a| matrix(a));
                            let local = mul(&m.unwrap_or(IDENTITY), &ctm);
                            let res = stream.dict.get(b"Resources").ok().and_then(|r| dict(doc, r)).or(resources);
                            let inner = self.form(id, stream, res, depth)?;
                            if !self.count(inner.len()) {
                                return None;
                            }
                            let (k, det) = (stretch(&local), (local[0] * local[3] - local[1] * local[2]).abs());
                            for (img, v) in inner.iter() {
                                let u = uses.entry(*img).or_default();
                                u.w = u.w.max(v.w * k);
                                u.h = u.h.max(v.h * k);
                                u.area += v.area * det;
                            }
                        }
                        _ => {}
                    }
                }
                _ => {}
            }
        }
        Some(uses)
    }

    /// A form's summary, walked on its first draw with these resources.
    fn form(&mut self, id: ObjectId, stream: &Stream, res: Option<&Dictionary>, depth: usize) -> Option<Rc<Uses>> {
        let key = (id, res.map_or(0, |r| std::ptr::from_ref(r) as usize));
        if let Some(u) = self.memo.get(&key) {
            return Some(u.clone());
        }
        let Ok(data) = stream.decompressed_content_with_limit(MAX_CONTENT) else {
            self.stop = Some(Stop::Failed);
            return None;
        };
        self.stack.push(id);
        let uses = self.walk(&data, res, depth + 1);
        self.stack.pop();
        let uses = Rc::new(uses?);
        self.memo.insert(key, uses.clone());
        Some(uses)
    }

    /// Counts `n` more operators; false (with `stop` set) past `MAX_OPS` or once cancelled.
    fn count(&mut self, n: usize) -> bool {
        self.ops += n;
        if self.ops > MAX_OPS {
            self.stop = Some(Stop::Failed);
        } else if self.ops & 0xffff < n.min(0x10000) && self.cancel.load(Ordering::Relaxed) {
            self.stop = Some(Stop::Cancelled);
        }
        self.stop.is_none()
    }
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
