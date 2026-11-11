// SPDX-License-Identifier: GPL-3.0-or-later
//! `pdf.optimise`: rewrites a PDF without changing what it shows or contains. Fonts, text,
//! annotations, forms, outlines, the structure tree and every other object stay as they are;
//! what changes is how streams are stored:
//!
//! - images are downsampled to `dpi` when drawn denser, and stored as the smaller of a JPEG at
//!   the compression factor's ceiling (only where that is safe, see `images`) and Flate with PNG
//!   predictors; JPEGs are re-encoded only when downsampled or, with a `dpi`, above the ceiling,
//!   and otherwise only re-coded losslessly; at compression 0 no image is touched;
//! - every other Flate or uncompressed stream is recompressed with libdeflate's strongest level;
//! - embedded TrueType and CFF fonts keep only the glyphs the document draws (see `fonts`);
//! - large inline images are moved into image XObjects first (see `inline`);
//! - identical streams are stored once, unreachable objects are dropped, and the rest go into
//!   object streams with a cross-reference stream;
//! - with `strip`, the document information dictionary, the catalog's XMP, page thumbnails and
//!   application private data (`/PieceInfo`) are removed.
//!
//! Encrypted input that opens without a password (an owner password with an empty user one) is
//! rewritten and encrypted again with its own security handler: the same algorithm, key length,
//! `/O`, `/U`, `/P` and crypt filters, and the same file key; the output is reopened and must
//! give back exactly that. Input that needs a password is refused (`unsupported`), and so is
//! input lopdf cannot read completely
//! (`decode`): a rewrite of a damaged file could silently lose pages.

mod budget;
mod cff;
mod deflate;
mod fonts;
mod images;
mod inline;
mod integrity;
mod mono;
mod placement;
#[cfg(test)]
mod tests;

use crate::ctx::Ctx;
use crate::error::{EngineError, Result};
use crate::ops::{Encoded, compression, finish, open, parse_params};
use crate::protocol::{Format, OpResult, PdfParams, Request};
use crate::quality;
use images::ImagePlan;
use lopdf::{Document, LoadOptions, Object, ObjectId, SaveOptions, Stream};
use rayon::prelude::*;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::atomic::{AtomicUsize, Ordering};

pub fn optimise(req: &Request, ctx: &Ctx) -> Result<OpResult> {
    let (p, ignored) = parse_params::<PdfParams>(&req.params)?;
    let factor = compression(p.compression)?;
    let dpi = match p.dpi {
        None | Some(0) => None,
        Some(d) if (48..=300).contains(&d) => (d < 300).then_some(d as f64),
        Some(_) => return Err(EngineError::invalid("`dpi` must be 0 or 48..=300")),
    };
    let (bytes, target) = open(req, &p.out)?;
    let settings = Settings::new(factor, dpi, p.out.strip);
    let (out, lossy) = rewrite(&bytes, &settings, ctx)?;
    let q = settings.jpeg_quality;
    let enc =
        Encoded { bytes: out, format: Some(Format::Pdf), quality: lossy.then_some(q), lossy, ..Default::default() };
    finish(&target, bytes.len() as u64, enc, p.out.allow_larger.unwrap_or(false), ignored, ctx)
}

/// JPEG quality for images: the compression factor's ceiling, capped where L'Esclop's
/// Ghostscript settings capped it (`/QFactor` 0.68 above 100 dpi, 0.76 at 100, 1.0 at 72 and 1.3
/// at 48, which are libjpeg qualities 66, 62, 50 and 38).
pub fn jpeg_quality(factor: u8, dpi: Option<f64>) -> u8 {
    let cap = match dpi {
        Some(d) if d <= 48.0 => 38,
        Some(d) if d <= 72.0 => 50,
        Some(d) if d <= 100.0 => 62,
        _ => 66,
    };
    quality::jpeg_max_quality(factor).min(cap)
}

/// What one rewrite does.
#[derive(Clone, Copy)]
pub struct Settings {
    /// Downsample images drawn denser than this; `None` keeps every image's resolution.
    pub dpi: Option<f64>,
    pub jpeg_quality: u8,
    /// The page gate: SSIM 0.98 at default settings, 0.95 when aggressive.
    pub min_ssim: f64,
    /// The lowest SSIM any one image may keep, however little of its page it covers: 0.90 at
    /// default settings, 0.85 when aggressive (a signature or a QR code is small and must stay
    /// legible).
    pub image_floor: f64,
    pub strip: bool,
    /// False at compression 0: images stay exactly as stored.
    pub images: bool,
}

