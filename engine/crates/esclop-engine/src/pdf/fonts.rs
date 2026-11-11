// SPDX-License-Identifier: GPL-3.0-or-later
//! Subsetting of embedded TrueType and CFF fonts (`/FontFile2`, `/FontFile3`) to the glyphs the
//! document draws. TrueType goes through skera with glyph ids retained; CFF (bare, or in an
//! OpenType wrapper) through `cff`, which only empties the charstrings of glyphs no page uses
//! and keeps the charset, FDSelect, Private dicts and subroutines byte for byte.
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
//!   (each `cmap` subtable at the code, at 0xF000 + code, at the code's Unicode value and at its
//!   MacRoman code, the
//!   `post` glyph names of `/Differences`, and the code as a glyph id), not one guessed mapping;
//!   a simple font drawing a code that no `cmap` subtable maps is kept whole, since viewers
//!   then fall back to `post` names through the base encoding (Word's subsets often lack `cmap`);
//! - text is collected from page content, form XObjects, tiling patterns, Type 3 glyphs,
//!   soft-mask groups and annotation appearances; a font dictionary that no scanned stream
//!   selects, an interactive form's default fonts (`/AcroForm /DR`, which fill fields typed
//!   later) and fonts used through a CMap other than Identity keep their whole program;
//! - if any content stream fails to parse, no font in the document is subset.

use super::budget::{Held, too_much};
use super::{cff, deflate};
use crate::error::{EngineError, Result};
use lopdf::content::Content;
use lopdf::{Dictionary, Document, Object, ObjectId, Stream};
use rayon::prelude::*;
use read_fonts::collections::IntSet;
use read_fonts::types::{GlyphId, NameId, Tag};
use read_fonts::{FontRef, TableProvider};
use skera::{Plan, SubsetFlags, subset_font};
use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

const MAX_DEPTH: usize = 32;
use super::placement::MAX_CONTENT;

/// The current font and the fonts saved by `q`.
type TextState<'a> = (Option<&'a Dictionary>, Vec<Option<&'a Dictionary>>);
const LIMIT: usize = 256 << 20;

/// Layout and device tables a PDF viewer never reads: glyph positions come from the PDF.
const DROP: &[&[u8; 4]] = &[
    b"GSUB", b"GPOS", b"GDEF", b"BASE", b"JSTF", b"MATH", b"kern", b"morx", b"mort", b"feat", b"kerx", b"DSIG",
    b"hdmx", b"LTSH", b"VDMX", b"PCLT", b"meta", b"STAT", b"trak", b"opbd", b"prop", b"lcar", b"just",
];
/// Copied unchanged: the code-to-glyph map (glyph ids are kept, so it stays right), the hinting
/// programs, and `OS/2`, whose recomputed ranges and first and last characters moved
/// CoreGraphics' rendering of glyph tops by a pixel.
const KEEP: &[&[u8; 4]] = &[b"cmap", b"fpgm", b"prep", b"cvt ", b"gasp", b"OS/2", b"hmtx", b"hhea", b"post"];

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
    /// One-byte codes; each lists every glyph it might select, or is `None` when no `cmap`
    /// subtable maps it (the viewer would then go through `post` names or other guesses, which
    /// this module does not follow: the font is kept whole).
    Simple(Box<[Option<Vec<u16>>]>),
    /// Two-byte CIDs (Identity-H or -V) through `/CIDToGIDMap`; `None` is Identity.
    Cid(Option<Vec<u16>>, Option<Vec<u16>>),
}

struct Font {
    program: ObjectId,
    map: Map,
}

