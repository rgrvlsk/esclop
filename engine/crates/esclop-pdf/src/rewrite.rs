// SPDX-License-Identifier: MPL-2.0
//! The rewrite itself: load and check, fonts, image placement, recompression in batches, write
//! and read back. See the crate documentation for what changes.

use crate::error::{Failure, Result};
use crate::images::ImagePlan;
use crate::{Ctx, KeptReason, Options, Report, Stage, budget, deflate, fonts, images, inline, integrity, placement};
use lopdf::{Document, LoadOptions, Object, ObjectId, SaveOptions, Stream};
use rayon::prelude::*;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::atomic::{AtomicUsize, Ordering};

#[cfg(test)]
#[path = "tests.rs"]
pub(crate) mod tests;

/// JPEG quality for images: the compression factor's ceiling, capped where L'Esclop's former
/// Ghostscript settings capped it (`/QFactor` 0.68 above 100 dpi, 0.76 at 100, 1.0 at 72 and 1.3
/// at 48, which are libjpeg qualities 66, 62, 50 and 38).
/// Stored stream data recompressed per batch (see `rewrite`).
const BATCH: usize = 64 << 20;

pub fn jpeg_quality(factor: u8, dpi: Option<f64>) -> u8 {
    let cap = match dpi {
        Some(d) if d <= 48.0 => 38,
        Some(d) if d <= 72.0 => 50,
        Some(d) if d <= 100.0 => 62,
        _ => 66,
    };
    crate::jpeg_max_quality(factor).min(cap)
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
    /// See `Options::memory_budget`.
    pub memory_budget: usize,
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
            memory_budget: Options::DEFAULT_MEMORY_BUDGET,
        }
    }

    pub fn from_options(o: &Options) -> Self {
        let dpi = o.max_dpi().filter(|d| *d < 300).map(f64::from);
        Self { memory_budget: o.memory_budget(), ..Self::new(o.compression(), dpi, o.strip_metadata()) }
    }
}