impl Settings {
    pub fn new(factor: u8, dpi: Option<f64>, strip: bool) -> Self {
        Self {
            dpi,
            jpeg_quality: jpeg_quality(factor, dpi),
            min_ssim: if factor <= 40 { 0.98 } else { 0.95 },
            image_floor: if factor <= 40 { 0.90 } else { 0.85 },
            strip,
            images: factor > 0,
        }
    }
}

/// The rewritten file and whether any image lost information. Without `dpi` (no downsampling)
/// JPEG images are only re-coded losslessly, as Ghostscript passed them through.
pub fn rewrite(bytes: &[u8], settings: &Settings, ctx: &Ctx) -> Result<(Vec<u8>, bool)> {
    let Settings { dpi, jpeg_quality, min_ssim, image_floor, strip, images } = *settings;
    let head = &bytes[..bytes.len().min(1024)];
    if !head.windows(5).any(|w| w == b"%PDF-") {
        return Err(EngineError::unsupported("not a PDF"));
    }
    if bytes.len() > budget::MAX_INPUT {
        return Err(EngineError::unsupported(format!("PDFs over {} MB are not rewritten", budget::MAX_INPUT >> 20)));
    }
    ctx.progress(0.02, "decode");
    let options = LoadOptions {
        max_decompressed_size: Some(budget::MAX_LOAD_STREAM),
        filter: Some(budget::load_filter),
        ..Default::default()
    };
    ctx.check()?;
    budget::start_load();
    let mut loaded = Document::load_mem_with_options(bytes, options.clone());
    // With a filter lopdf no longer rebuilds a damaged file's page tree by scanning for its
    // objects, as it does without one: done here, through the same filter, when the load came
    // back without pages.
    if loaded.as_ref().is_ok_and(|d| d.get_pages().is_empty()) && budget::loaded() <= budget::MAX_HELD {
        budget::start_load();
        let options = LoadOptions { force_reconstruct: true, ..options };
        if let Ok(rebuilt) = Document::load_mem_with_options(bytes, options)
            && !rebuilt.get_pages().is_empty()
        {
            loaded = Ok(rebuilt);
        }
    }
    // lopdf loads an encrypted file without the filter: what it holds is counted afterwards.
    if let Ok(d) = &loaded
        && d.was_encrypted()
    {
        budget::start_load();
        d.objects.values().for_each(budget::count);
    }
    if budget::loaded() > budget::MAX_HELD {
        return Err(budget::too_much());
    }
    let held = std::sync::Arc::new(budget::Held::new(budget::loaded()));
    let mut doc = match loaded {
        Ok(d) => d,
        Err(lopdf::Error::Decompress(lopdf::DecompressError::MemoryLimitExceeded { .. })) => {
            return Err(EngineError::unsupported(format!(
                "this PDF has an object stream over {} MB",
                budget::MAX_LOAD_STREAM >> 20
            )));
        }
        Err(e) if is_encrypted(bytes) => return Err(EngineError::unsupported(format!("encrypted PDF: {e}"))),
        Err(e) => return Err(EngineError::decode(format!("unreadable PDF: {e}"))),
    };
    if doc.is_encrypted() {
        return Err(EngineError::unsupported("this PDF needs a password"));
    }
    // Set when lopdf opened the file with the empty user password: the output is encrypted
    // again with it, never left unprotected.
    let encryption = doc.encryption_state.clone();
    // Whether the file is encrypted is read from its bytes too: lopdf can drop an `/Encrypt`
    // it does not follow (pdf.js issue7665, `/CF` given by reference) and hand back undecrypted
    // strings as if the file were plain; writing that out would lose the protection and the text.
    if encryption.is_none() && names_encryption(bytes, &doc) {
        return Err(EngineError::unsupported("this PDF's encryption cannot be read and written again"));
    }
    let handler = match &encryption {
        Some(state) => {
            let dict = state.encode().map_err(|e| EngineError::unsupported(format!("encryption: {e}")))?;
            if dict.get(b"Filter").and_then(|f| f.as_name()).ok() != Some(b"Standard") {
                return Err(EngineError::unsupported("only the standard security handler is rewritten"));
            }
            // From V4 on, the crypt filters /StmF and /StrF name must be defined: lopdf leaves
            // them out when `/CF` is a reference (pdf.js issue7665) and would then decrypt and
            // encrypt nothing.
            if dict.get(b"V").and_then(|v| v.as_i64()).unwrap_or(0) >= 4 {
                let cf = dict.get(b"CF").and_then(|c| c.as_dict()).ok();
                for key in [&b"StmF"[..], b"StrF"] {
                    let name = dict.get(key).and_then(|n| n.as_name()).unwrap_or(b"Identity");
                    if name != b"Identity" && !cf.is_some_and(|cf| cf.has(name)) {
                        return Err(EngineError::unsupported("this PDF's crypt filters cannot be read"));
                    }
                }
            }
            // Per-stream crypt filters (`/Crypt` in a stream's filters) and a separate filter for
            // embedded files are not reproduced: lopdf would encrypt those streams with the
            // default filter (pdf.js crypt_filters lost the text of two forms).
            let per_stream = doc
                .objects
                .values()
                .any(|o| matches!(o, Object::Stream(s) if s.filters().is_ok_and(|f| f.iter().any(|n| *n == b"Crypt"))));
            let eff = dict.get(b"EFF").and_then(|n| n.as_name()).ok();
            if per_stream || eff.is_some_and(|e| Some(e) != dict.get(b"StmF").and_then(|n| n.as_name()).ok()) {
                return Err(EngineError::unsupported("this PDF's per-stream encryption is not reproduced"));
            }
            Some(dict)
        }
        None => None,
    };
    // A rewrite moves every byte a signature's /ByteRange covers, and Reader usage rights
    // (/Perms /UR3) are a signature too.
    if is_signed(&doc) {
        return Err(EngineError::unsupported("Signed PDFs are left as they are, so their signatures stay valid"));
    }
    ctx.check()?;
    integrity::check(bytes, &doc, &ctx.cancel_flag())?;
    let pages = check_complete(&doc, ctx)?;
    ctx.check()?;

    if strip {
        strip_metadata(&mut doc);
    }
    // Before the placement walk, so the moved images get their drawn size.
    inline::move_inline_images(&mut doc, &ctx.cancel_flag())?;
    // Unreachable fonts would otherwise count as used by something the font scan cannot see.
    doc.prune_objects();
    ctx.progress(0.03, "fonts");
    fonts::subset_fonts(&mut doc, &ctx.cancel_flag(), &held)?;
    ctx.check()?;
    let drawn = placement::image_resolutions(&doc, &ctx.cancel_flag())?;
    let masks = mask_ids(&doc);
    let matted = matte_parents(&doc);

    // Recompress every stream in parallel from the unchanged document, then apply.
    let ids: Vec<ObjectId> =
        doc.objects.iter().filter(|(_, o)| matches!(o, Object::Stream(_))).map(|(id, _)| *id).collect();
    let done = AtomicUsize::new(0);
    let lossy = AtomicUsize::new(0);
    let cancel = ctx.cancel_flag();
    let total = ids.len().max(1);
    let budget = budget::Budget::new();
    let replaced: Vec<(ObjectId, Stream)> = ids
        .par_iter()
        .map(|id| -> Result<Option<(ObjectId, Stream)>> {
            if cancel.load(Ordering::Relaxed) {
                return Err(EngineError::cancelled());
            }
            let Ok(Object::Stream(s)) = doc.get_object(*id) else { return Ok(None) };
            let new = if s.dict.get(b"Subtype").and_then(|t| t.as_name()).ok() == Some(b"Image") {
                if !images {
                    return Ok(None);
                }
                let plan = ImagePlan {
                    jpeg_quality,
                    // Masks are never resampled, and a /Matte mask must keep its image's size.
                    dpi: dpi.filter(|_| !matted.contains(id)),
                    drawn_dpi: drawn.get(id).map(|p| p.dpi),
                    is_mask: masks.contains(id),
                    // Without downsampling a JPEG is passed through (re-coded losslessly).
                    reencode_jpeg: dpi.is_some(),
                    // Each image may lose its share of the page's SSIM budget (see `placement`).
                    min_ssim: image_gate(min_ssim, image_floor, drawn.get(id).map(|p| p.allowance)),
                };
                let new = match images::recompress(&doc, s, &plan, &budget) {
                    Ok(n) => n,
                    Err(e) if budget.exhausted() => return Err(e),
                    Err(_) => None,
                };
                if new.as_ref().is_some_and(|(n, changed)| *changed && n.content.len() < s.content.len()) {
                    lossy.fetch_add(1, Ordering::Relaxed);
                }
                new.map(|(n, _)| n)
            } else {
                recompress_stream(s, &budget)?
            };
            let n = done.fetch_add(1, Ordering::Relaxed) + 1;
            if n.is_multiple_of(16) {
                ctx.progress(0.05 + 0.85 * n as f32 / total as f32, "compress");
            }
            Ok(new.filter(|n| n.content.len() < s.content.len()).map(|n| (*id, n)))
        })
        .collect::<Result<Vec<_>>>()?
        .into_iter()
        .flatten()
        .collect();
    ctx.check()?;
    for (id, s) in replaced {
        doc.objects.insert(id, Object::Stream(s));
    }

    ctx.check()?;
    dedupe_streams(&mut doc);
    doc.prune_objects();
    doc.renumber_objects();
    if doc.version.as_str() < "1.5" {
        doc.version = "1.5".into();
    }
    if let Some(state) = &encryption {
        doc.encrypt(state).map_err(|e| EngineError::encode(format!("encrypting the PDF again: {e}")))?;
    }
    ctx.progress(0.92, "write");
    let mut writer = budget::CappedWriter::new(budget::max_output(bytes.len()), ctx.cancel_flag());
    // Strings inside an object stream are not encrypted one by one (the stream is): lopdf
    // packs objects after encrypting them, so an encrypted file keeps every object on its own.
    let packed = encryption.is_none();
    let save = SaveOptions::builder().use_object_streams(packed).use_xref_streams(packed).compression_level(9).build();
    if let Err(e) = doc.save_with_options(&mut writer, save) {
        ctx.check()?;
        return Err(if writer.buf.len() + (1 << 20) > budget::max_output(bytes.len()) {
            EngineError::unsupported("the rewritten PDF would be more than twice the size of the original")
        } else {
            EngineError::encode(format!("writing the PDF: {e}"))
        });
    }
    let out = writer.buf;

    ctx.check()?;
    // The result must read back with every page.
    let back =
        Document::load_mem(&out).map_err(|e| EngineError::internal(format!("rewritten PDF does not load: {e}")))?;
    if back.get_pages().len() != pages {
        return Err(EngineError::internal("rewritten PDF lost pages"));
    }
    // Encrypted again exactly as it was: same handler dictionary, same file key.
    if let (Some(before), Some(state)) = (&handler, &encryption) {
        let after = back
            .encryption_state
            .as_ref()
            .ok_or_else(|| EngineError::internal("the rewritten PDF lost its encryption"))?;
        let same_dict = after.encode().ok().as_ref() == Some(before);
        if !same_dict || after.file_encryption_key() != state.file_encryption_key() {
            return Err(EngineError::internal("the rewritten PDF's encryption differs from the original's"));
        }
    }
    Ok((out, lossy.load(Ordering::Relaxed) > 0))
}

