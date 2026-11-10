// SPDX-License-Identifier: GPL-3.0-or-later
//! Subsetting of embedded TrueType fonts (`/FontFile2`) to the glyphs the document draws.
//!
//! The method is the one Ghostscript's pdfwrite follows, reimplemented from its description:
//! find every glyph each embedded font paints, then store a font program that holds only those.
//! Unlike pdfwrite, which re-renders the document and so re-encodes all text, nothing outside
//! the font program changes. Glyph ids are kept (unused glyphs become empty outlines) and the
//! `cmap` table is copied as it was, so every code that selected a glyph before still selects
//! the same glyph, and content streams, `/Widths`, `/W`, `/ToUnicode` and `/CIDToGIDMap` stay
//! valid as they are.
//!
//! A glyph that is drawn but left out would show as a blank, so every doubt keeps glyphs or
//! keeps the whole font:
//! - the glyphs a one-byte code can select are taken from every mapping a viewer might use
//!   (each `cmap` subtable at the code, at 0xF000 + code and at the code's Unicode value, the
//!   `post` glyph names of `/Differences`, and the code as a glyph id), not one guessed mapping;
//! - text is collected from page content, form XObjects, tiling patterns, Type 3 glyphs,
//!   soft-mask groups and annotation appearances; a font dictionary that no scanned stream
//!   selects, an interactive form's default fonts (`/AcroForm /DR`, which fill fields typed
//!   later) and fonts used through a CMap other than Identity keep their whole program;
//! - if any content stream fails to parse, no font in the document is subset.

use super::deflate;
use lopdf::content::Content;
use lopdf::{Dictionary, Document, Object, ObjectId, Stream};
use rayon::prelude::*;
use read_fonts::collections::IntSet;
use read_fonts::types::{GlyphId, NameId, Tag};
use read_fonts::{FontRef, TableProvider};
use skera::{Plan, SubsetFlags, subset_font};
use std::collections::{BTreeSet, HashMap, HashSet};

const MAX_DEPTH: usize = 32;
const LIMIT: usize = 256 << 20;

/// Layout and device tables a PDF viewer never reads: glyph positions come from the PDF.
const DROP: &[&[u8; 4]] = &[
    b"GSUB", b"GPOS", b"GDEF", b"BASE", b"JSTF", b"MATH", b"kern", b"morx", b"mort", b"feat", b"kerx", b"DSIG",
    b"hdmx", b"LTSH", b"VDMX", b"PCLT", b"meta", b"STAT", b"trak", b"opbd", b"prop", b"lcar", b"just",
];
/// Copied unchanged: the code-to-glyph map (glyph ids are kept, so it stays right) and the
/// hinting programs.
const KEEP: &[&[u8; 4]] = &[b"cmap", b"fpgm", b"prep", b"cvt ", b"gasp"];

fn deref<'a>(doc: &'a Document, mut o: &'a Object) -> &'a Object {
    for _ in 0..16 {
        match o {
            Object::Reference(id) => match doc.get_object(*id) {
                Ok(x) => o = x,
                Err(_) => return o,
            },
            _ => return o,
        }
    }
    o
}

fn dict<'a>(doc: &'a Document, o: &'a Object) -> Option<&'a Dictionary> {
    match deref(doc, o) {
        Object::Dictionary(d) => Some(d),
        Object::Stream(s) => Some(&s.dict),
        _ => None,
    }
}

fn get<'a>(doc: &'a Document, d: &'a Dictionary, key: &[u8]) -> Option<&'a Object> {
    d.get(key).ok().map(|o| deref(doc, o))
}

fn name<'a>(doc: &'a Document, d: &'a Dictionary, key: &[u8]) -> Option<&'a [u8]> {
    get(doc, d, key).and_then(|o| o.as_name().ok())
}

fn key(d: &Dictionary) -> usize {
    std::ptr::from_ref(d) as usize
}

/// How a font dictionary's codes select glyphs of its program.
enum Map {
    /// One-byte codes; each lists every glyph it might select.
    Simple(Box<[Vec<u16>]>),
    /// Two-byte CIDs (Identity-H or -V) through `/CIDToGIDMap`; `None` is Identity.
    Cid(Option<Vec<u16>>),
}

struct Font {
    program: ObjectId,
    map: Map,
}