/// The `/FontFile2` or `/FontFile3` stream of a font dictionary, its own or its descendant's.
fn program_of(doc: &Document, font: &Dictionary) -> Option<ObjectId> {
    let own = |d: &Dictionary| {
        let desc = dict(doc, d.get(b"FontDescriptor").ok()?)?;
        desc.get(b"FontFile2").or_else(|_| desc.get(b"FontFile3")).ok()?.as_reference().ok()
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
        // A simple font with CFF outlines may be read through the CFF charset's glyph names,
        // which `simple_map` does not follow (pdf.js issue215, an OpenType-CFF Pagella in a
        // TrueType font, lost glyphs): kept whole.
        Some(b"TrueType") if programs.bytes(doc, program).is_some_and(|d| cff_table(d).is_some()) => None,
        Some(b"TrueType") => programs.simple_map(doc, font, program).map(Map::Simple),
        Some(b"Type0") => cid_map(doc, font).map(|m| Map::Cid(m, programs.cff_cids(doc, program))),
        _ => None,
    };
    Some(map.map(|map| Font { program, map }).ok_or(program))
}

fn cid_map(doc: &Document, font: &Dictionary) -> Option<Option<Vec<u16>>> {
    if !matches!(name(doc, font, b"Encoding"), Some(b"Identity-H" | b"Identity-V")) {
        return None;
    }
    let desc = dict(doc, get(doc, font, b"DescendantFonts")?.as_array().ok()?.first()?)?;
    match name(doc, desc, b"Subtype") {
        Some(b"CIDFontType2") => {}
        // CFF outlines: CIDs reach glyphs through the CFF charset (added in `show`).
        Some(b"CIDFontType0") => return Some(None),
        _ => return None,
    }
    match get(doc, desc, b"CIDToGIDMap") {
        None => Some(None),
        Some(Object::Name(n)) if n == b"Identity" => Some(None),
        Some(Object::Stream(s)) => {
            let data = s.decompressed_content_with_limit(LIMIT).ok()?;
            Some(Some(data.as_chunks::<2>().0.iter().map(|c| u16::from_be_bytes(*c)).collect()))
        }
        _ => None,
    }
}

/// Decoded font programs, by stream id, counted against the document's `Held` budget (`over`
/// once a program did not fit).
#[derive(Default)]
struct Programs {
    data: HashMap<ObjectId, Option<Vec<u8>>>,
    held: Option<Arc<Held>>,
    over: bool,
}

impl Programs {
    fn bytes(&mut self, doc: &Document, id: ObjectId) -> Option<&[u8]> {
        let held = self.held.clone();
        let over = &mut self.over;
        self.data
            .entry(id)
            .or_insert_with(|| {
                let s = doc.get_object(id).ok()?.as_stream().ok()?;
                // Decoded only as far as the document's budget has room: past it the operation
                // is refused, never a program decoded first and counted after.
                let room = held.as_ref().map_or(LIMIT, |h| h.room().min(LIMIT));
                // Strictly decoded and of the declared length: a short read would be subset into
                // a font missing glyphs.
                let data = match s.filters().unwrap_or_default().as_slice() {
                    [] => s.content.clone(),
                    [b"FlateDecode"] if !s.dict.has(b"DecodeParms") => {
                        match miniz_oxide::inflate::decompress_to_vec_zlib_with_limit(&s.content, room) {
                            Ok(d) => d,
                            Err(e) => {
                                *over |= room < LIMIT && e.status == miniz_oxide::inflate::TINFLStatus::HasMoreOutput;
                                return None;
                            }
                        }
                    }
                    _ => match s.decompressed_content_with_limit(room) {
                        Ok(d) => d,
                        Err(e) => {
                            *over |= room < LIMIT
                                && matches!(
                                    e,
                                    lopdf::Error::Decompress(lopdf::DecompressError::MemoryLimitExceeded { .. })
                                );
                            return None;
                        }
                    },
                };
                if let Some(h) = &held
                    && h.take(data.len()).is_err()
                {
                    *over = true;
                    return None;
                }
                let declared = s.dict.get(b"Length1").and_then(|l| l.as_i64()).ok();
                declared.is_none_or(|l| l as usize == data.len()).then_some(data)
            })
            .as_deref()
    }

    /// For a program with CFF outlines (bare or in an sfnt), the glyph of each CID in the CFF
    /// charset (`u16::MAX` where none).
    fn cff_cids(&mut self, doc: &Document, program: ObjectId) -> Option<Vec<u16>> {
        let data = self.bytes(doc, program)?;
        // read-fonts reads no charset from a bare CID-keyed CFF: parsed here.
        let cids = cff::cids(cff_table(data)?)?;
        let mut out = vec![u16::MAX; 65536];
        for (g, cid) in cids.iter().enumerate().take(65535) {
            out[*cid as usize] = g as u16;
        }
        Some(out)
    }