/// The SSIM an image must keep: its share of the page gate's loss (an image covering a tenth of
/// its page may lose ten times what the page may), never below `floor`.
fn image_gate(min_ssim: f64, floor: f64, allowance: Option<f64>) -> f64 {
    allowance.map_or(min_ssim, |a| 1.0 - (1.0 - min_ssim) * a).max(floor)
}

/// A catalog `/Perms` (DocMDP, UR3), or any signature value (a dictionary with `/ByteRange`).
fn is_signed(doc: &Document) -> bool {
    fn has_byte_range(o: &Object, depth: usize) -> bool {
        if depth > 32 {
            return false;
        }
        match o {
            Object::Dictionary(d) => d.has(b"ByteRange") || d.iter().any(|(_, v)| has_byte_range(v, depth + 1)),
            Object::Stream(s) => s.dict.iter().any(|(_, v)| has_byte_range(v, depth + 1)),
            Object::Array(a) => a.iter().any(|v| has_byte_range(v, depth + 1)),
            _ => false,
        }
    }
    let perms = doc.catalog().ok().and_then(|c| c.get(b"Perms").ok()).map(|p| match p {
        Object::Reference(r) => doc.get_object(*r).unwrap_or(p),
        p => p,
    });
    if perms.and_then(|p| p.as_dict().ok()).is_some_and(|d| !d.is_empty()) {
        return true;
    }
    doc.objects.values().any(|o| has_byte_range(o, 0))
}

