// SPDX-License-Identifier: GPL-3.0-or-later
//! Memory limits for one `pdf.optimise`, whatever the input: a file can declare a 600-megapixel
//! JPEG behind a small `/Width`, or a stream that inflates a thousandfold.
//!
//! - **Input**: files over `MAX_INPUT` are refused (`unsupported`).
//! - **One stream**: decoding a stream or an image may hold at most `MAX_STREAM` bytes; a stream
//!   that needs more is left exactly as stored.
//! - **In flight**: the streams recompressed in parallel hold at most `MAX_IN_FLIGHT` bytes
//!   between them; a stream waits for room before it decodes.
//! - **Decoded in total**: past `MAX_DECODED` the operation is refused (`unsupported`).
//! - **Written**: the output may not pass `max_output` (twice the input plus 64 MB): the writer
//!   stops and the operation is refused (`unsupported`).
//! - **Held**: the objects lopdf parses (object streams included) and the font programs decoded
//!   for subsetting stay in memory together; past `MAX_HELD` the operation is refused
//!   (`unsupported`). Object and cross-reference streams decode to at most `MAX_LOAD_STREAM`
//!   (the largest in the benchmark corpus is 12.4 MB): their objects parse into several times
//!   their size before the filter sees them.

use crate::error::{EngineError, Result};
use lopdf::Object;
use std::io::Write;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Condvar, Mutex};

pub const MAX_INPUT: usize = 1 << 30;
pub const MAX_STREAM: usize = 384 << 20;
pub const MAX_IN_FLIGHT: usize = 256 << 20;
pub const MAX_DECODED: u64 = 16 << 30;
pub const MAX_HELD: usize = 256 << 20;
pub const MAX_LOAD_STREAM: usize = 16 << 20;

/// What a document may still hold (see `MAX_HELD`), shared by the stages that keep decoded data.
pub struct Held(AtomicUsize);

impl Held {
    pub fn new(used: usize) -> Self {
        Self(AtomicUsize::new(used))
    }

    /// What is left.
    pub fn room(&self) -> usize {
        MAX_HELD.saturating_sub(self.0.load(Ordering::Relaxed))
    }

    /// Takes `bytes` more; an error once the document would hold more than `MAX_HELD`.
    pub fn take(&self, bytes: usize) -> Result<()> {
        if self.0.fetch_add(bytes, Ordering::Relaxed).saturating_add(bytes) > MAX_HELD {
            return Err(too_much());
        }
        Ok(())
    }
}

pub fn too_much() -> EngineError {
    EngineError::unsupported(format!("rewriting this PDF would hold more than {} MB in memory", MAX_HELD >> 20))
}

thread_local! {
    /// Bytes the objects parsed so far by `load_filter` hold, on this thread's load.
    static LOADED: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

/// Starts counting a load on this thread.
pub fn start_load() {
    LOADED.with(|l| l.set(0));
}

/// What the load counted: the bytes its objects hold, more than `MAX_HELD` when it stopped
/// keeping them.
pub fn loaded() -> usize {
    LOADED.with(|l| l.get())
}

/// lopdf's load filter: counts what each object holds and drops objects past `MAX_HELD`, so a
/// file whose object streams parse into gigabytes stops growing (the load is then refused).
/// lopdf ignores the returned object for top-level objects and keeps it for those of object
/// streams, which never hold streams.
pub fn load_filter(id: (u32, u16), o: &mut Object) -> Option<((u32, u16), Object)> {
    let total = LOADED.with(|l| {
        let t = l.get().saturating_add(held(o, 0));
        l.set(t);
        t
    });
    if total > MAX_HELD {
        return None;
    }
    Some((id, if matches!(o, Object::Stream(_)) { Object::Null } else { o.clone() }))
}

/// Roughly what an object holds in memory.
fn held(o: &Object, depth: usize) -> usize {
    const NODE: usize = std::mem::size_of::<Object>();
    if depth > 64 {
        return NODE;
    }
    NODE + match o {
        Object::String(s, _) | Object::Name(s) => s.len(),
        Object::Array(a) => a.iter().map(|o| held(o, depth + 1)).sum(),
        Object::Dictionary(d) => d.iter().map(|(k, v)| k.len() + 16 + held(v, depth + 1)).sum(),
        Object::Stream(s) => {
            s.content.len() + s.dict.iter().map(|(k, v)| k.len() + 16 + held(v, depth + 1)).sum::<usize>()
        }
        _ => 0,
    }
}

pub fn max_output(input: usize) -> usize {
    input.saturating_mul(2).saturating_add(64 << 20)
}

pub struct Budget {
    in_flight: Mutex<usize>,
    room: Condvar,
    decoded: AtomicU64,
    exhausted: AtomicBool,
}

/// Bytes held until dropped.
pub struct Hold<'a> {
    budget: &'a Budget,
    bytes: usize,
}

