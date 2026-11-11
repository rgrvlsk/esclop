// SPDX-License-Identifier: GPL-3.0-or-later
//! Whether lopdf read the file the way a viewer does. Viewers repair damaged files their own way
//! (they scan for `obj` and `endstream`); lopdf repairs differently or not at all, and a rewrite
//! would then store lopdf's reading: a stream without `/Length` loaded as empty, an object taken
//! from the wrong place. Such files are refused (`decode`) instead.

use crate::error::{EngineError, Result};
use lopdf::xref::XrefEntry;
use lopdf::{Document, Object};
use std::sync::atomic::{AtomicBool, Ordering};

/// Every in-use cross-reference entry of an object lopdf loaded must point at `id gen obj`, and
/// every stream lopdf loaded
/// must hold all the bytes up to its `endstream`. Linear in the file: `endobj` and `endstream`
/// are located once (`Marks`), not searched for from each object.
pub fn check(bytes: &[u8], doc: &Document, cancel: &AtomicBool) -> Result<()> {
    let referenced = referenced_ids(doc);
    let marks = Marks::new(bytes);
    for (n, (&id, entry)) in doc.reference_table.entries.iter().enumerate() {
        if n % 4096 == 0 && cancel.load(Ordering::Relaxed) {
            return Err(EngineError::cancelled());
        }
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
        // Decrypted content is shorter than its stored bytes: AES adds a 16-byte IV and up to
        // 16 bytes of padding (lopdf also rewrites `/Length` to the decrypted size).
        let slack = if doc.was_encrypted() { 32 } else { 0 };
        if let Some(Object::Stream(s)) = doc.objects.get(&(id, generation))
            && let Some(raw) = raw_stream_len(bytes, after, &marks)
            && s.content.len() + slack < raw
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

/// Where every `endobj` and `endstream` of the file starts, in order.
struct Marks {
    endobj: Vec<usize>,
    endstream: Vec<usize>,
}

impl Marks {
    fn new(bytes: &[u8]) -> Self {
        let (mut endobj, mut endstream) = (Vec::new(), Vec::new());
        let mut i = 0;
        while let Some(p) = bytes.get(i..).and_then(memchr_e) {
            let at = i + p;
            if bytes[at..].starts_with(b"endobj") {
                endobj.push(at);
            } else if bytes[at..].starts_with(b"endstream") {
                endstream.push(at);
            }
            i = at + 1;
        }
        Self { endobj, endstream }
    }

    /// The first mark at or after `from`.
    fn next(marks: &[usize], from: usize) -> Option<usize> {
        marks.get(marks.partition_point(|m| *m < from)).copied()
    }
}

/// The offset of the next `e`.
fn memchr_e(b: &[u8]) -> Option<usize> {
    b.iter().position(|c| *c == b'e')
}

/// Bytes between the `stream` keyword's line end and the first `endstream` (its line end
/// excluded), when the object starting its body at `after` is a stream.
fn raw_stream_len(bytes: &[u8], after: usize, marks: &Marks) -> Option<usize> {
    let end_obj = Marks::next(&marks.endobj, after).unwrap_or(bytes.len());
    // The first `stream` of the object: the keyword after its dictionary, or the start of an
    // `endstream` when it has none.
    let kw = after + find(&bytes[after..end_obj], b"stream")?;
    if kw >= after + 3 && &bytes[kw - 3..kw] == b"end" {
        return None;
    }
    let mut start = kw + 6;
    if bytes.get(start) == Some(&b'\r') {
        start += 1;
    }
    if bytes.get(start) == Some(&b'\n') {
        start += 1;
    }
    let end = Marks::next(&marks.endstream, start)?;
    let mut len = end - start;
    for eol in *b"\n\r" {
        if len > 0 && bytes[start + len - 1] == eol {
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
        assert_eq!(raw_stream_len(f, 17, &Marks::new(f)), Some(5));
        let g = b" << >> endobj";
        assert_eq!(raw_stream_len(g, 0, &Marks::new(g)), None);
    }
}