/// Whether a trailer names an `/Encrypt` dictionary: the one lopdf read, a cross-reference
/// stream's, or any `trailer` dictionary in the file (text that merely contains the word does not
/// count).
fn names_encryption(bytes: &[u8], doc: &Document) -> bool {
    if doc.trailer.has(b"Encrypt") {
        return true;
    }
    let xref_stream = doc.objects.values().any(|o| {
        matches!(o, Object::Stream(s) if s.dict.get(b"Type").and_then(|t| t.as_name()).ok() == Some(b"XRef")
            && s.dict.has(b"Encrypt"))
    });
    if xref_stream {
        return true;
    }
    let find = |hay: &[u8], needle: &[u8]| hay.windows(needle.len()).position(|w| w == needle);
    let mut at = 0;
    while let Some(p) = find(&bytes[at..], b"trailer") {
        let start = at + p + 7;
        let end = find(&bytes[start..], b"startxref").map_or(bytes.len(), |e| start + e);
        if find(&bytes[start..end], b"/Encrypt").is_some() {
            return true;
        }
        at = start;
    }
    false
}

fn is_encrypted(bytes: &[u8]) -> bool {
    let tail = &bytes[bytes.len().saturating_sub(64 << 10)..];
    tail.windows(8).any(|w| w == b"/Encrypt")
}