/// The `/FontFile2` stream of a font dictionary, its own or its descendant's.
fn program_of(doc: &Document, font: &Dictionary) -> Option<ObjectId> {
    let own = |d: &Dictionary| {
        let desc = dict(doc, d.get(b"FontDescriptor").ok()?)?;
        desc.get(b"FontFile2").ok()?.as_reference().ok()
    };
    own(font).or_else(|| {
        let first = get(doc, font, b"DescendantFonts")?.as_array().ok()?.first()?;
        own(dict(doc, first)?)
    })
}

/// Whether a dictionary is a font that can carry its own program (a Type 0 font through its
/// descendant). Descendant CIDFonts are left to their parent.
fn is_font(doc: &Document, d: &Dictionary) -> bool {
    let typed = name(doc, d, b"Type").is_none_or(|t| t == b"Font");
    typed && matches!(name(doc, d, b"Subtype"), Some(b"TrueType" | b"Type0" | b"Type1" | b"MMType1"))
}

/// The font as this module can subset it: `None` when it has no TrueType program,
/// `Some(Err(program))` when it has one this module cannot follow.
fn resolve(doc: &Document, font: &Dictionary, programs: &mut Programs) -> Option<Result<Font, ObjectId>> {
    let program = program_of(doc, font)?;
    let map = match name(doc, font, b"Subtype") {
        Some(b"TrueType") => programs.simple_map(doc, font, program).map(Map::Simple),
        Some(b"Type0") => cid_map(doc, font).map(Map::Cid),
        _ => None,
    };
    Some(map.map(|map| Font { program, map }).ok_or(program))
}

fn cid_map(doc: &Document, font: &Dictionary) -> Option<Option<Vec<u16>>> {
    if !matches!(name(doc, font, b"Encoding"), Some(b"Identity-H" | b"Identity-V")) {
        return None;
    }
    let desc = dict(doc, get(doc, font, b"DescendantFonts")?.as_array().ok()?.first()?)?;
    if name(doc, desc, b"Subtype") != Some(b"CIDFontType2") {
        return None;
    }
    match get(doc, desc, b"CIDToGIDMap") {
        None => Some(None),
        Some(Object::Name(n)) if n == b"Identity" => Some(None),
        Some(Object::Stream(s)) => {
            let data = s.decompressed_content_with_limit(LIMIT).ok()?;
            Some(Some(data.chunks_exact(2).map(|c| u16::from_be_bytes([c[0], c[1]])).collect()))
        }
        _ => None,
    }
}

/// Decoded font programs, by stream id.
#[derive(Default)]
struct Programs(HashMap<ObjectId, Option<Vec<u8>>>);

impl Programs {
    fn bytes(&mut self, doc: &Document, id: ObjectId) -> Option<&[u8]> {
        self.0
            .entry(id)
            .or_insert_with(|| doc.get_object(id).ok()?.as_stream().ok()?.decompressed_content_with_limit(LIMIT).ok())
            .as_deref()
    }

    /// For each one-byte code, every glyph of the program a viewer might draw for it.
    fn simple_map(&mut self, doc: &Document, font: &Dictionary, program: ObjectId) -> Option<Box<[Vec<u16>]>> {
        let encoding = font.get_font_encoding(doc).ok();
        let differences = differences(doc, font);
        let data = self.bytes(doc, program)?;
        let f = FontRef::new(data).ok()?;
        let glyphs = f.maxp().ok()?.num_glyphs();
        let cmap = f.cmap().ok();
        let subtables: Vec<_> =
            cmap.iter().flat_map(|c| c.encoding_records().iter().filter_map(|r| r.subtable(c.offset_data()).ok())).collect();
        let mut by_name: HashMap<String, u16> = HashMap::new();
        if differences.iter().any(Option::is_some)
            && let Ok(post) = f.post()
        {
            for g in 0..glyphs {
                if let Some(n) = post.glyph_name(g.into()) {
                    by_name.entry(n.to_string()).or_insert(g);
                }
            }
        }
        let mut out = vec![Vec::new(); 256];
        for (c, slot) in out.iter_mut().enumerate() {
            let mut cps: Vec<u32> = vec![c as u32, 0xF000 + c as u32, 0xF100 + c as u32, 0xF200 + c as u32];
            if let Some(e) = &encoding
                && let Ok(s) = e.bytes_to_string(&[c as u8])
            {
                cps.extend(s.chars().map(u32::from));
            }
            let mut gids: Vec<u16> = vec![c as u16];
            if let Some(n) = &differences[c] {
                gids.extend(by_name.get(n.as_str()));
                cps.extend(unicode_of_name(n));
                gids.extend(gid_of_name(n));
            }
            for t in &subtables {
                gids.extend(cps.iter().filter_map(|cp| t.map_codepoint(*cp)).map(|g| g.to_u32() as u16));
            }
            gids.retain(|g| *g < glyphs);
            gids.sort_unstable();
            gids.dedup();
            *slot = gids;
        }
        Some(out.into_boxed_slice())
    }
}

