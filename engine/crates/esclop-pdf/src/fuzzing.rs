// SPDX-License-Identifier: MPL-2.0
//! Entry points for the cargo-fuzz targets in `fuzz/` (feature `fuzzing`). Not part of the
//! public interface: they may change in any release.

use crate::{Ctx, Options, budget, cff, fonts, inline, integrity, rewrite};
use lopdf::{Document, LoadOptions};
use std::collections::BTreeSet;

/// libfuzzer-sys aborts on every panic, caught or not. The font subsetter catches skera's (a
/// dependency that unwraps a glyph-map entry a malformed font may lack) and keeps that font
/// whole; those are let through, every other panic still aborts.
fn tolerate_caught_dependency_panics() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let abort = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            if info.location().is_some_and(|l| l.file().contains("/skera-")) {
                return;
            }
            abort(info);
        }));
    });
}

/// The whole rewrite: at the default settings, or (for inputs of odd length) at aggressive ones
/// with downsampling to 72 dpi and metadata stripped. One rewrite per input.
pub fn optimise(data: &[u8]) {
    tolerate_caught_dependency_panics();
    let options = if data.len().is_multiple_of(2) {
        Options::default()
    } else {
        Options::builder().aggressive().max_dpi(72).strip_metadata(true).build().expect("valid")
    };
    let _ = crate::optimise(data.to_vec(), &options);
}

/// Loading as the rewrite does (load filter, stream limits, page-tree rebuild) and the checks
/// that follow: integrity against the raw bytes, every page complete.
pub fn load(data: &[u8]) {
    let ctx = Ctx::silent();
    let Ok(limit) = rewrite::load_stream_limit(data, &ctx) else { return };
    let options =
        LoadOptions { max_decompressed_size: Some(limit), filter: Some(budget::load_filter), ..Default::default() };
    budget::start_load(Options::DEFAULT_MEMORY_BUDGET);
    let Ok(doc) = Document::load_mem_with_options(data, options) else { return };
    if budget::loaded() > Options::DEFAULT_MEMORY_BUDGET {
        return;
    }
    if integrity::check(data, &doc, ctx).is_ok() {
        let _ = rewrite::check_complete(&doc, &ctx);
    }
}

/// The CFF subsetter on a bare CFF program: every other glyph kept, and only `.notdef`.
pub fn cff(data: &[u8]) {
    let n = cff::glyph_count(data).unwrap_or(0).min(4096);
    let _ = cff::cids(data);
    let _ = cff::charstrings(data);
    for keep in [|g: usize| g.is_multiple_of(2), |g: usize| g == 0] {
        let gids: BTreeSet<u16> = (0..n).filter(|g| keep(*g)).map(|g| g as u16).collect();
        let _ = cff::seac_components(data, &gids);
        let _ = cff::subset(data, &keep);
    }
}

/// The font subsetter (TrueType through skera, CFF in an OpenType wrapper through `cff`) on a
/// font program: the first byte picks which glyphs to keep.
pub fn font(data: &[u8]) {
    tolerate_caught_dependency_panics();
    let Some((&pick, font)) = data.split_first() else { return };
    let gids: BTreeSet<u16> = (0..512u16).filter(|g| (g % 8) as u8 <= pick % 8).collect();
    let _ = fonts::subset(font, &gids);
}

/// Inline-image extraction: `data` as the content of a one-page PDF whose inline images are
/// moved into image objects.
pub fn inline(data: &[u8]) {
    use lopdf::{Dictionary, Object, Stream};
    let mut doc = Document::with_version("1.7");
    let content = doc.add_object(Stream::new(Dictionary::new(), data.to_vec()));
    let pages = doc.new_object_id();
    let mut page = Dictionary::new();
    page.set("Type", Object::Name(b"Page".to_vec()));
    page.set("Parent", pages);
    page.set("Contents", content);
    page.set("Resources", Dictionary::new());
    page.set("MediaBox", vec![0.into(), 0.into(), 612.into(), 792.into()]);
    let page = doc.add_object(page);
    let mut tree = Dictionary::new();
    tree.set("Type", Object::Name(b"Pages".to_vec()));
    tree.set("Kids", vec![page.into()]);
    tree.set("Count", 1);
    doc.objects.insert(pages, Object::Dictionary(tree));
    let mut catalog = Dictionary::new();
    catalog.set("Type", Object::Name(b"Catalog".to_vec()));
    catalog.set("Pages", pages);
    let catalog = doc.add_object(catalog);
    doc.trailer.set("Root", catalog);
    let _ = inline::move_inline_images(&mut doc, Ctx::silent());
}
