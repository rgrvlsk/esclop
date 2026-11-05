// SPDX-License-Identifier: GPL-3.0-or-later
//! `esclop-engine serve [--workers N]`
//! `esclop-engine <op> --json '<request or params>' [--progress]`
//! `esclop-engine schema <dir>`
//! `esclop-engine --version`

use esclop_engine::ctx::Ctx;
use esclop_engine::protocol::{ProgressEvent, Request};
use esclop_engine::{error::EngineError, error_response, respond, schema, server};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;

const USAGE: &str = "usage:
  esclop-engine serve [--workers N]          JSON lines on stdin/stdout (see engine/PROTOCOL.md)
  esclop-engine <op> --json '<json>' [--progress]
                                             one request; <json> is a request object
                                             ({\"input\",\"output\",\"params\"}) or its params with
                                             \"input\"/\"output\" inline; '-' reads stdin
  esclop-engine schema <dir>                 write the JSON Schemas
  esclop-engine --version";

fn main() {
    without_large_malloc_cache();
    std::process::exit(run(std::env::args().skip(1).collect()));
}

/// macOS's allocator keeps freed large blocks cached for reuse. The engine allocates image-sized
/// buffers of a different size for every image (and every `fit` probe), so the cache rarely gets
/// a hit and the footprint only grows: four resizes of a 24-megapixel JPEG at different scales
/// peak at 418 MB with it and 207 MB without. The switch is read when the allocator starts, so
/// the engine re-executes itself once with it set.
fn without_large_malloc_cache() {
    #[cfg(target_os = "macos")]
    if std::env::var_os("MallocLargeCache").is_none() {
        use std::os::unix::process::CommandExt;
        if let Ok(exe) = std::env::current_exe() {
            let err =
                std::process::Command::new(exe).args(std::env::args_os().skip(1)).env("MallocLargeCache", "0").exec();
            // exec returns only on failure; carry on with the cache
            esclop_engine::log::warn(&format!("could not re-execute without the large-block cache: {err}"));
        }
    }
}

fn run(args: Vec<String>) -> i32 {
    match args.first().map(String::as_str) {
        None | Some("-h" | "--help" | "help") => {
            println!("{USAGE}");
            if args.is_empty() { 2 } else { 0 }
        }
        Some("-V" | "--version" | "version") => {
            println!(
                "esclop-engine {} (protocol {})",
                env!("CARGO_PKG_VERSION"),
                esclop_engine::protocol::PROTOCOL_VERSION
            );
            0
        }
        Some("serve") => {
            let workers =
                flag_value(&args, "--workers").and_then(|v| v.parse().ok()).unwrap_or_else(server::default_workers);
            server::serve(workers)
        }
        Some("schema") => {
            let Some(dir) = args.get(1) else {
                eprintln!("{USAGE}");
                return 2;
            };
            match schema::write(&PathBuf::from(dir)) {
                Ok(()) => 0,
                Err(e) => {
                    eprintln!("esclop-engine: {e}");
                    1
                }
            }
        }
        Some(op) => one_shot(op, &args),
    }
}

fn flag_value<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).map(String::as_str)
}

fn one_shot(op: &str, args: &[String]) -> i32 {
    let raw = match flag_value(args, "--json") {
        Some("-") => {
            let mut s = String::new();
            let _ = std::io::Read::read_to_string(&mut std::io::stdin(), &mut s);
            s
        }
        Some(s) => s.to_string(),
        None if op == "hello" => "{}".to_string(),
        None => {
            eprintln!("{USAGE}");
            return 2;
        }
    };
    let req = match build_request(op, &raw) {
        Ok(r) => r,
        Err(e) => {
            println!("{}", serde_json::to_string(&error_response(serde_json::Value::Null, e)).unwrap());
            return 1;
        }
    };
    let ctx = if args.iter().any(|a| a == "--progress") {
        let id = req.id.clone();
        Ctx::new(
            Arc::new(AtomicBool::new(false)),
            Arc::new(move |fraction, stage: &str| {
                let ev =
                    ProgressEvent { id: id.clone(), event: "progress".into(), fraction, stage: Some(stage.into()) };
                eprintln!("{}", serde_json::to_string(&ev).unwrap_or_default());
            }),
        )
    } else {
        Ctx::silent()
    };
    let resp = respond(&req, &ctx);
    println!("{}", serde_json::to_string(&resp).unwrap_or_default());
    if resp.ok { 0 } else { 1 }
}

/// Accepts a whole request or params with `input`/`output` inline. Relative paths are resolved
/// against the working directory (the stdio protocol itself requires absolute paths).
fn build_request(op: &str, raw: &str) -> Result<Request, EngineError> {
    let mut v: serde_json::Value =
        serde_json::from_str(raw).map_err(|e| EngineError::invalid(format!("--json: {e}")))?;
    let obj = v.as_object_mut().ok_or_else(|| EngineError::invalid("--json must be an object"))?;
    let take = |obj: &mut serde_json::Map<String, serde_json::Value>, k: &str| obj.remove(k);
    let id = take(obj, "id").unwrap_or(serde_json::Value::Null);
    let input = take(obj, "input").and_then(|v| v.as_str().map(abs));
    let output = take(obj, "output").and_then(|v| v.as_str().map(abs));
    obj.remove("op");
    let params = match take(obj, "params") {
        Some(p) => p,
        None => serde_json::Value::Object(obj.clone()),
    };
    let mut params = params;
    if let Some(d) = params.get_mut("frames_dir")
        && let Some(s) = d.as_str()
    {
        *d = serde_json::Value::String(abs(s).to_string_lossy().into_owned());
    }
    Ok(Request { id, op: op.to_string(), input, output, params })
}

fn abs(p: &str) -> PathBuf {
    let p = PathBuf::from(p);
    if p.is_absolute() { p } else { std::env::current_dir().map(|d| d.join(&p)).unwrap_or(p) }
}