/// The glyph name `/Differences` gives each code.
fn differences(doc: &Document, font: &Dictionary) -> Vec<Option<String>> {
    let mut out = vec![None; 256];
    let Some(Object::Dictionary(enc)) = get(doc, font, b"Encoding") else { return out };
    let Some(Object::Array(a)) = get(doc, enc, b"Differences") else { return out };
    let mut code = 0usize;
    for o in a {
        match deref(doc, o) {
            Object::Integer(i) => code = (*i).clamp(0, 256) as usize,
            Object::Name(n) => {
                if code < 256 {
                    out[code] = Some(String::from_utf8_lossy(n).into_owned());
                }
                code += 1;
            }
            _ => {}
        }
    }
    out
}

/// `uniXXXX` and `uXXXX[XX]` names.
fn unicode_of_name(n: &str) -> Option<u32> {
    let hex = n.strip_prefix("uni").filter(|h| h.len() == 4).or_else(|| n.strip_prefix('u').filter(|h| (4..=6).contains(&h.len())))?;
    u32::from_str_radix(hex, 16).ok()
}

/// `gNN`, `glyphNN` and `cidNN` names, which some writers use for glyph ids.
fn gid_of_name(n: &str) -> Option<u16> {
    let digits = n.strip_prefix("glyph").or_else(|| n.strip_prefix("cid")).or_else(|| n.strip_prefix('g'))?;
    digits.parse().ok()
}

/// What the content of a document draws with each TrueType program.
#[derive(Default)]
struct Usage {
    fonts: HashMap<usize, Option<Result<Font, ObjectId>>>,
    /// Font dictionaries some scanned stream selects.
    selected: HashSet<usize>,
    used: HashMap<ObjectId, BTreeSet<u16>>,
    keep_whole: HashSet<ObjectId>,
    visited: HashSet<(ObjectId, usize)>,
    failed: bool,
    programs: Programs,
}

impl Usage {
    fn show(&mut self, doc: &Document, font: &Dictionary, text: &[u8]) {
        let k = key(font);
        self.selected.insert(k);
        let programs = &mut self.programs;
        let entry = self.fonts.entry(k).or_insert_with(|| resolve(doc, font, programs));
        match entry {
            None => {}
            Some(Err(p)) => {
                self.keep_whole.insert(*p);
            }
            Some(Ok(f)) => {
                let set = self.used.entry(f.program).or_default();
                match &f.map {
                    Map::Simple(m) => text.iter().for_each(|b| set.extend(&m[*b as usize])),
                    Map::Cid(m) => {
                        for c in text.chunks_exact(2) {
                            let cid = u16::from_be_bytes([c[0], c[1]]);
                            set.insert(m.as_ref().map_or(cid, |m| m.get(cid as usize).copied().unwrap_or(0)));
                        }
                    }
                }
            }
        }
    }