impl Drop for Hold<'_> {
    fn drop(&mut self) {
        let mut used = self.budget.in_flight.lock().unwrap_or_else(|e| e.into_inner());
        *used -= self.bytes;
        self.budget.room.notify_all();
    }
}

impl Budget {
    pub fn new() -> Self {
        Self {
            in_flight: Mutex::new(0),
            room: Condvar::new(),
            decoded: AtomicU64::new(0),
            exhausted: AtomicBool::new(false),
        }
    }

    /// Whether the operation decoded more than `MAX_DECODED` (the one image error that stops
    /// the whole file; any other leaves that image as stored).
    pub fn exhausted(&self) -> bool {
        self.exhausted.load(Ordering::Relaxed)
    }

    /// Room for decoding `bytes`: `Ok(None)` when one stream may not hold that much (leave it
    /// as stored), an error when the operation has decoded too much in total.
    pub fn hold(&self, bytes: usize) -> Result<Option<Hold<'_>>> {
        if bytes > MAX_STREAM {
            return Ok(None);
        }
        let total = self.decoded.fetch_add(bytes as u64, Ordering::Relaxed) + bytes as u64;
        if total > MAX_DECODED {
            self.exhausted.store(true, Ordering::Relaxed);
            return Err(EngineError::unsupported(format!(
                "decoding this PDF needs more than {} GB",
                MAX_DECODED >> 30
            )));
        }
        let mut used = self.in_flight.lock().unwrap_or_else(|e| e.into_inner());
        while *used > 0 && *used + bytes > MAX_IN_FLIGHT {
            used = self.room.wait(used).unwrap_or_else(|e| e.into_inner());
        }
        *used += bytes;
        Ok(Some(Hold { budget: self, bytes }))
    }
}

/// A `Vec` writer that fails past `limit` bytes, or once `cancel` is set.
pub struct CappedWriter {
    pub buf: Vec<u8>,
    limit: usize,
    cancel: Arc<AtomicBool>,
}

impl CappedWriter {
    pub fn new(limit: usize, cancel: Arc<AtomicBool>) -> Self {
        Self { buf: Vec::new(), limit, cancel }
    }
}

impl Write for CappedWriter {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        if self.buf.len() + data.len() > self.limit {
            return Err(std::io::Error::other("output limit reached"));
        }
        if self.cancel.load(Ordering::Relaxed) {
            return Err(std::io::Error::other("cancelled"));
        }
        self.buf.extend_from_slice(data);
        Ok(data.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn limits() {
        let b = Budget::new();
        assert!(b.hold(MAX_STREAM + 1).unwrap().is_none());
        let a = b.hold(MAX_STREAM).unwrap().unwrap();
        drop(a);
        let mut w = CappedWriter::new(4, Arc::new(AtomicBool::new(false)));
        assert!(w.write_all(b"abcd").is_ok());
        assert!(w.write_all(b"e").is_err());
    }
}
