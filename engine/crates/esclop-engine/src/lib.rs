// SPDX-License-Identifier: GPL-3.0-or-later
//! L'Esclop image engine. `engine/PROTOCOL.md` is the contract; this crate implements it.
//!
//! The binary (`main.rs`) is a thin shell: `serve` runs [`server::serve`], the one-shot form
//! calls [`respond`] once.

pub mod codec;
pub mod ctx;
pub mod error;
pub mod format;
pub mod fsio;
pub mod log;
pub mod meta;
pub mod ops;
pub mod pixels;
pub mod protocol;
pub mod quality;
pub mod schema;
pub mod server;
pub mod synth;

use ctx::Ctx;
use error::{EngineError, ErrorCode, Result};
use protocol::{ErrorBody, Features, HelloResult, Request, Response};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicUsize, Ordering};

/// Worker count `hello` reports (set by `serve`).
pub static WORKERS: AtomicUsize = AtomicUsize::new(1);

pub fn hello() -> HelloResult {
    HelloResult {
        version: env!("CARGO_PKG_VERSION").to_string(),
        protocol: protocol::PROTOCOL_VERSION,
        ops: protocol::OPS.iter().map(|s| s.to_string()).collect(),
        features: Features {
            decode: format::DECODABLE.to_vec(),
            encode: format::ENCODABLE
                .iter()
                .copied()
                .filter(|f| *f != protocol::Format::Avif || codec::avif::codec().is_some())
                .collect(),
            jpeg_codec: codec::jpeg::codec().name().to_string(),
            avif_encoder: codec::avif::codec().map(|c| c.describe()),
            gifsicle: codec::gif::find_gifsicle(),
            workers: WORKERS.load(Ordering::Relaxed),
            compression_normal: quality::NORMAL,
            compression_aggressive: quality::AGGRESSIVE,
            capabilities: ["cancel", "progress", "in_place", "ignored_params"].map(String::from).to_vec(),
        },
    }
}

/// Runs one request.
pub fn handle(req: &Request, ctx: &Ctx) -> Result<serde_json::Value> {
    let r = match req.op.as_str() {
        "hello" => return to_value(hello()),
        "probe" => ops::probe::probe(req, ctx),
        "png.optimise" => ops::optimise::png(req, ctx),
        "jpeg.optimise" => ops::optimise::jpeg(req, ctx),
        "gif.optimise" => ops::optimise::gif(req, ctx),
        "webp.encode" => ops::encode::webp(req, ctx),
        "avif.encode" => ops::encode::avif(req, ctx),
        "convert" => ops::encode::convert(req, ctx),
        "gif.from_frames" => ops::frames::from_frames(req, ctx),
        "resize" => ops::geometry::resize(req, ctx),
        "crop" => ops::geometry::crop(req, ctx),
        "metadata.strip" => ops::strip::strip(req, ctx),
        "fit" => ops::fit::fit(req, ctx),
        "cancel" => return Err(EngineError::invalid("`cancel` only applies to `serve`")),
        other => return Err(EngineError::unsupported(format!("unknown op `{other}`; `hello` lists the ops"))),
    }?;
    to_value(r)
}

fn to_value<T: serde::Serialize>(v: T) -> Result<serde_json::Value> {
    serde_json::to_value(v).map_err(|e| EngineError::internal(e.to_string()))
}

/// Runs one request and wraps the outcome, turning panics into `internal` errors.
pub fn respond(req: &Request, ctx: &Ctx) -> Response {
    let outcome = catch_unwind(AssertUnwindSafe(|| handle(req, ctx))).unwrap_or_else(|p| {
        let msg = p
            .downcast_ref::<String>()
            .cloned()
            .or_else(|| p.downcast_ref::<&str>().map(|s| s.to_string()))
            .unwrap_or_default();
        Err(EngineError::internal(format!("engine bug: {msg}")))
    });
    let outcome = match outcome {
        Err(_) if ctx.is_cancelled() => Err(EngineError::cancelled()),
        o => o,
    };
    match outcome {
        Ok(v) => Response { id: req.id.clone(), ok: true, result: Some(v), error: None },
        Err(e) => {
            if e.code == ErrorCode::Internal {
                log::error(&format!("{} {}: {}", req.op, req.id, e.message));
            }
            error_response(req.id.clone(), e)
        }
    }
}

pub fn error_response(id: serde_json::Value, e: EngineError) -> Response {
    Response { id, ok: false, result: None, error: Some(ErrorBody { code: e.code, message: e.message }) }
}
