// SPDX-License-Identifier: GPL-3.0-or-later
//! Large inline images (`BI … ID … EI` in page content) moved into image XObjects, so they are
//! downsampled and recompressed like any other image.
//!
//! An inline image and an image XObject are both drawn into the unit square under the current
//! matrix, so `BI … EI` and `/Name Do` paint the same thing. The content bytes are edited in
//! place, never re-serialised (lopdf keeps numbers as f32): the inline image's byte range is
//! found around its data and replaced by `/EsclopImN Do`. The edited stream must parse to the
//! old operator sequence with each moved `BI` now a `Do`, and keep its text operators; else
//! the stream stays as it was. Only page content streams are edited (their resources can be
//! given the new names), inline images under `MIN_BYTES` stay inline, and so does any whose
//! keys or colour space are not ones this module expands.

use super::placement::MAX_CONTENT;
use crate::error::{EngineError, Result};
use lopdf::content::Content;
use lopdf::{Dictionary, Document, Object, ObjectId, Stream};
use std::sync::atomic::{AtomicBool, Ordering};

const MIN_BYTES: usize = 4096;
/// Largest content stream this pass decodes, and the most memory its operator list may take,
/// estimated at 100 bytes a token: content made mostly of inline image data has few tokens for
/// its size (pdf.js bug1077808: 8.75 MB in 31 images), plain drawing content many.
const MAX_STREAM: usize = 64 << 20;
const MAX_OPERATOR_MEMORY: usize = 128 << 20;

/// Whitespace-separated tokens in `data` (an upper bound on what lopdf's parse allocates).
fn tokens(data: &[u8]) -> usize {
    let mut n = 0;
    let mut inside = false;
    for &b in data {
        let space = is_space(b);
        if !space && !inside {
            n += 1;
        }
        inside = !space;
    }
    n
}

fn expand_key(k: &[u8]) -> Option<&'static [u8]> {
    Some(match k {
        b"BPC" | b"BitsPerComponent" => b"BitsPerComponent",
        b"CS" | b"ColorSpace" => b"ColorSpace",
        b"D" | b"Decode" => b"Decode",
        b"DP" | b"DecodeParms" => b"DecodeParms",
        b"F" | b"Filter" => b"Filter",
        b"H" | b"Height" => b"Height",
        b"W" | b"Width" => b"Width",
        b"IM" | b"ImageMask" => b"ImageMask",
        b"I" | b"Interpolate" => b"Interpolate",
        b"Intent" => b"Intent",
        _ => return None,
    })
}

fn expand_filter(o: &Object) -> Option<Object> {
    let name = |n: &[u8]| -> Option<Object> {
        Some(Object::Name(
            match n {
                b"AHx" | b"ASCIIHexDecode" => &b"ASCIIHexDecode"[..],
                b"A85" | b"ASCII85Decode" => b"ASCII85Decode",
                b"LZW" | b"LZWDecode" => b"LZWDecode",
                b"Fl" | b"FlateDecode" => b"FlateDecode",
                b"RL" | b"RunLengthDecode" => b"RunLengthDecode",
                b"CCF" | b"CCITTFaxDecode" => b"CCITTFaxDecode",
                b"DCT" | b"DCTDecode" => b"DCTDecode",
                _ => return None,
            }
            .to_vec(),
        ))
    };
    match o {
        Object::Name(n) => name(n),
        Object::Array(a) => {
            a.iter().map(|x| x.as_name().ok().and_then(name)).collect::<Option<Vec<_>>>().map(Object::Array)
        }
        _ => None,
    }
}

/// The colour space value of an image XObject for an inline image's `CS`: device spaces by
/// their full names, other names through the page's `/ColorSpace` resources.
fn expand_space(o: &Object, spaces: Option<&Dictionary>) -> Option<Object> {
    match o {
        Object::Name(n) => match n.as_slice() {
            b"G" | b"DeviceGray" => Some(Object::Name(b"DeviceGray".to_vec())),
            b"RGB" | b"DeviceRGB" => Some(Object::Name(b"DeviceRGB".to_vec())),
            b"CMYK" | b"DeviceCMYK" => Some(Object::Name(b"DeviceCMYK".to_vec())),
            other => spaces?.get(other).ok().cloned(),
        },
        // [/I base hival lookup]: Indexed over a device or named base.
        Object::Array(a) if a.len() == 4 && matches!(a[0].as_name(), Ok(b"I" | b"Indexed")) => {
            let base = expand_space(&a[1], spaces)?;
            Some(Object::Array(vec![Object::Name(b"Indexed".to_vec()), base, a[2].clone(), a[3].clone()]))
        }
        _ => None,
    }
}