    /// Walks one content stream drawn with `resources`, and the streams it draws.
    fn walk<'a>(&mut self, doc: &'a Document, content: &[u8], resources: Option<&'a Dictionary>, depth: usize) {
        if depth > MAX_DEPTH {
            self.failed = true;
            return;
        }
        let Ok(ops) = Content::decode(content) else {
            self.failed = true;
            return;
        };
        let res = |k: &[u8]| resources.and_then(|r| get(doc, r, k)).and_then(|o| dict(doc, o));
        let (fonts, xobjects, states) = (res(b"Font"), res(b"XObject"), res(b"ExtGState"));
        if let Some(r) = resources {
            self.side_streams(doc, r, depth);
        }
        let mut font: Option<&Dictionary> = None;
        let mut saved = Vec::new();
        for op in &ops.operations {
            let args = &op.operands;
            match op.operator.as_str() {
                "q" => saved.push(font),
                "Q" => font = saved.pop().unwrap_or(font),
                "Tf" => {
                    let n = args.first().and_then(|o| o.as_name().ok());
                    font = n.and_then(|n| fonts.and_then(|f| f.get(n).ok())).and_then(|o| dict(doc, o));
                }
                "gs" => {
                    let n = args.first().and_then(|o| o.as_name().ok());
                    let state = n.and_then(|n| states.and_then(|s| s.get(n).ok())).and_then(|o| dict(doc, o));
                    if let Some(Object::Array(a)) = state.and_then(|s| get(doc, s, b"Font")) {
                        font = a.first().and_then(|o| dict(doc, o)).or(font);
                    }
                }
                "Tj" | "'" | "\"" | "TJ" => {
                    let Some(f) = font else { continue };
                    let mut strings = Vec::new();
                    match args.last() {
                        Some(Object::String(s, _)) => strings.push(s),
                        Some(Object::Array(a)) => strings.extend(a.iter().filter_map(|o| match o {
                            Object::String(s, _) => Some(s),
                            _ => None,
                        })),
                        _ => {}
                    }
                    for s in strings {
                        self.show(doc, f, s);
                    }
                }
                "Do" => {
                    let n = args.first().and_then(|o| o.as_name().ok());
                    let Some(Ok(id)) = n.and_then(|n| xobjects.and_then(|x| x.get(n).ok())).map(|o| o.as_reference()) else {
                        continue;
                    };
                    self.form(doc, id, resources, depth);
                }
                _ => {}
            }
        }
    }

    /// A form-like stream (form XObject, pattern, glyph procedure, appearance) by id, drawn
    /// with its own resources or, lacking them, the caller's.
    fn form<'a>(&mut self, doc: &'a Document, id: ObjectId, inherited: Option<&'a Dictionary>, depth: usize) {
        let Ok(Object::Stream(s)) = doc.get_object(id) else { return };
        if name(doc, &s.dict, b"Subtype") == Some(b"Image") {
            return;
        }
        let res = get(doc, &s.dict, b"Resources").and_then(|o| dict(doc, o)).or(inherited);
        if !self.visited.insert((id, res.map_or(0, key))) {
            return;
        }
        match s.decompressed_content_with_limit(LIMIT) {
            Ok(data) => self.walk(doc, &data, res, depth + 1),
            Err(_) => self.failed = true,
        }
    }

    /// Streams a resource dictionary carries besides the content that names it: tiling
    /// patterns, Type 3 glyph procedures and soft-mask groups. All are walked, drawn or not.
    fn side_streams<'a>(&mut self, doc: &'a Document, r: &'a Dictionary, depth: usize) {
        let sub = |k: &[u8]| get(doc, r, k).and_then(|o| dict(doc, o));
        for (_, p) in sub(b"Pattern").into_iter().flat_map(|d| d.iter()) {
            if let Ok(id) = p.as_reference() {
                self.form(doc, id, Some(r), depth);
            }
        }
        for (_, f) in sub(b"Font").into_iter().flat_map(|d| d.iter()) {
            let Some(f) = dict(doc, f) else { continue };
            if name(doc, f, b"Subtype") != Some(b"Type3") {
                continue;
            }
            let res = get(doc, f, b"Resources").and_then(|o| dict(doc, o)).or(Some(r));
            for (_, g) in get(doc, f, b"CharProcs").and_then(|o| dict(doc, o)).into_iter().flat_map(|d| d.iter()) {
                if let Ok(id) = g.as_reference() {
                    self.form(doc, id, res, depth);
                }
            }
        }
        for (_, s) in sub(b"ExtGState").into_iter().flat_map(|d| d.iter()) {
            let mask = dict(doc, s).and_then(|s| get(doc, s, b"SMask")).and_then(|m| m.as_dict().ok());
            if let Some(Ok(id)) = mask.and_then(|m| m.get(b"G").ok()).map(|g| g.as_reference()) {
                self.form(doc, id, Some(r), depth);
            }
        }
    }
}

