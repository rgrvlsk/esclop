// SPDX-License-Identifier: MPL-2.0
//! The inputs fuzzing found problems with (`fuzz/regressions/<target>/`), run through the same
//! entry points: each must finish, without a panic escaping, in well under the fuzzing limit.

use std::path::Path;
use std::time::{Duration, Instant};

fn each(target: &str, run: fn(&[u8])) {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("fuzz/regressions").join(target);
    // Absent from the published package, which ships only `src`.
    let Ok(entries) = std::fs::read_dir(&dir) else { return };
    for e in entries.flatten() {
        let data = std::fs::read(e.path()).unwrap();
        let t = Instant::now();
        run(&data);
        let limit = Duration::from_secs(if cfg!(debug_assertions) { 60 } else { 10 });
        assert!(t.elapsed() < limit, "{}: {:?}", e.path().display(), t.elapsed());
    }
}

#[test]
fn cff_inputs() {
    // A Private DICT offset that overflowed when added to its size.
    each("cff", crate::fuzzing::cff);
}

#[test]
fn font_inputs() {
    // A TrueType font skera panics on (an unwrap in its glyph map): kept whole.
    each("font", crate::fuzzing::font);
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("fuzz/regressions/font/skera-glyph-map-unwrap");
    if let Ok(data) = std::fs::read(dir) {
        let gids = (0..512u16).filter(|g| g % 8 <= u16::from(data[0] % 8)).collect();
        assert!(crate::fonts::subset(&data[1..], &gids).is_err());
    }
}

#[test]
fn a_loca_claiming_gigabytes_is_not_given_to_skera() {
    // skera sized its buffer from these `loca` lengths: 11 GB.
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("fuzz/regressions/font/skera-loca-11gb-allocation");
    let Ok(data) = std::fs::read(path) else { return };
    let gids = (0..512u16).filter(|g| g % 8 <= u16::from(data[0] % 8)).collect();
    let err = crate::fonts::subset(&data[1..], &gids).unwrap_err();
    assert!(err.contains("loca"), "{err}");
}

#[test]
fn a_last_loca_offset_claiming_704_mb_is_not_given_to_skera() {
    // `Loca::len` counts glyphs, not offsets: the check once missed the last one.
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("fuzz/regressions/font/skera-last-loca-704mb-allocation");
    let Ok(data) = std::fs::read(path) else { return };
    let gids = (0..512u16).filter(|g| g % 8 <= u16::from(data[0] % 8)).collect();
    let err = crate::fonts::subset(&data[1..], &gids).unwrap_err();
    assert!(err.contains("loca"), "{err}");
}

#[test]
fn optimise_inputs() {
    each("optimise", crate::fuzzing::optimise);
}

#[test]
fn load_inputs() {
    each("load", crate::fuzzing::load);
}

#[test]
fn inline_inputs() {
    each("inline", crate::fuzzing::inline);
}