    /// For each one-byte code, every glyph of the program a viewer might draw for it.
    fn simple_map(&mut self, doc: &Document, font: &Dictionary, program: ObjectId) -> Option<Box<[Option<Vec<u16>>]>> {
        let encoding = font.get_font_encoding(doc).ok();
        // Non-symbolic fonts with a Macintosh (1,0) cmap are read through the glyph's
        // MacRoman code (® is 0xAE in WinAnsi, 0xA8 in MacRoman).
        let mut mac = Dictionary::new();
        mac.set("Type", Object::Name(b"Font".to_vec()));
        mac.set("Encoding", Object::Name(b"MacRomanEncoding".to_vec()));
        let mac_roman = mac.get_font_encoding(doc).ok();
        let differences = differences(doc, font);
        let data = self.bytes(doc, program)?;
        let f = FontRef::new(data).ok()?;
        let glyphs = f.maxp().ok()?.num_glyphs();
        let cmap = f.cmap().ok();
        let subtables: Vec<_> = cmap
            .iter()
            .flat_map(|c| c.encoding_records().iter().filter_map(|r| r.subtable(c.offset_data()).ok()))
            .collect();
        // Glyphs by `post` name, and each glyph's name. CoreGraphics picks glyphs by name, so a
        // font with two glyphs of one name can draw either: both are kept.
        let mut by_name: HashMap<String, Vec<u16>> = HashMap::new();
        let mut names: Vec<Option<String>> = vec![None; glyphs as usize];
        if let Ok(post) = f.post() {
            for g in 0..glyphs {
                if let Some(n) = post.glyph_name(g.into()).filter(|n| !n.is_empty() && *n != ".notdef") {
                    by_name.entry(n.to_string()).or_default().push(g);
                    names[g as usize] = Some(n.to_string());
                }
            }
        }
        let mut out = vec![None; 256];
        for (c, slot) in out.iter_mut().enumerate() {
            let mut cps: Vec<u32> = vec![c as u32, 0xF000 + c as u32, 0xF100 + c as u32, 0xF200 + c as u32];
            if let Some(e) = &encoding
                && let Ok(s) = e.bytes_to_string(&[c as u8])
            {
                cps.extend(s.chars().map(u32::from));
                if let Some(m) = &mac_roman {
                    cps.extend(m.string_to_bytes(&s).into_iter().map(u32::from));
                }
            }
            let mut gids: Vec<u16> = vec![c as u16];
            if let Some(n) = &differences[c] {
                gids.extend(by_name.get(n.as_str()).into_iter().flatten());
                cps.extend(unicode_of_name(n));
                gids.extend(gid_of_name(n));
            }
            let before = gids.len();
            for t in &subtables {
                gids.extend(cps.iter().filter_map(|cp| t.map_codepoint(*cp)).map(|g| g.to_u32() as u16));
            }
            let mapped = gids.len() > before;
            gids.retain(|g| *g < glyphs);
            let same_name: Vec<u16> = gids
                .iter()
                .filter_map(|g| names[*g as usize].as_ref())
                .flat_map(|n| by_name.get(n).into_iter().flatten().copied())
                .collect();
            gids.extend(same_name);
            gids.sort_unstable();
            gids.dedup();
            *slot = mapped.then_some(gids);
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
    let hex = n
        .strip_prefix("uni")
        .filter(|h| h.len() == 4)
        .or_else(|| n.strip_prefix('u').filter(|h| (4..=6).contains(&h.len())))?;
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
    /// Streams walked: (id, resources, font in effect when drawn).
    visited: HashSet<(ObjectId, usize, usize)>,
    failed: bool,
    programs: Programs,
    cancel: Option<Arc<AtomicBool>>,
    cancelled: bool,
    ops: usize,
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
                    Map::Simple(m) => {
                        for b in text {
                            match &m[*b as usize] {
                                Some(g) => set.extend(g),
                                None => {
                                    self.keep_whole.insert(f.program);
                                }
                            }
                        }
                    }
                    Map::Cid(m, charset) => {
                        for c in text.as_chunks::<2>().0 {
                            let cid = u16::from_be_bytes([c[0], c[1]]);
                            set.insert(m.as_ref().map_or(cid, |m| m.get(cid as usize).copied().unwrap_or(0)));
                            // CFF outlines: a viewer may also go through the charset (CID-keyed
                            // fonts); both glyphs are kept, and the charset itself never changes.
                            if let Some(g) =
                                charset.as_ref().and_then(|cs| cs.get(cid as usize)).filter(|g| **g != u16::MAX)
                            {
                                set.insert(*g);
                            }
                        }
                    }
                }
            }
        }
    }

    /// Walks one content stream drawn with `resources`, and the streams it draws.
    /// `text` is the current font and its saved stack, carried across a page's content streams.
    fn walk<'a>(
        &mut self,
        doc: &'a Document,
        content: &[u8],
        resources: Option<&'a Dictionary>,
        depth: usize,
        text: &mut TextState<'a>,
    ) {
        if depth > MAX_DEPTH {
            self.failed = true;
            return;
        }
        let Ok(ops) = Content::decode(content) else {
            self.failed = true;
            return;
        };
        // lopdf stops at a token it cannot parse and returns what came before as a success,
        // while viewers skip the token and draw the rest. A parse that saw fewer text operators
        // than the raw bytes hold counts as failed.
        let shown = ops.operations.iter().filter(|o| matches!(o.operator.as_str(), "Tj" | "TJ" | "'" | "\"")).count();
        if shown < text_operator_tokens(content) {
            self.failed = true;
            return;
        }
        let res = |k: &[u8]| resources.and_then(|r| get(doc, r, k)).and_then(|o| dict(doc, o));
        let (fonts, xobjects, states) = (res(b"Font"), res(b"XObject"), res(b"ExtGState"));
        if let Some(r) = resources {
            self.side_streams(doc, r, depth);
        }
        let (font, saved) = (&mut text.0, &mut text.1);
        for op in &ops.operations {
            self.ops += 1;
            if self.ops.is_multiple_of(4096) && self.cancel.as_ref().is_some_and(|c| c.load(Ordering::Relaxed)) {
                self.cancelled = true;
                self.failed = true;
                return;
            }
            let args = &op.operands;
            match op.operator.as_str() {
                "q" => saved.push(*font),
                "Q" => *font = saved.pop().unwrap_or(*font),
                "Tf" => {
                    let n = args.first().and_then(|o| o.as_name().ok());
                    *font = n.and_then(|n| fonts.and_then(|f| f.get(n).ok())).and_then(|o| dict(doc, o));
                }
                "gs" => {
                    let n = args.first().and_then(|o| o.as_name().ok());
                    let state = n.and_then(|n| states.and_then(|s| s.get(n).ok())).and_then(|o| dict(doc, o));
                    if let Some(Object::Array(a)) = state.and_then(|s| get(doc, s, b"Font")) {
                        *font = a.first().and_then(|o| dict(doc, o)).or(*font);
                    }
                }
                "Tj" | "'" | "\"" | "TJ" => {
                    let Some(f) = *font else { continue };
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
                    let Some(Ok(id)) = n.and_then(|n| xobjects.and_then(|x| x.get(n).ok())).map(|o| o.as_reference())
                    else {
                        continue;
                    };
                    // A form starts with the graphics state of its `Do`, the current font included.
                    self.form(doc, id, resources, *font, depth);
                }
                _ => {}
            }
        }
    }

    /// A form-like stream (form XObject, pattern, glyph procedure, appearance) by id, drawn
    /// with its own resources or, lacking them, the caller's, and `font` as the current font
    /// (a form XObject inherits it from its `Do`; the others start without one).
    fn form<'a>(
        &mut self,
        doc: &'a Document,
        id: ObjectId,
        inherited: Option<&'a Dictionary>,
        font: Option<&'a Dictionary>,
        depth: usize,
    ) {
        let Ok(Object::Stream(s)) = doc.get_object(id) else { return };
        if name(doc, &s.dict, b"Subtype") == Some(b"Image") {
            return;
        }
        let res = get(doc, &s.dict, b"Resources").and_then(|o| dict(doc, o)).or(inherited);
        if !self.visited.insert((id, res.map_or(0, key), font.map_or(0, key))) {
            return;
        }
        match s.decompressed_content_with_limit(MAX_CONTENT) {
            Ok(data) => self.walk(doc, &data, res, depth + 1, &mut (font, Vec::new())),
            Err(_) => self.failed = true,
        }
    }

    /// Streams a resource dictionary carries besides the content that names it: tiling
    /// patterns, Type 3 glyph procedures and soft-mask groups. All are walked, drawn or not.
    fn side_streams<'a>(&mut self, doc: &'a Document, r: &'a Dictionary, depth: usize) {
        let sub = |k: &[u8]| get(doc, r, k).and_then(|o| dict(doc, o));
        for (_, p) in sub(b"Pattern").into_iter().flat_map(|d| d.iter()) {
            if let Ok(id) = p.as_reference() {
                self.form(doc, id, Some(r), None, depth);
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
                    self.form(doc, id, res, None, depth);
                }
            }
        }
        for (_, s) in sub(b"ExtGState").into_iter().flat_map(|d| d.iter()) {
            let mask = dict(doc, s).and_then(|s| get(doc, s, b"SMask")).and_then(|m| m.as_dict().ok());
            if let Some(Ok(id)) = mask.and_then(|m| m.get(b"G").ok()).map(|g| g.as_reference()) {
                self.form(doc, id, Some(r), None, depth);
            }
        }
    }
}