fn page_resources(doc: &Document, page: ObjectId) -> Option<&Dictionary> {
    let mut node = doc.get_dictionary(page).ok()?;
    for _ in 0..64 {
        if let Some(r) = get(doc, node, b"Resources").and_then(|o| dict(doc, o)) {
            return Some(r);
        }
        node = dict(doc, node.get(b"Parent").ok()?)?;
    }
    None
}

/// Every TrueType program referenced from a font dictionary the scan never selected, or from
/// the interactive form's default resources.
fn unscanned_programs(doc: &Document, usage: &Usage) -> HashSet<ObjectId> {
    fn visit(doc: &Document, o: &Object, usage: &Usage, out: &mut HashSet<ObjectId>, depth: usize) {
        if depth > 64 {
            return;
        }
        let d = match o {
            Object::Dictionary(d) => d,
            Object::Stream(s) => &s.dict,
            Object::Array(a) => return a.iter().for_each(|o| visit(doc, o, usage, out, depth + 1)),
            _ => return,
        };
        if is_font(doc, d) {
            if !usage.selected.contains(&key(d))
                && let Some(p) = program_of(doc, d)
            {
                out.insert(p);
            }
            return;
        }
        d.iter().for_each(|(_, o)| visit(doc, o, usage, out, depth + 1));
    }
    let mut out = HashSet::new();
    doc.objects.values().for_each(|o| visit(doc, o, usage, &mut out, 0));
    let form_fonts = doc
        .catalog()
        .ok()
        .and_then(|c| get(doc, c, b"AcroForm"))
        .and_then(|a| a.as_dict().ok())
        .and_then(|a| get(doc, a, b"DR"))
        .and_then(|r| r.as_dict().ok())
        .and_then(|r| get(doc, r, b"Font"))
        .and_then(|f| f.as_dict().ok());
    for (_, f) in form_fonts.into_iter().flat_map(|d| d.iter()) {
        if let Some(p) = dict(doc, f).and_then(|f| program_of(doc, f)) {
            out.insert(p);
        }
    }
    out
}

/// Glyph ids each TrueType program must keep, for the programs that can be subset.
fn collect(doc: &Document) -> (HashMap<ObjectId, BTreeSet<u16>>, Programs) {
    let mut u = Usage::default();
    for (_, page) in doc.get_pages() {
        let res = page_resources(doc, page);
        match doc.get_page_content_with_limit(page, LIMIT) {
            Ok(c) => u.walk(doc, &c, res, 0),
            Err(_) => u.failed = true,
        }
        let annots = doc.get_dictionary(page).ok().and_then(|p| get(doc, p, b"Annots")).and_then(|a| a.as_array().ok());
        for a in annots.into_iter().flatten() {
            let ap = dict(doc, a).and_then(|a| get(doc, a, b"AP")).and_then(|o| o.as_dict().ok());
            for (_, look) in ap.into_iter().flat_map(|d| d.iter()) {
                match look {
                    Object::Reference(id) if matches!(doc.get_object(*id), Ok(Object::Stream(_))) => u.form(doc, *id, None, 0),
                    o => {
                        for (_, s) in dict(doc, o).into_iter().flat_map(|d| d.iter()) {
                            if let Ok(id) = s.as_reference() {
                                u.form(doc, id, None, 0);
                            }
                        }
                    }
                }
            }
        }
        if u.failed {
            if std::env::var_os("ESCLOP_FONT_TRACE").is_some() {
                eprintln!("fonts: a content stream failed to parse on page {page:?}");
            }
            return (HashMap::new(), u.programs);
        }
    }
    let mut skip = unscanned_programs(doc, &u);
    skip.extend(&u.keep_whole);
    if std::env::var_os("ESCLOP_FONT_TRACE").is_some() {
        eprintln!("fonts: used {:?}", u.used.iter().map(|(p, g)| (p.0, g.len(), skip.contains(p))).collect::<Vec<_>>());
        eprintln!("fonts: unscanned {:?} keep_whole {:?}", unscanned_programs(doc, &u).iter().map(|p| p.0).collect::<Vec<_>>(), u.keep_whole.iter().map(|p| p.0).collect::<Vec<_>>());
    }
    let used = u.used.into_iter().filter(|(p, _)| !skip.contains(p)).collect();
    (used, u.programs)
}

