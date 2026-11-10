// SPDX-License-Identifier: GPL-3.0-or-later
//! JSON Schema files for `engine/schema/`, generated from the wire types.

use crate::protocol::*;
use schemars::{JsonSchema, SchemaGenerator};

fn one<T: JsonSchema>() -> String {
    let s = SchemaGenerator::default().into_root_schema_for::<T>();
    serde_json::to_string_pretty(&s).expect("schema serialises") + "\n"
}

/// (file name, contents) for every schema, in a stable order.
pub fn all() -> Vec<(String, String)> {
    let mut v = vec![
        ("request.schema.json".to_string(), one::<Request>()),
        ("response.schema.json".to_string(), one::<Response>()),
        ("progress.schema.json".to_string(), one::<ProgressEvent>()),
        ("result.schema.json".to_string(), one::<OpResult>()),
        ("hello-result.schema.json".to_string(), one::<HelloResult>()),
    ];
    let params: [(&str, String); 13] = [
        ("probe", one::<ProbeParams>()),
        ("png.optimise", one::<PngParams>()),
        ("jpeg.optimise", one::<JpegParams>()),
        ("webp.encode", one::<WebpParams>()),
        ("avif.encode", one::<AvifParams>()),
        ("gif.optimise", one::<GifParams>()),
        ("gif.from_frames", one::<GifFramesParams>()),
        ("resize", one::<ResizeParams>()),
        ("crop", one::<CropParams>()),
        ("metadata.strip", one::<StripParams>()),
        ("convert", one::<ConvertParams>()),
        ("fit", one::<FitParams>()),
        ("pdf.optimise", one::<PdfParams>()),
    ];
    v.extend(params.into_iter().map(|(op, s)| (format!("params/{op}.schema.json"), s)));
    v
}

/// Writes every schema under `dir`.
pub fn write(dir: &std::path::Path) -> std::io::Result<()> {
    for (name, body) in all() {
        let p = dir.join(name);
        if let Some(parent) = p.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(p, body)?;
    }
    Ok(())
}