/// Every page resolves and its content decodes, and the page tree's count agrees. Returns the
/// page count.
fn check_complete(doc: &Document, ctx: &Ctx) -> Result<usize> {
    let pages = doc.get_pages();
    if pages.is_empty() {
        return Err(EngineError::decode("the PDF has no readable pages"));
    }
    let count = doc
        .catalog()
        .ok()
        .and_then(|c| c.get(b"Pages").ok())
        .and_then(|p| p.as_reference().ok())
        .and_then(|id| doc.get_dictionary(id).ok())
        .and_then(|d| d.get(b"Count").ok())
        .and_then(|c| c.as_i64().ok());
    if count != Some(pages.len() as i64) {
        return Err(EngineError::decode("the page tree is incomplete"));
    }
    for id in pages.values() {
        ctx.check()?;
        let page = doc.get_dictionary(*id).map_err(|e| EngineError::decode(format!("page {id:?}: {e}")))?;
        let refs: Vec<ObjectId> = match page.get(b"Contents") {
            Ok(Object::Reference(r)) => match doc.get_object(*r) {
                Ok(Object::Array(a)) => a.iter().filter_map(|o| o.as_reference().ok()).collect(),
                _ => vec![*r],
            },
            Ok(Object::Array(a)) => a.iter().filter_map(|o| o.as_reference().ok()).collect(),
            _ => vec![],
        };
        for r in refs {
            let s = doc
                .get_object(r)
                .and_then(|o| o.as_stream())
                .map_err(|_| EngineError::decode("a page's content is missing"))?;
            if s.filters().is_ok() && s.decompressed_content_with_limit(budget::MAX_STREAM).is_err() {
                return Err(EngineError::decode("a page's content does not decode"));
            }
        }
    }
    Ok(pages.len())
}

/// Ids of images used as another image's `/SMask` or `/Mask`.
fn mask_ids(doc: &Document) -> HashSet<ObjectId> {
    let mut out = HashSet::new();
    for o in doc.objects.values() {
        if let Object::Stream(s) = o {
            for k in [b"SMask".as_slice(), b"Mask"] {
                if let Ok(Object::Reference(r)) = s.dict.get(k) {
                    out.insert(*r);
                }
            }
        }
    }
    out
}

/// Ids of images whose `/SMask` has `/Matte` (pre-multiplied colour).
fn matte_parents(doc: &Document) -> HashSet<ObjectId> {
    let mut out = HashSet::new();
    for (id, o) in &doc.objects {
        if let Object::Stream(s) = o
            && let Ok(Object::Reference(m)) = s.dict.get(b"SMask")
            && doc.get_object(*m).and_then(|m| m.as_stream()).is_ok_and(|m| m.dict.has(b"Matte"))
        {
            out.insert(*id);
        }
    }
    out
}