/// The image XObject for an inline image's dictionary and data.
fn xobject(image: &Stream, spaces: Option<&Dictionary>) -> Option<Stream> {
    let mut d = Dictionary::new();
    d.set("Type", Object::Name(b"XObject".to_vec()));
    d.set("Subtype", Object::Name(b"Image".to_vec()));
    for (k, v) in image.dict.iter() {
        // The stream's length is the new stream's own.
        if matches!(k.as_slice(), b"Length" | b"L") {
            continue;
        }
        let key = expand_key(k)?;
        let value = match key {
            b"ColorSpace" => expand_space(v, spaces)?,
            b"Filter" => expand_filter(v)?,
            _ => v.clone(),
        };
        d.set(key.to_vec(), value);
    }
    if !d.has(b"Width") || !d.has(b"Height") {
        return None;
    }
    Some(Stream::new(d, image.content.clone()))
}

fn find(hay: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    if needle.is_empty() || from > hay.len() {
        return None;
    }
    hay[from..].windows(needle.len()).position(|w| w == needle).map(|p| p + from)
}

fn is_space(b: u8) -> bool {
    matches!(b, b' ' | b'\n' | b'\r' | b'\t' | b'\x0c' | 0)
}

/// The byte range of the `BI … EI` whose data is `data`, searching from `from`.
fn locate(content: &[u8], data: &[u8], from: usize) -> Option<(usize, usize)> {
    let at = find(content, data, from)?;
    // Back to the `BI` that opens it: the last `BI` token before the data.
    let bi = (from..at).rev().find(|&i| {
        content.get(i..i + 2) == Some(b"BI")
            && (i == 0 || is_space(content[i - 1]))
            && content.get(i + 2).is_some_and(|b| is_space(*b) || *b == b'/')
    })?;
    // Forward past the data to `EI`.
    let mut e = at + data.len();
    while content.get(e).is_some_and(|b| is_space(*b)) {
        e += 1;
    }
    (content.get(e..e + 2) == Some(b"EI") && content.get(e + 2).is_none_or(|b| is_space(*b))).then_some((bi, e + 2))
}

/// An inline image lopdf could not read (an ASCII85 or ASCIIHex first filter, which it does
/// not end), read from the raw bytes after `from`: its `BI … EI` range and the image. Only
/// those two filters are taken, because their data has an unambiguous end (`~>`, `>`).
fn raw_inline(content: &[u8], from: usize) -> Option<(usize, usize, Stream)> {
    let bi = (from..content.len().saturating_sub(2)).find(|&i| {
        &content[i..i + 2] == b"BI"
            && (i == 0 || is_space(content[i - 1]))
            && content.get(i + 2).is_some_and(|b| is_space(*b) || *b == b'/')
    })?;
    let id = (bi + 2..content.len().saturating_sub(2)).find(|&i| {
        &content[i..i + 2] == b"ID" && is_space(content[i - 1]) && content.get(i + 2).is_some_and(|b| is_space(*b))
    })?;
    let mut text = b"<<".to_vec();
    text.extend_from_slice(&content[bi + 2..id]);
    text.extend_from_slice(b">> x");
    let dict = match Content::decode(&text).ok()?.operations.first()?.operands.first()? {
        Object::Dictionary(d) => d.clone(),
        _ => return None,
    };
    let first = match dict.get(b"F").or_else(|_| dict.get(b"Filter")).ok()? {
        Object::Name(n) => n.clone(),
        Object::Array(a) => a.first()?.as_name().ok()?.to_vec(),
        _ => return None,
    };
    let start = id + 3;
    let terminator: &[u8] = match first.as_slice() {
        b"A85" | b"ASCII85Decode" => b"~>",
        b"AHx" | b"ASCIIHexDecode" => b">",
        _ => return None,
    };
    let end_data = find(content, terminator, start)? + terminator.len();
    let mut e = end_data;
    while content.get(e).is_some_and(|b| is_space(*b)) {
        e += 1;
    }
    if content.get(e..e + 2) != Some(b"EI") || !content.get(e + 2).is_none_or(|b| is_space(*b)) {
        return None;
    }
    Some((bi, e + 2, Stream::new(dict, content[start..end_data].to_vec())))
}

fn text_ops(c: &Content) -> usize {
    c.operations.iter().filter(|o| matches!(o.operator.as_str(), "Tj" | "TJ" | "'" | "\"")).count()
}