/// The rewritten file and whether any image lost information. Without `dpi` (no downsampling)
/// JPEG images are only re-coded losslessly, as Ghostscript passed them through.
/// The input is dropped once the checks that read its raw bytes are done: from then on lopdf's
/// copy of its streams is the only one.
pub fn rewrite(input: Vec<u8>, settings: &Settings, ctx: Ctx) -> Result<(Vec<u8>, Report)> {
    let bytes = input.as_slice();
    let Settings { dpi, jpeg_quality, min_ssim, image_floor, strip, images, memory_budget } = *settings;
    let mut report = Report { bytes_before: bytes.len() as u64, metadata_stripped: strip, ..Default::default() };
    let head = &bytes[..bytes.len().min(1024)];
    if !head.windows(5).any(|w| w == b"%PDF-") {
        return Err(Failure::not_pdf());
    }
    if bytes.len() > budget::MAX_INPUT {
        return Err(Failure::left_as_is(
            KeptReason::InputTooLarge,
            format!("PDFs over {} MB are not rewritten", budget::MAX_INPUT >> 20),
        ));
    }
    ctx.progress(0.02, Stage::Load);
    let stream_limit = load_stream_limit(bytes, &ctx)?;
    let options = LoadOptions {
        max_decompressed_size: Some(stream_limit),
        filter: Some(budget::load_filter),
        ..Default::default()
    };
    ctx.check()?;
    budget::start_load(memory_budget);
    let mut loaded = Document::load_mem_with_options(bytes, options.clone());
    // With a filter lopdf no longer rebuilds a damaged file's page tree by scanning for its
    // objects, as it does without one: done here, through the same filter, when the load came
    // back without pages.
    if loaded.as_ref().is_ok_and(|d| d.get_pages().is_empty()) && budget::loaded() <= memory_budget {
        budget::start_load(memory_budget);
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
        budget::start_load(memory_budget);
        d.objects.values().for_each(budget::count);
    }
    if budget::loaded() > memory_budget {
        return Err(budget::too_much(memory_budget));
    }
    let held = std::sync::Arc::new(budget::Held::new(budget::loaded(), memory_budget));
    let mut doc = match loaded {
        Ok(d) => d,
        Err(lopdf::Error::Decompress(lopdf::DecompressError::MemoryLimitExceeded { .. })) => {
            return Err(Failure::left_as_is(
                KeptReason::MemoryBudget,
                format!("this PDF has an object or cross-reference stream over {} KB", stream_limit >> 10),
            ));
        }
        Err(e) if is_encrypted(bytes) => {
            return Err(Failure::left_as_is(KeptReason::Encryption, format!("encrypted PDF: {e}")));
        }
        Err(e) => return Err(Failure::decode(format!("unreadable PDF: {e}"))),
    };
    if doc.is_encrypted() {
        return Err(Failure::left_as_is(KeptReason::PasswordRequired, "this PDF needs a password"));
    }
    // Set when lopdf opened the file with the empty user password: the output is encrypted
    // again with it, never left unprotected.
    let encryption = doc.encryption_state.clone();
    // Whether the file is encrypted is read from its bytes too: lopdf can drop an `/Encrypt`
    // it does not follow (pdf.js issue7665, `/CF` given by reference) and hand back undecrypted
    // strings as if the file were plain; writing that out would lose the protection and the text.
    if encryption.is_none() && names_encryption(bytes, &doc, &ctx)? {
        return Err(Failure::left_as_is(
            KeptReason::Encryption,
            "this PDF's encryption cannot be read and written again",
        ));
    }
    let handler = match &encryption {
        Some(state) => {
            let dict =
                state.encode().map_err(|e| Failure::left_as_is(KeptReason::Encryption, format!("encryption: {e}")))?;
            if dict.get(b"Filter").and_then(|f| f.as_name()).ok() != Some(b"Standard") {
                return Err(Failure::left_as_is(
                    KeptReason::Encryption,
                    "only the standard security handler is rewritten",
                ));
            }
            // From V4 on, the crypt filters /StmF and /StrF name must be defined: lopdf leaves
            // them out when `/CF` is a reference (pdf.js issue7665) and would then decrypt and
            // encrypt nothing.
            if dict.get(b"V").and_then(|v| v.as_i64()).unwrap_or(0) >= 4 {
                let cf = dict.get(b"CF").and_then(|c| c.as_dict()).ok();
                for key in [&b"StmF"[..], b"StrF"] {
                    let name = dict.get(key).and_then(|n| n.as_name()).unwrap_or(b"Identity");
                    if name != b"Identity" && !cf.is_some_and(|cf| cf.has(name)) {
                        return Err(Failure::left_as_is(
                            KeptReason::Encryption,
                            "this PDF's crypt filters cannot be read",
                        ));
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
                return Err(Failure::left_as_is(
                    KeptReason::Encryption,
                    "this PDF's per-stream encryption is not reproduced",
                ));
            }
            Some(dict)
        }
        None => None,
    };
    // A rewrite moves every byte a signature's /ByteRange covers, and Reader usage rights
    // (/Perms /UR3) are a signature too.
    if is_signed(&doc) {
        return Err(Failure::left_as_is(KeptReason::Signed, "signed: a /ByteRange signature or the catalog's /Perms"));
    }
    ctx.check()?;
    integrity::check(bytes, &doc, ctx)?;
    let input_len = bytes.len();
    drop(input);
    let pages = check_complete(&doc, &ctx)?;
    ctx.check()?;

    if strip {
        strip_metadata(&mut doc);
    }
    // Before the placement walk, so the moved images get their drawn size.
    report.inline_images_moved = inline::move_inline_images(&mut doc, ctx)?;
    // Unreachable fonts would otherwise count as used by something the font scan cannot see.
    doc.prune_objects();
    ctx.progress(0.03, Stage::Fonts);
    report.fonts_subset = fonts::subset_fonts(&mut doc, ctx, &held)?;
    ctx.check()?;
    let drawn = placement::image_resolutions(&doc, ctx)?;
    let masks = mask_ids(&doc);
    let matted = matte_parents(&doc);

    // Recompress the streams in parallel, a batch at a time (about 64 MB of stored data): each
    // batch's results replace their originals before the next starts, so the document never
    // holds old and new streams of more than one batch.
    let ids: Vec<ObjectId> =
        doc.objects.iter().filter(|(_, o)| matches!(o, Object::Stream(_))).map(|(id, _)| *id).collect();
    let done = AtomicUsize::new(0);
    let lossy = AtomicUsize::new(0);
    let (images_rewritten, streams_recompressed) = (AtomicUsize::new(0), AtomicUsize::new(0));
    let total = ids.len().max(1);
    let budget = budget::Budget::new(input_len);
    let stored = |id: &ObjectId| match doc.objects.get(id) {
        Some(Object::Stream(s)) => s.content.len(),
        _ => 0,
    };
    let mut batches: Vec<Vec<ObjectId>> = vec![Vec::new()];
    let mut size = 0;
    for id in ids {
        let n = stored(&id);
        if size + n > BATCH && !batches.last().is_some_and(Vec::is_empty) {
            batches.push(Vec::new());
            size = 0;
        }
        size += n;
        batches.last_mut().expect("one batch").push(id);
    }
    for batch in batches {
        let replaced: Vec<(ObjectId, Stream)> = batch
            .par_iter()
            .map(|id| -> Result<Option<(ObjectId, Stream)>> {
                if ctx.is_cancelled() {
                    return Err(Failure::cancelled());
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
                    if new.as_ref().is_some_and(|(n, _)| n.content.len() < s.content.len()) {
                        images_rewritten.fetch_add(1, Ordering::Relaxed);
                    }
                    new.map(|(n, _)| n)
                } else {
                    let new = recompress_stream(s, &budget)?;
                    if new.as_ref().is_some_and(|n| n.content.len() < s.content.len()) {
                        streams_recompressed.fetch_add(1, Ordering::Relaxed);
                    }
                    new
                };
                let n = done.fetch_add(1, Ordering::Relaxed) + 1;
                if n.is_multiple_of(16) {
                    ctx.progress(0.05 + 0.85 * n as f32 / total as f32, Stage::Compress);
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
    }

    ctx.check()?;
    dedupe_streams(&mut doc);
    doc.prune_objects();
    doc.renumber_objects();
    if doc.version.as_str() < "1.5" {
        doc.version = "1.5".into();
    }
    if let Some(state) = &encryption {
        doc.encrypt(state).map_err(|e| Failure::encode(format!("encrypting the PDF again: {e}")))?;
    }
    ctx.progress(0.92, Stage::Write);
    // Written to a temporary file, not memory: the document and its serialisation are not held
    // together. Read back once the document is gone.
    let spool = tempfile::tempfile().map_err(|e| Failure::internal(format!("temporary file: {e}")))?;
    let mut writer = budget::CappedWriter::new(spool, budget::max_output(input_len), ctx);
    // Strings inside an object stream are not encrypted one by one (the stream is): lopdf
    // packs objects after encrypting them, so an encrypted file keeps every object on its own.
    let packed = encryption.is_none();
    let save = SaveOptions::builder().use_object_streams(packed).use_xref_streams(packed).compression_level(9).build();
    if let Err(e) = doc.save_with_options(&mut writer, save) {
        ctx.check()?;
        return Err(if writer.written() + (1 << 20) > budget::max_output(input_len) {
            Failure::left_as_is(
                KeptReason::OutputTooLarge,
                "the rewritten PDF would be more than twice the size of the original",
            )
        } else {
            Failure::encode(format!("writing the PDF: {e}"))
        });
    }
    drop(doc);
    let out = writer.into_bytes().map_err(|e| Failure::internal(format!("reading the rewritten PDF: {e}")))?;

    ctx.check()?;
    // The result must read back with every page (its streams' data is not kept: the page tree
    // and the encryption are what is compared).
    let light = LoadOptions { filter: Some(budget::drop_stream_data), ..Default::default() };
    let back = Document::load_mem_with_options(&out, light)
        .map_err(|e| Failure::internal(format!("rewritten PDF does not load: {e}")))?;
    if back.get_pages().len() != pages {
        return Err(Failure::internal("rewritten PDF lost pages"));
    }
    // Encrypted again exactly as it was: same handler dictionary, same file key.
    if let (Some(before), Some(state)) = (&handler, &encryption) {
        let after =
            back.encryption_state.as_ref().ok_or_else(|| Failure::internal("the rewritten PDF lost its encryption"))?;
        let same_dict = after.encode().ok().as_ref() == Some(before);
        if !same_dict || after.file_encryption_key() != state.file_encryption_key() {
            return Err(Failure::internal("the rewritten PDF's encryption differs from the original's"));
        }
    }
    report.bytes_after = out.len() as u64;
    report.images_changed = lossy.load(Ordering::Relaxed);
    report.lossy = report.images_changed > 0;
    report.jpeg_quality = report.lossy.then_some(jpeg_quality);
    report.images_rewritten = images_rewritten.load(Ordering::Relaxed);
    report.streams_recompressed = streams_recompressed.load(Ordering::Relaxed);
    Ok((out, report))
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
/// count). One pass over the file: each region from a `trailer` to the next `startxref` is
/// searched once, however many `trailer` words it holds.
fn names_encryption(bytes: &[u8], doc: &Document, ctx: &Ctx) -> Result<bool> {
    if doc.trailer.has(b"Encrypt") {
        return Ok(true);
    }
    let xref_stream = doc.objects.values().any(|o| {
        matches!(o, Object::Stream(s) if s.dict.get(b"Type").and_then(|t| t.as_name()).ok() == Some(b"XRef")
            && s.dict.has(b"Encrypt"))
    });
    if xref_stream {
        return Ok(true);
    }
    trailer_names_encrypt(bytes, ctx)
}

/// Whether any `trailer` dictionary of the raw file names `/Encrypt`: each region from a
/// `trailer` to the next `startxref` is searched once.
fn trailer_names_encrypt(bytes: &[u8], ctx: &Ctx) -> Result<bool> {
    let find = |hay: &[u8], needle: &[u8]| hay.windows(needle.len()).position(|w| w == needle);
    let mut at = 0;
    while let Some(p) = find(&bytes[at..], b"trailer") {
        ctx.check()?;
        let start = at + p + 7;
        let end = find(&bytes[start..], b"startxref").map_or(bytes.len(), |e| start + e);
        if find(&bytes[start..end], b"/Encrypt").is_some() {
            return Ok(true);
        }
        at = end;
    }
    Ok(false)
}

/// Encrypted inputs over this are left as they are (see `load_stream_limit`).
const MAX_ENCRYPTED_INPUT: usize = 64 << 20;

/// The most one object or cross-reference stream may decode to while loading. lopdf loads an
/// encrypted file without `budget::load_filter`, parsing each object stream whole (several
/// times its size in memory): there the decoded bytes of all of them share 32 MB, so each gets
/// 32 MB over the number of `/ObjStm` names in the file (at most `MAX_LOAD_STREAM`). Past 512 of
/// them each would get under 64 KB, too little for a real object stream: such files, and
/// encrypted inputs over 64 MB, are left as they are.
pub(crate) fn load_stream_limit(bytes: &[u8], ctx: &Ctx) -> Result<usize> {
    if !(is_encrypted(bytes) || trailer_names_encrypt(bytes, ctx)? || xref_stream_names_encrypt(bytes)) {
        return Ok(budget::MAX_LOAD_STREAM);
    }
    if bytes.len() > MAX_ENCRYPTED_INPUT {
        return Err(Failure::left_as_is(
            KeptReason::EncryptedTooLarge,
            format!("an encrypted PDF of {} MB", bytes.len() >> 20),
        ));
    }
    let n = names_count(bytes, b"ObjStm").max(1);
    if n > 512 {
        return Err(Failure::left_as_is(KeptReason::MemoryBudget, format!("an encrypted PDF with {n} object streams")));
    }
    Ok(((32usize << 20) / n).min(budget::MAX_LOAD_STREAM))
}

/// How many PDF names in the raw bytes read `name` once `#xx` escapes are decoded.
fn names_count(bytes: &[u8], name: &[u8]) -> usize {
    name_positions(bytes, name).len()
}

/// Where each PDF name of the raw bytes that reads `name` (escapes decoded) starts.
fn name_positions(bytes: &[u8], name: &[u8]) -> Vec<usize> {
    let delimiter = |b: u8| b.is_ascii_whitespace() || b"()<>[]{}/%".contains(&b) || b == 0;
    let hex = |b: u8| (b as char).to_digit(16).map(|d| d as u8);
    let (mut n, mut i) = (Vec::new(), 0);
    while i < bytes.len() {
        if bytes[i] != b'/' {
            i += 1;
            continue;
        }
        let at = i;
        i += 1;
        let mut decoded = Vec::with_capacity(name.len() + 1);
        while i < bytes.len() && !delimiter(bytes[i]) {
            let b = match (bytes[i], bytes.get(i + 1).and_then(|b| hex(*b)), bytes.get(i + 2).and_then(|b| hex(*b))) {
                (b'#', Some(h), Some(l)) => {
                    i += 2;
                    h << 4 | l
                }
                (b, _, _) => b,
            };
            if decoded.len() <= name.len() {
                decoded.push(b);
            }
            i += 1;
        }
        if decoded == name {
            n.push(at);
        }
    }
    n
}

/// Whether a cross-reference stream's dictionary names `/Encrypt`: each `/Encrypt` name is
/// checked against the object around it (from its `obj` to its `stream` or `endobj`), each
/// object once. Its trailer keys are not near the end of the file when the stream is long.
fn xref_stream_names_encrypt(bytes: &[u8]) -> bool {
    let marks = |needle: &[u8]| -> Vec<usize> {
        let mut out = Vec::new();
        let mut i = 0;
        while let Some(p) = bytes[i..].windows(needle.len()).position(|w| w == needle) {
            out.push(i + p);
            i += p + needle.len();
        }
        out
    };
    let (objs, ends) = (marks(b"obj"), marks(b"stream"));
    let mut seen = None;
    for p in name_positions(bytes, b"Encrypt") {
        let Some(start) = objs.partition_point(|o| *o < p).checked_sub(1).map(|i| objs[i]) else { continue };
        if seen == Some(start) {
            continue;
        }
        seen = Some(start);
        let end = ends.get(ends.partition_point(|e| *e < p)).copied().unwrap_or(bytes.len());
        if names_count(&bytes[start..end], b"XRef") > 0 {
            return true;
        }
    }
    false
}

fn is_encrypted(bytes: &[u8]) -> bool {
    let tail = &bytes[bytes.len().saturating_sub(64 << 10)..];
    tail.windows(8).any(|w| w == b"/Encrypt")
}

/// Every page resolves and its content decodes, and the page tree's count agrees. Returns the
/// page count.
pub(crate) fn check_complete(doc: &Document, ctx: &Ctx) -> Result<usize> {
    let pages = doc.get_pages();
    if pages.is_empty() {
        return Err(Failure::decode("the PDF has no readable pages"));
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
        return Err(Failure::decode("the page tree is incomplete"));
    }
    for id in pages.values() {
        ctx.check()?;
        let page = doc.get_dictionary(*id).map_err(|e| Failure::decode(format!("page {id:?}: {e}")))?;
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
                .map_err(|_| Failure::decode("a page's content is missing"))?;
            if s.filters().is_ok() && s.decompressed_content_with_limit(budget::MAX_STREAM).is_err() {
                return Err(Failure::decode("a page's content does not decode"));
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