/// The program holding only `gids` (plus `.notdef`), glyph ids unchanged.
fn subset(data: &[u8], gids: &BTreeSet<u16>) -> Result<Vec<u8>, String> {
    let font = FontRef::new(data).map_err(|e| format!("read: {e}"))?;
    font.glyf().map_err(|e| format!("glyf: {e}"))?;
    let total = font.maxp().map_err(|e| format!("maxp: {e}"))?.num_glyphs();
    let mut input = IntSet::<GlyphId>::empty();
    input.insert(GlyphId::NOTDEF);
    // Retained ids stop at the highest glyph kept; keeping the last one too holds the glyph
    // count, so the unchanged `cmap` never points past the end.
    input.insert(GlyphId::new(u32::from(total.saturating_sub(1))));
    input.extend(gids.iter().map(|g| GlyphId::new(u32::from(*g))));
    let drop: IntSet<Tag> = DROP.iter().map(|t| Tag::new(t)).collect();
    let keep: IntSet<Tag> = KEEP.iter().map(|t| Tag::new(t)).collect();
    let mut names = IntSet::<NameId>::empty();
    names.insert_range(NameId::from(0)..=NameId::from(6));
    let mut languages = IntSet::<u16>::empty();
    languages.insert(0x409);
    let flags = SubsetFlags::SUBSET_FLAGS_RETAIN_GIDS
        | SubsetFlags::SUBSET_FLAGS_GLYPH_NAMES
        | SubsetFlags::SUBSET_FLAGS_NOTDEF_OUTLINE
        | SubsetFlags::SUBSET_FLAGS_NAME_LEGACY;
    let empty_tags = IntSet::<Tag>::empty();
    let mut plan = Plan::new(&input, &IntSet::empty(), &font, flags, &drop, &empty_tags, &empty_tags, &names, &languages);
    plan.set_no_subset_tables(&keep);
    let out = subset_font(&font, &plan).map_err(|e| format!("subset: {e}"))?;
    // The subset must read back with the same number of glyphs, or ids would shift.
    let back = FontRef::new(&out).map_err(|e| format!("reread: {e}"))?;
    let count = |f: &FontRef| f.maxp().map(|m| m.num_glyphs()).ok();
    if count(&back) != count(&font) || count(&font).is_none() {
        return Err(format!("glyph count {:?} -> {:?}", count(&font), count(&back)));
    }
    Ok(out)
}

/// Replaces each embedded TrueType program the document can spare glyphs of with its subset,
/// where that is smaller. Returns how many were replaced.
pub fn subset_fonts(doc: &mut Document) -> usize {
    let (used, mut programs) = collect(doc);
    let jobs: Vec<(ObjectId, Vec<u8>, BTreeSet<u16>)> = used
        .into_iter()
        .filter_map(|(id, gids)| Some((id, programs.bytes(doc, id)?.to_vec(), gids)))
        .collect();
    drop(programs);
    let done: Vec<(ObjectId, Vec<u8>, usize)> = jobs
        .into_par_iter()
        .filter_map(|(id, data, gids)| {
            let out = subset(&data, &gids);
            if std::env::var_os("ESCLOP_FONT_TRACE").is_some() {
                eprintln!("fonts: program {} {} bytes, {} glyphs -> {:?}", id.0, data.len(), gids.len(), out.as_ref().map(Vec::len));
            }
            let out = out.ok()?;
            let n = out.len();
            Some((id, deflate::zlib(&out, 9), n))
        })
        .collect();
    let mut count = 0;
    for (id, packed, raw) in done {
        let Ok(Object::Stream(s)) = doc.get_object_mut(id) else { continue };
        if packed.len() >= s.content.len() {
            continue;
        }
        let mut d = s.dict.clone();
        for k in [&b"Filter"[..], b"DecodeParms", b"Length2", b"Length3"] {
            d.remove(k);
        }
        d.set("Filter", Object::Name(b"FlateDecode".to_vec()));
        d.set("Length1", Object::Integer(raw as i64));
        *s = Stream::new(d, packed);
        count += 1;
    }
    count
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn glyph_names() {
        assert_eq!(unicode_of_name("uni0041"), Some(0x41));
        assert_eq!(unicode_of_name("u1F600"), Some(0x1F600));
        assert_eq!(unicode_of_name("uniform"), None);
        assert_eq!(gid_of_name("g12"), Some(12));
        assert_eq!(gid_of_name("glyph7"), Some(7));
        assert_eq!(gid_of_name("grave"), None);
    }
}