/// Moves the large inline images of every page's content streams into XObjects; returns how
/// many it moved.
pub fn move_inline_images(doc: &mut Document, cancel: &AtomicBool) -> Result<usize> {
    let mut moved = 0;
    let mut serial = 0usize;
    let pages: Vec<ObjectId> = doc.get_pages().values().copied().collect();
    // A content stream two pages share keeps its inline images: the other page's resources
    // would lack the new names.
    let mut uses: std::collections::HashMap<ObjectId, usize> = std::collections::HashMap::new();
    for &p in &pages {
        for id in doc.get_page_contents(p) {
            *uses.entry(id).or_default() += 1;
        }
    }
    for page in pages {
        if cancel.load(Ordering::Relaxed) {
            return Err(EngineError::cancelled());
        }
        let Some(resources) = page_resources(doc, page) else { continue };
        let spaces = resources.get(b"ColorSpace").ok().and_then(|o| resolve_dict(doc, o)).cloned();
        let mut names: Vec<(Vec<u8>, Stream)> = Vec::new();
        let mut edits: Vec<(ObjectId, Vec<u8>)> = Vec::new();
        for id in doc.get_page_contents(page) {
            if uses.get(&id).copied().unwrap_or(0) > 1 {
                continue;
            }
            let Ok(s) = doc.get_object(id).and_then(|o| o.as_stream()) else { continue };
            let Ok(data) = s.decompressed_content_with_limit(MAX_STREAM) else { continue };
            if data.len() > MAX_CONTENT && tokens(&data) * 100 > MAX_OPERATOR_MEMORY {
                continue;
            }
            let Ok(old) = Content::decode(&data) else { continue };
            let mut out = Vec::with_capacity(data.len());
            // `at`: bytes copied so far; `scan`: where the next inline image is searched from.
            let (mut at, mut scan, mut ops_expected, mut added) = (0usize, 0usize, Vec::new(), Vec::new());
            for op in &old.operations {
                let mut expected = op.operator.clone();
                // The image lopdf read, or (when it could not) the one read from the raw bytes.
                let found = match op.operands.first() {
                    Some(Object::Stream(image)) if op.operator == "BI" => {
                        locate(&data, &image.content, scan).map(|(s, e)| (s, e, image.clone()))
                    }
                    None if op.operator == "BI" => raw_inline(&data, scan),
                    _ => None,
                };
                if op.operator == "BI"
                    && let Some((start, end, image)) = &found
                    && image.content.len() >= MIN_BYTES
                    && let Some(xo) = xobject(image, spaces.as_ref())
                {
                    let (start, end) = (*start, *end);
                    serial += 1;
                    let name = format!("EsclopIm{serial}").into_bytes();
                    out.extend_from_slice(&data[at..start]);
                    out.extend_from_slice(b"/");
                    out.extend_from_slice(&name);
                    out.extend_from_slice(b" Do");
                    at = end;
                    scan = end;
                    expected = "Do".to_string();
                    added.push((name, xo));
                } else if op.operator == "BI"
                    && let Some((_, end, _)) = &found
                {
                    // An inline image left in place is searched past, and copied as it is.
                    scan = scan.max(*end).min(data.len());
                }
                ops_expected.push(expected);
            }
            if added.is_empty() {
                continue;
            }
            out.extend_from_slice(&data[at..]);
            // The edit must parse to the same operators, the moved images now `Do`.
            let Ok(new) = Content::decode(&out) else { continue };
            let same = new.operations.iter().map(|o| o.operator.as_str()).eq(ops_expected.iter().map(String::as_str))
                && text_ops(&new) == text_ops(&old);
            if !same {
                continue;
            }
            edits.push((id, out));
            names.extend(added);
        }
        if edits.is_empty() {
            continue;
        }
        // Names in the page's own XObject resources (a copy when they were inherited).
        let mut xobjects =
            resources.get(b"XObject").ok().and_then(|o| resolve_dict(doc, o)).cloned().unwrap_or_default();
        if names.iter().any(|(n, _)| xobjects.has(n)) {
            continue;
        }
        for (name, xo) in names {
            let id = doc.add_object(Object::Stream(xo));
            xobjects.set(name, Object::Reference(id));
            moved += 1;
        }
        let mut res = resources.clone();
        res.set("XObject", Object::Dictionary(xobjects));
        if let Ok(p) = doc.get_dictionary_mut(page) {
            p.set("Resources", Object::Dictionary(res));
        }
        for (id, data) in edits {
            if let Ok(Object::Stream(s)) = doc.get_object_mut(id) {
                let mut d = s.dict.clone();
                d.remove(b"Filter");
                d.remove(b"DecodeParms");
                *s = Stream::new(d, data);
            }
        }
    }
    Ok(moved)
}

fn resolve_dict<'a>(doc: &'a Document, o: &'a Object) -> Option<&'a Dictionary> {
    match o {
        Object::Reference(r) => resolve_dict(doc, doc.get_object(*r).ok()?),
        Object::Dictionary(d) => Some(d),
        _ => None,
    }
}

/// A page's resources (inherited through the page tree when the page has none), as a copy.
fn page_resources(doc: &Document, page: ObjectId) -> Option<Dictionary> {
    let mut node = doc.get_dictionary(page).ok()?;
    for _ in 0..64 {
        if let Some(r) = node.get(b"Resources").ok().and_then(|o| resolve_dict(doc, o)) {
            return Some(r.clone());
        }
        node = doc.get_dictionary(node.get(b"Parent").ok()?.as_reference().ok()?).ok()?;
    }
    Some(Dictionary::new())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn locates_the_inline_image() {
        let data = vec![7u8; 5000];
        let mut c = b"q 10 0 0 10 0 0 cm BI /W 100 /H 50 /BPC 8 /CS /G ID ".to_vec();
        c.extend_from_slice(&data);
        c.extend_from_slice(b"\nEI Q");
        let (s, e) = locate(&c, &data, 0).unwrap();
        assert_eq!(&c[s..s + 2], b"BI");
        assert_eq!(&c[e - 2..e], b"EI");
        assert_eq!(&c[e..], b" Q");
    }
}
