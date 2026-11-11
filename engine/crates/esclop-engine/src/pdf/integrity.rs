// SPDX-License-Identifier: GPL-3.0-or-later
//! Whether lopdf read the file the way a viewer does. Viewers repair damaged files their own way
//! (they scan for `obj` and `endstream`); lopdf repairs differently or not at all, and a rewrite
//! would then store lopdf's reading: a stream without `/Length` loaded as empty, an object taken
//! from the wrong place. Such files are refused (`decode`) instead.

use crate::error::{EngineError, Result};
use lopdf::xref::XrefEntry;
use lopdf::{Document, Object};

/// Every in-use cross-reference entry of an object lopdf loaded must point at `id gen obj`, and
/// every stream lopdf loaded
/// must hold all the bytes up to its `endstream`.
pub fn check(bytes: &[u8], doc: &Document) -> Result<()> {
    let referenced = referenced_ids(doc);
    for (&id, entry) in &doc.reference_table.entries {
        let XrefEntry::Normal { offset, generation } = *entry else { continue };
        // Entry 0 is the free list's head even when a writer marks it in use; an entry for an
        // object lopdf could not load matters only when something refers to it (a viewer may
        // find it elsewhere in the file, lopdf leaves the reference dangling).
        if id == 0 {
            continue;
        }
        if !doc.objects.contains_key(&(id, generation)) {
            if referenced.contains(&id) {
                return Err(EngineError::decode(format!("object {id} is referred to but cannot be read")));
            }
            continue;
        }
        let Some(after) = object_header(bytes, offset as usize, id, generation) else {
            return Err(EngineError::decode(format!("the cross-reference table misplaces object {id}")));
        };
        if let Some(Object::Stream(s)) = doc.objects.get(&(id, generation))
            && let Some(raw) = raw_stream_len(&bytes[after..])
            && s.content.len() < raw
        {
            return Err(EngineError::decode(format!(
                "object {id}'s stream is {raw} bytes long but declares {}",
                s.content.len()
            )));
        }
    }
    Ok(())
}

/// Object numbers some reference points at.
fn referenced_ids(doc: &Document) -> std::collections::HashSet<u32> {
    fn walk(o: &Object, out: &mut std::collections::HashSet<u32>, depth: usize) {
        if depth > 64 {
            return;
        }
        match o {
            Object::Reference((id, _)) => {
                out.insert(*id);
            }
            Object::Array(a) => a.iter().for_each(|o| walk(o, out, depth + 1)),
            Object::Dictionary(d) => d.iter().for_each(|(_, o)| walk(o, out, depth + 1)),
            Object::Stream(s) => s.dict.iter().for_each(|(_, o)| walk(o, out, depth + 1)),
            _ => {}
        }
    }
    let mut out = std::collections::HashSet::new();
    doc.objects.values().for_each(|o| walk(o, &mut out, 0));
    doc.trailer.iter().for_each(|(_, o)| walk(o, &mut out, 0));
    out
}

/// The position after `id gen obj` when that is what stands at `offset` (after whitespace).
fn object_header(bytes: &[u8], offset: usize, id: u32, generation: u16) -> Option<usize> {
    let mut p = offset;
    let skip = |p: &mut usize| {
        while bytes.get(*p).is_some_and(|b| b.is_ascii_whitespace()) {
            *p += 1;
        }
    };
    let number = |p: &mut usize| -> Option<u64> {
        let start = *p;
        while bytes.get(*p).is_some_and(u8::is_ascii_digit) {
            *p += 1;
        }
        std::str::from_utf8(bytes.get(start..*p)?).ok()?.parse().ok()
    };
    skip(&mut p);
    (number(&mut p)? == u64::from(id)).then_some(())?;
    skip(&mut p);
    (number(&mut p)? == u64::from(generation)).then_some(())?;
    skip(&mut p);
    bytes.get(p..p + 3).filter(|k| *k == b"obj").map(|_| p + 3)
}

/// Bytes between the `stream` keyword's line end and the first `endstream` (its line end
/// excluded), when the object is a stream.
fn raw_stream_len(obj: &[u8]) -> Option<usize> {
    let end_obj = find(obj, b"endobj").unwrap_or(obj.len());
    let kw = find(&obj[..end_obj], b"stream")?;
    if kw >= 3 && &obj[kw - 3..kw] == b"end" {
        return None;
    }
    let mut start = kw + 6;
    if obj.get(start) == Some(&b'\r') {
        start += 1;
    }
    if obj.get(start) == Some(&b'\n') {
        start += 1;
    }
    let end = start + find(&obj[start..], b"endstream")?;
    let mut len = end - start;
    for eol in *b"\n\r" {
        if len > 0 && obj[start + len - 1] == eol {
            len -= 1;
        }
    }
    Some(len)
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn headers_and_streams() {
        let f = b"%PDF-1.4\n 5 0 obj\n<< >>\nstream\nBT ET\r\nendstream\nendobj\n";
        assert_eq!(object_header(f, 9, 5, 0), Some(17));
        assert_eq!(object_header(f, 9, 4, 0), None);
        assert_eq!(raw_stream_len(&f[17..]), Some(5));
        assert_eq!(raw_stream_len(b" << >> endobj"), None);
    }
}
