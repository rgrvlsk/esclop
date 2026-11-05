// SPDX-License-Identifier: GPL-3.0-or-later
//! `engine/schema/` must match the wire types. Regenerate with
//! `cargo run -p esclop-engine -- schema schema` from `engine/`.

use std::path::Path;

#[test]
fn committed_schema_matches_the_code() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../schema");
    let mut stale = Vec::new();
    for (name, body) in esclop_engine::schema::all() {
        match std::fs::read_to_string(dir.join(&name)) {
            Ok(on_disk) if on_disk == body => {}
            _ => stale.push(name),
        }
    }
    assert!(
        stale.is_empty(),
        "stale or missing schema files {stale:?}: run `cargo run -p esclop-engine -- schema schema` in engine/"
    );
}

#[test]
fn params_schemas_name_every_field_the_engine_reads() {
    // flattened OutputParams must show up in each op's schema so `ignored_params` stays honest
    let keys = esclop_engine::ops::known_keys::<esclop_engine::protocol::PngParams>();
    for k in ["lossy", "quality", "speed", "in_place", "strip", "keep", "allow_larger", "compression"] {
        assert!(keys.iter().any(|x| x == k), "missing {k} in {keys:?}");
    }
    let keys = esclop_engine::ops::known_keys::<esclop_engine::protocol::ResizeParams>();
    for k in ["scale", "long_edge", "format", "quality", "compression", "in_place"] {
        assert!(keys.iter().any(|x| x == k), "missing {k} in {keys:?}");
    }
}