/// Text-showing operator tokens (`Tj`, `TJ`, `'`, `"`) in raw content bytes, standing between
/// delimiters. Never fewer than the real operators; bytes inside strings or inline images may
/// add more, which only makes the check above more cautious.
fn text_operator_tokens(content: &[u8]) -> usize {
    let delim = |b: u8| b.is_ascii_whitespace() || b"()<>[]{}/%".contains(&b);
    let mut n = 0;
    for i in 0..content.len() {
        let before = i == 0 || delim(content[i - 1]);
        let len = match &content[i..] {
            [b'T', b'j' | b'J', ..] => 2,
            [b'\'' | b'"', ..] => 1,
            _ => continue,
        };
        let after = content.get(i + len).is_none_or(|b| delim(*b));
        if before && after {
            n += 1;
        }
    }
    n
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
fn collect(
    doc: &Document,
    cancel: &Arc<AtomicBool>,
    held: &Arc<Held>,
) -> Result<(HashMap<ObjectId, BTreeSet<u16>>, Programs)> {
    let programs = Programs { held: Some(held.clone()), ..Default::default() };
    let mut u = Usage { cancel: Some(cancel.clone()), programs, ..Default::default() };
    for (_, page) in doc.get_pages() {
        let res = page_resources(doc, page);
        // The page's streams joined, within `placement::MAX_CONTENT`.
        match doc.get_page_content_with_limit(page, MAX_CONTENT) {
            Ok(data) => u.walk(doc, &data, res, 0, &mut (None, Vec::new())),
            Err(_) => u.failed = true,
        }
        let annots = doc.get_dictionary(page).ok().and_then(|p| get(doc, p, b"Annots")).and_then(|a| a.as_array().ok());
        for a in annots.into_iter().flatten() {
            let ap = dict(doc, a).and_then(|a| get(doc, a, b"AP")).and_then(|o| o.as_dict().ok());
            for (_, look) in ap.into_iter().flat_map(|d| d.iter()) {
                match look {
                    Object::Reference(id) if matches!(doc.get_object(*id), Ok(Object::Stream(_))) => {
                        u.form(doc, *id, None, None, 0)
                    }
                    o => {
                        for (_, s) in dict(doc, o).into_iter().flat_map(|d| d.iter()) {
                            if let Ok(id) = s.as_reference() {
                                u.form(doc, id, None, None, 0);
                            }
                        }
                    }
                }
            }
        }
        if u.cancelled {
            return Err(EngineError::cancelled());
        }
        if u.programs.over {
            return Err(too_much());
        }
        if u.failed {
            return Ok((HashMap::new(), u.programs));
        }
    }
    let mut skip = unscanned_programs(doc, &u);
    skip.extend(&u.keep_whole);
    if u.programs.over {
        return Err(too_much());
    }
    let used = u.used.into_iter().filter(|(p, _)| !skip.contains(p)).collect();
    Ok((used, u.programs))
}

/// The program holding only `gids` (plus `.notdef`), glyph ids unchanged.
/// The CFF data of a program: the program itself (bare CFF) or its sfnt's `CFF ` table.
fn cff_table(data: &[u8]) -> Option<&[u8]> {
    if data.first() == Some(&1) {
        return Some(data);
    }
    FontRef::new(data).ok()?.table_data(Tag::new(b"CFF ")).map(|d| d.as_bytes())
}

/// A CFF program (bare, or the `CFF ` table of an sfnt) with the glyphs not in `gids` reduced
/// to `endchar`; checked to keep the glyph count, every glyph's charset entry and every kept
/// glyph's charstring.
fn subset_cff(data: &[u8], gids: &BTreeSet<u16>) -> Result<Vec<u8>, String> {
    let table = cff_table(data).ok_or("no CFF")?;
    // An accented glyph made with `seac` draws two other glyphs: they stay.
    let mut gids = gids.clone();
    gids.extend(cff::seac_components(table, &gids).ok_or("charstrings not evaluated")?);
    let gids = &gids;
    let keep = |g: usize| g <= u16::MAX as usize && gids.contains(&(g as u16));
    let new = cff::subset(table, &keep).ok_or("CFF layout not handled")?;
    let (old_cs, new_cs) = (cff::charstrings(table).ok_or("CFF")?, cff::charstrings(&new).ok_or("CFF rewrite")?);
    if old_cs.len() != new_cs.len()
        || old_cs.iter().zip(&new_cs).enumerate().any(|(g, (a, b))| (g == 0 || keep(g)) && a != b)
    {
        return Err("charstrings changed".into());
    }
    if cff::cids(table) != cff::cids(&new) {
        return Err("charset changed".into());
    }
    // A CID-keyed font must have had its charset read: glyphs were chosen through it.
    if cff::is_cid(table) && cff::cids(table).is_none() {
        return Err("CID-keyed charset not read".into());
    }
    if data.first() == Some(&1) {
        return Ok(new);
    }
    // An sfnt: the same tables with the new `CFF `, layout tables dropped.
    let font = FontRef::new(data).map_err(|e| format!("read: {e}"))?;
    let mut b = write_fonts::FontBuilder::new();
    b.add_raw(Tag::new(b"CFF "), new);
    for rec in font.table_directory.table_records() {
        let tag = rec.tag();
        if tag == Tag::new(b"CFF ") || DROP.iter().any(|t| Tag::new(t) == tag) {
            continue;
        }
        if let Some(d) = font.table_data(tag) {
            b.add_raw(tag, d.as_bytes().to_vec());
        }
    }
    Ok(b.build())
}

fn subset(data: &[u8], gids: &BTreeSet<u16>) -> Result<Vec<u8>, String> {
    if cff_table(data).is_some() {
        return subset_cff(data, gids);
    }
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
    let mut plan =
        Plan::new(&input, &IntSet::empty(), &font, flags, &drop, &empty_tags, &empty_tags, &names, &languages);
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
pub fn subset_fonts(doc: &mut Document, cancel: &Arc<AtomicBool>, held: &Arc<Held>) -> Result<usize> {
    let (used, mut programs) = collect(doc, cancel, held)?;
    // Moved out of the cache, not copied: the programs are held once.
    let jobs: Vec<(ObjectId, Vec<u8>, BTreeSet<u16>)> =
        used.into_iter().filter_map(|(id, gids)| Some((id, programs.data.remove(&id).flatten()?, gids))).collect();
    drop(programs);
    let done: Vec<(ObjectId, Vec<u8>, usize)> = jobs
        .into_par_iter()
        .filter_map(|(id, data, gids)| {
            if cancel.load(Ordering::Relaxed) {
                return None;
            }
            let out = subset(&data, &gids).ok()?;
            let n = out.len();
            Some((id, deflate::zlib(&out, 9), n))
        })
        .collect();
    if cancel.load(Ordering::Relaxed) {
        return Err(EngineError::cancelled());
    }
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
    Ok(count)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A name-keyed CFF: .notdef, A, acute, and Aacute drawn as `seac` of A and acute.
    fn seac_font() -> (Vec<u8>, [usize; 3]) {
        use read_fonts::ps::Sid;
        let sid = |n: &[u8]| (0..391u16).find(|s| Sid::new(*s).resolve_standard().ok() == Some(n)).unwrap();
        let int5 = |v: usize| {
            let b = (v as i32).to_be_bytes();
            [29, b[0], b[1], b[2], b[3]]
        };
        let path: &[u8] = &[239, 239, 21, 189, 139, 5, 14]; // 100 100 rmoveto 50 0 rlineto endchar
        let seac: &[u8] = &[139, 139, 204, 247, 86, 14]; // 0 0 65 194 endchar
        let charstrings: Vec<&[u8]> = vec![&[14], path, path, seac];
        let names = [&b"A"[..], b"acute", b"Aacute"];
        let header = [1u8, 0, 4, 1];
        let name_index = cff::test_index(&[b"X"]);
        // Top DICT with five-byte offsets: charset, CharStrings, Private [0 offset].
        let top_len = 5 + 1 + 5 + 1 + 1 + 5 + 1;
        let top_index_len = 2 + 1 + 2 + top_len;
        let charset_at = header.len() + name_index.len() + top_index_len + 2 + 2;
        let charset: Vec<u8> = std::iter::once(0u8).chain(names.iter().flat_map(|n| sid(n).to_be_bytes())).collect();
        let cs_at = charset_at + charset.len();
        let cs_index = cff::test_index(&charstrings);
        let private_at = cs_at + cs_index.len();
        let mut top = Vec::new();
        top.extend(int5(charset_at));
        top.push(15);
        top.extend(int5(cs_at));
        top.push(17);
        top.push(139);
        top.extend(int5(private_at));
        top.push(18);
        assert_eq!(top.len(), top_len);
        let mut out = header.to_vec();
        out.extend(name_index);
        out.extend(cff::test_index(&[&top]));
        out.extend([0, 0, 0, 0]); // String and Global Subr INDEXes, empty
        assert_eq!(out.len(), charset_at);
        out.extend(charset);
        out.extend(cs_index);
        (out, [1, 2, 3])
    }

    #[test]
    fn seac_components_are_kept() {
        let (font, [a, acute, aacute]) = seac_font();
        let kept: BTreeSet<u16> = [aacute as u16].into();
        let out = subset(&font, &kept).unwrap();
        let cs = cff::charstrings(&out).unwrap();
        assert!(cs[a].len() > 1 && cs[acute].len() > 1, "a seac component was emptied");
        assert_eq!(cs[aacute], cff::charstrings(&font).unwrap()[aacute]);
        // Without the accented glyph, both go.
        let out = subset(&font, &[a as u16].into()).unwrap();
        assert_eq!(cff::charstrings(&out).unwrap()[acute], &[14][..]);
    }

    #[test]
    fn text_tokens() {
        assert_eq!(text_operator_tokens(b"BT /F1 9 Tf (a)Tj [(b) 3 (c)]TJ (d) ' 1 2 (e) \" ET"), 4);
        assert_eq!(text_operator_tokens(b"(don't) Tj /TjX 1 0 0 1 0 0 cm"), 1);
        // A token lopdf cannot parse ends its parse; the raw count still sees the text after it.
        let content = b"BT /F1 9 Tf (a) Tj ET 1 2 m - 3 l BT (b) Tj ET";
        let ops = Content::decode(content).map(|c| c.operations.len()).unwrap_or(0);
        assert!(text_operator_tokens(content) == 2 && ops > 0);
    }

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
