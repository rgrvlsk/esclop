// SPDX-License-Identifier: GPL-3.0-or-later
//! Where the bytes of embedded fonts sit in a corpus: `cargo run --release --example font-census -- <dir>`.
//! Prints, per font program kind, how many there are, their stored bytes, their share of all
//! file bytes and how many are already subset (a `ABCDEF+` name prefix).

use lopdf::{Document, Object, ObjectId};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};

#[derive(Default)]
struct Tally {
    count: usize,
    bytes: u64,
    subset: usize,
    subset_bytes: u64,
    files: usize,
}

fn pdfs(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        if p.is_dir() {
            pdfs(&p, out);
        } else if p.extension().is_some_and(|x| x.eq_ignore_ascii_case("pdf")) {
            out.push(p);
        }
    }
}

fn name(doc: &Document, o: &Object) -> Option<Vec<u8>> {
    match o {
        Object::Name(n) => Some(n.clone()),
        Object::Reference(id) => doc.get_object(*id).ok().and_then(|o| name(doc, o)),
        _ => None,
    }
}

fn main() {
    let dir = PathBuf::from(std::env::args().nth(1).expect("usage: font-census DIR"));
    let mut files = Vec::new();
    pdfs(&dir, &mut files);
    files.sort();
    let (mut total, mut read, mut images) = (0u64, 0usize, 0u64);
    let mut kinds: BTreeMap<String, Tally> = BTreeMap::new();
    // Font programs per file that share a base name: copies a merge could drop.
    let (mut dup_programs, mut dup_bytes) = (0usize, 0u64);
    for f in &files {
        let Ok(bytes) = std::fs::read(f) else { continue };
        total += bytes.len() as u64;
        let Ok(doc) = Document::load_mem(&bytes) else { continue };
        read += 1;
        let mut seen: HashSet<ObjectId> = HashSet::new();
        let mut by_name: HashMap<(String, Vec<u8>), Vec<u64>> = HashMap::new();
        let mut kinds_here: HashSet<String> = HashSet::new();
        for o in doc.objects.values() {
            if let Object::Stream(s) = o
                && s.dict.get(b"Subtype").ok().and_then(|t| t.as_name().ok()) == Some(b"Image")
            {
                images += s.content.len() as u64;
            }
            let Ok(d) = o.as_dict().or_else(|_| o.as_stream().map(|s| &s.dict)) else { continue };
            if d.get(b"Type").ok().and_then(|t| t.as_name().ok()) != Some(b"FontDescriptor") {
                continue;
            }
            let font_name = d.get(b"FontName").ok().and_then(|n| name(&doc, n)).unwrap_or_default();
            for key in [&b"FontFile"[..], b"FontFile2", b"FontFile3"] {
                let Some(id) = d.get(key).ok().and_then(|r| r.as_reference().ok()) else { continue };
                if !seen.insert(id) {
                    continue;
                }
                let Ok(s) = doc.get_object(id).and_then(|o| o.as_stream()) else { continue };
                let kind = match key {
                    b"FontFile" => "Type1 (FontFile)".to_string(),
                    b"FontFile2" => "TrueType (FontFile2)".to_string(),
                    _ => {
                        let sub = s.dict.get(b"Subtype").ok().and_then(|t| t.as_name().ok()).unwrap_or(b"?");
                        format!("{} (FontFile3)", String::from_utf8_lossy(sub))
                    }
                };
                let n = s.content.len() as u64;
                let is_subset = font_name.len() > 7 && font_name[6] == b'+' && font_name[..6].iter().all(u8::is_ascii_uppercase);
                let t = kinds.entry(kind.clone()).or_default();
                t.count += 1;
                t.bytes += n;
                if is_subset {
                    t.subset += 1;
                    t.subset_bytes += n;
                }
                kinds_here.insert(kind.clone());
                let base = if is_subset { font_name[7..].to_vec() } else { font_name.clone() };
                by_name.entry((kind, base)).or_default().push(n);
            }
        }
        for k in kinds_here {
            kinds.get_mut(&k).unwrap().files += 1;
        }
        for (_, mut sizes) in by_name {
            if sizes.len() > 1 {
                sizes.sort_unstable();
                dup_programs += sizes.len() - 1;
                dup_bytes += sizes[..sizes.len() - 1].iter().sum::<u64>();
            }
        }
    }
    let mb = |b: u64| b as f64 / 1e6;
    println!("{} PDFs, {} readable, {:.1} MB; image streams {:.1} MB ({:.0}%)", files.len(), read, mb(total), mb(images), 100.0 * images as f64 / total as f64);
    println!("| font program | files | programs | MB | % of all bytes | subset already | MB in subset ones |");
    println!("|---|---:|---:|---:|---:|---:|---:|");
    let mut all = 0;
    for (k, t) in &kinds {
        all += t.bytes;
        println!("| {k} | {} | {} | {:.1} | {:.1} | {} | {:.1} |", t.files, t.count, mb(t.bytes), 100.0 * t.bytes as f64 / total as f64, t.subset, mb(t.subset_bytes));
    }
    println!("| all fonts | | | {:.1} | {:.1} | | |", mb(all), 100.0 * all as f64 / total as f64);
    println!("same-name copies within a file (merge candidates): {dup_programs} programs, {:.1} MB", mb(dup_bytes));
}
