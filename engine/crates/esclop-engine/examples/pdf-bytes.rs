// SPDX-License-Identifier: GPL-3.0-or-later
//! Where a PDF's bytes are: `cargo run --release --example pdf-bytes -- FILE...`.
//! One JSON line per file: bytes in images (with their pixels, by filter), font programs (by
//! kind), page and form content streams, other streams, and structure (everything else: object
//! and cross-reference streams, dictionaries, overhead). Used to split the size gap between two
//! optimisers' outputs by cause.

use lopdf::{Document, Object, ObjectId};
use std::collections::{BTreeMap, HashSet};

fn name(o: Option<&Object>) -> String {
    match o {
        Some(Object::Name(n)) => String::from_utf8_lossy(n).into_owned(),
        Some(Object::Array(a)) => a.iter().map(|x| name(Some(x))).collect::<Vec<_>>().join("+"),
        _ => "none".into(),
    }
}

fn main() {
    for path in std::env::args().skip(1) {
        let Ok(bytes) = std::fs::read(&path) else { continue };
        let Ok(doc) = Document::load_mem(&bytes) else {
            println!("{{\"file\":{path:?},\"error\":\"unreadable\"}}");
            continue;
        };
        let mut content: HashSet<ObjectId> = HashSet::new();
        for (_, page) in doc.get_pages() {
            content.extend(doc.get_page_contents(page));
        }
        let mut font_files: HashSet<ObjectId> = HashSet::new();
        for o in doc.objects.values() {
            let d = match o {
                Object::Dictionary(d) => d,
                _ => continue,
            };
            if d.get(b"Type").ok().and_then(|t| t.as_name().ok()) == Some(b"FontDescriptor") {
                for k in [&b"FontFile"[..], b"FontFile2", b"FontFile3"] {
                    if let Ok(Object::Reference(r)) = d.get(k) {
                        font_files.insert(*r);
                    }
                }
            }
        }
        let (mut img, mut img_px, mut fonts, mut cont, mut other) = (0u64, 0u64, 0u64, 0u64, 0u64);
        let mut by_filter: BTreeMap<String, (u64, u64)> = BTreeMap::new();
        let mut by_font: BTreeMap<String, u64> = BTreeMap::new();
        for (id, o) in &doc.objects {
            let Object::Stream(s) = o else { continue };
            let n = s.content.len() as u64;
            let ty = s.dict.get(b"Type").ok().and_then(|t| t.as_name().ok());
            if matches!(ty, Some(b"ObjStm" | b"XRef")) {
                continue;
            }
            match s.dict.get(b"Subtype").ok().and_then(|t| t.as_name().ok()) {
                Some(b"Image") => {
                    let w = s.dict.get(b"Width").and_then(|v| v.as_i64()).unwrap_or(0).max(0) as u64;
                    let h = s.dict.get(b"Height").and_then(|v| v.as_i64()).unwrap_or(0).max(0) as u64;
                    img += n;
                    img_px += w * h;
                    let e = by_filter.entry(name(s.dict.get(b"Filter").ok())).or_default();
                    e.0 += n;
                    e.1 += w * h;
                }
                Some(b"Form") => cont += n,
                _ if font_files.contains(id) => {
                    fonts += n;
                    *by_font.entry(name(s.dict.get(b"Subtype").ok())).or_default() += n;
                }
                _ if content.contains(id) => cont += n,
                _ => other += n,
            }
        }
        let total = bytes.len() as u64;
        let structure = total.saturating_sub(img + fonts + cont + other);
        let filters: Vec<String> = by_filter.iter().map(|(k, (b, p))| format!("{k:?}:[{b},{p}]")).collect();
        let kinds: Vec<String> = by_font.iter().map(|(k, b)| format!("{k:?}:{b}")).collect();
        println!(
            "{{\"file\":{path:?},\"total\":{total},\"images\":{img},\"image_px\":{img_px},\"fonts\":{fonts},\"content\":{cont},\"other\":{other},\"structure\":{structure},\"by_filter\":{{{}}},\"by_font\":{{{}}}}}",
            filters.join(","),
            kinds.join(",")
        );
    }
}