/// Flate or unfiltered streams other than images, recompressed. Metadata streams stay as they
/// are (PDF/A wants XMP readable without decoding), and so do streams with predictors or other
/// filters.
fn recompress_stream(s: &Stream, budget: &budget::Budget) -> Result<Option<Stream>> {
    let d = &s.dict;
    let ty = d.get(b"Type").and_then(|t| t.as_name()).ok();
    if matches!(ty, Some(b"Metadata" | b"XRef" | b"ObjStm")) || d.has(b"DecodeParms") {
        return Ok(None);
    }
    let filters = s.filters().unwrap_or_default();
    if !filters.iter().all(|f| matches!(*f, b"FlateDecode" | b"Fl")) || filters.len() > 1 {
        return Ok(None);
    }
    // Room for twenty times the stored size: a stream that inflates more is already compact
    // and stays as stored.
    let room = (s.content.len() * 20).clamp(1 << 20, budget::MAX_STREAM);
    let Some(_hold) = budget.hold(room * 2)? else { return Ok(None) };
    // No filter (or an empty `/Filter []`, which lopdf decodes to nothing): the stored bytes are
    // the data.
    // Strict inflate, not lopdf's: lopdf stopped 5 kB short of a valid 165 kB font program
    // (pdf.js issue13316) without an error, and the rewrite stored the truncated font.
    let data = if filters.is_empty() {
        s.content.clone()
    } else {
        match miniz_oxide::inflate::decompress_to_vec_zlib_with_limit(&s.content, room) {
            Ok(d) => d,
            Err(_) => return Ok(None),
        }
    };
    if data.is_empty() && !s.content.is_empty() {
        return Ok(None);
    }
    // Font programs declare their decoded length.
    if d.get(b"Length1").and_then(|l| l.as_i64()).is_ok_and(|l| l as usize != data.len()) && !d.has(b"Length2") {
        return Ok(None);
    }
    // libdeflate's level 12 runs at a few MB/s; large streams (fonts, big drawings) get 9.
    let packed = deflate::zlib(&data, if data.len() > 256 << 10 { 9 } else { 12 });
    if packed.len() >= s.content.len() {
        return Ok(None);
    }
    let mut nd = d.clone();
    nd.set("Filter", Object::Name(b"FlateDecode".to_vec()));
    Ok(Some(Stream::new(nd, packed)))
}

fn strip_metadata(doc: &mut Document) {
    doc.trailer.remove(b"Info");
    if let Ok(cat) = doc.catalog_mut() {
        cat.remove(b"Metadata");
        cat.remove(b"PieceInfo");
    }
    let pages: Vec<ObjectId> = doc.get_pages().values().copied().collect();
    for id in pages {
        if let Ok(p) = doc.get_dictionary_mut(id) {
            p.remove(b"Thumb");
            p.remove(b"PieceInfo");
        }
    }
}

/// Stores byte-identical streams (same dictionary, same data) once.
fn dedupe_streams(doc: &mut Document) {
    let mut first: HashMap<(u64, usize), Vec<ObjectId>> = HashMap::new();
    let mut map: BTreeMap<ObjectId, ObjectId> = BTreeMap::new();
    for (id, o) in &doc.objects {
        let Object::Stream(s) = o else { continue };
        if matches!(s.dict.get(b"Type").and_then(|t| t.as_name()).ok(), Some(b"XRef" | b"ObjStm")) {
            continue;
        }
        let key = (hash(&s.content, &format!("{:?}", s.dict)), s.content.len());
        let bucket = first.entry(key).or_default();
        let same = bucket.iter().find(|k| match doc.objects.get(k) {
            Some(Object::Stream(t)) => t.content == s.content && format!("{:?}", t.dict) == format!("{:?}", s.dict),
            _ => false,
        });
        match same {
            Some(k) => {
                map.insert(*id, *k);
            }
            None => bucket.push(*id),
        }
    }
    if map.is_empty() {
        return;
    }
    fn fix(o: &mut Object, map: &BTreeMap<ObjectId, ObjectId>) {
        match o {
            Object::Reference(r) => {
                if let Some(k) = map.get(r) {
                    *r = *k;
                }
            }
            Object::Array(a) => a.iter_mut().for_each(|o| fix(o, map)),
            Object::Dictionary(d) => d.iter_mut().for_each(|(_, o)| fix(o, map)),
            Object::Stream(s) => s.dict.iter_mut().for_each(|(_, o)| fix(o, map)),
            _ => {}
        }
    }
    for o in doc.objects.values_mut() {
        fix(o, &map);
    }
    doc.trailer.iter_mut().for_each(|(_, o)| fix(o, &map));
    for id in map.keys() {
        doc.objects.remove(id);
    }
}

fn hash(data: &[u8], dict: &str) -> u64 {
    let mut h = crc32fast::Hasher::new();
    h.update(dict.as_bytes());
    h.update(data);
    let a = h.finalize() as u64;
    (a << 32) | (data.len() as u64 & 0xffff_ffff)
}
