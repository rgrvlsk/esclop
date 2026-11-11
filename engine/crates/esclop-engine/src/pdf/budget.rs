// SPDX-License-Identifier: GPL-3.0-or-later
//! Memory limits for one `pdf.optimise`, whatever the input: a file can declare a 600-megapixel
//! JPEG behind a small `/Width`, or a stream that inflates a thousandfold.
//!
//! - **Input**: files over `MAX_INPUT` are refused (`unsupported`).
//! - **One stream**: decoding a stream or an image may hold at most `MAX_STREAM` bytes; a stream
//!   that needs more is left exactly as stored.
//! - **In flight**: the streams recompressed in parallel hold at most `MAX_IN_FLIGHT` bytes
//!   between them (less for an input over 128 MB, down to 64 MB); a stream waits for room
//!   before it decodes.
//! - **Decoded in total**: past `MAX_DECODED` (or 64 times the input) the operation is refused
//!   (`unsupported`).
//! - **Written**: the output may not pass `max_output` (twice the input plus 64 MB): the writer
//!   stops and the operation is refused (`unsupported`).
//! - **Held**: the objects lopdf parses (object streams included; a stream's stored bytes are not
//!   counted, they are the input's, held once) and the font programs decoded for subsetting stay
//!   in memory together; past `MAX_HELD` the operation is refused (`unsupported`). Object and cross-reference streams decode to at most `MAX_LOAD_STREAM`
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
    EngineError::left_as_is(
        super::reasons::MEMORY,
        format!("rewriting this PDF would hold more than {} MB in memory", MAX_HELD >> 20),
    )
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

/// Counts what `o` holds into this thread's load.
pub fn count(o: &Object) {
    LOADED.with(|l| l.set(l.get().saturating_add(held(o, 0))));
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
        // The stored bytes are the input's (dropped once loaded): only the dictionary counts.
        Object::Stream(s) => s.dict.iter().map(|(k, v)| k.len() + 16 + held(v, depth + 1)).sum::<usize>(),
        _ => 0,
    }
}

pub fn max_output(input: usize) -> usize {
    input.saturating_mul(2).saturating_add(64 << 20)
}

pub struct Budget {
    /// `MAX_IN_FLIGHT`, less for a large input (whose streams are held already).
    max_in_flight: usize,
    /// `MAX_DECODED`, or 64 times the input when that is more (a 340 MB scanned book decodes
    /// 140 full pages).
    max_decoded: u64,
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
    /// For an input of `input` bytes.
    pub fn new(input: usize) -> Self {
        Self {
            max_in_flight: (384usize << 20).saturating_sub(input).clamp(64 << 20, MAX_IN_FLIGHT),
            max_decoded: MAX_DECODED.max(input as u64 * 64),
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
        if total > self.max_decoded {
            self.exhausted.store(true, Ordering::Relaxed);
            return Err(EngineError::left_as_is(
                super::reasons::MEMORY,
                format!("decoding this PDF needs more than {} GB", self.max_decoded >> 30),
            ));
        }
        let mut used = self.in_flight.lock().unwrap_or_else(|e| e.into_inner());
        while *used > 0 && *used + bytes > self.max_in_flight {
            used = self.room.wait(used).unwrap_or_else(|e| e.into_inner());
        }
        *used += bytes;
        Ok(Some(Hold { budget: self, bytes }))
    }
}

/// A buffered writer over `W` that fails past `limit` bytes, or once `cancel` is set.
pub struct CappedWriter<W: Write> {
    out: std::io::BufWriter<W>,
    written: usize,
    limit: usize,
    cancel: Arc<AtomicBool>,
}

impl<W: Write> CappedWriter<W> {
    pub fn new(out: W, limit: usize, cancel: Arc<AtomicBool>) -> Self {
        Self { out: std::io::BufWriter::with_capacity(1 << 20, out), written: 0, limit, cancel }
    }

    pub fn written(&self) -> usize {
        self.written
    }
}

impl CappedWriter<std::fs::File> {
    /// Everything written, read back from the file.
    pub fn into_bytes(self) -> std::io::Result<Vec<u8>> {
        use std::io::{Read, Seek};
        let mut file = self.out.into_inner().map_err(|e| e.into_error())?;
        file.rewind()?;
        let mut out = Vec::with_capacity(self.written);
        file.read_to_end(&mut out)?;
        Ok(out)
    }
}

impl<W: Write> Write for CappedWriter<W> {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        if self.written + data.len() > self.limit {
            return Err(std::io::Error::other("output limit reached"));
        }
        if self.cancel.load(Ordering::Relaxed) {
            return Err(std::io::Error::other("cancelled"));
        }
        self.out.write_all(data)?;
        self.written += data.len();
        Ok(data.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.out.flush()
    }
}

/// A load filter keeping every object but no stream's data: enough to count pages and read
/// the encryption. (lopdf keeps the returned object for those of object streams, which are
/// never streams, and the one it passed in for the others: see `load_filter`.)
pub fn drop_stream_data(id: (u32, u16), o: &mut Object) -> Option<((u32, u16), Object)> {
    if let Object::Stream(s) = o {
        // lopdf unpacks object streams after the filter has seen them: their data stays.
        // One byte, not none: lopdf reads an empty stream's data again from the file.
        if !matches!(s.dict.get(b"Type").and_then(|t| t.as_name()).ok(), Some(b"ObjStm" | b"XRef")) {
            s.content = vec![0];
        }
        return Some((id, Object::Null));
    }
    Some((id, o.clone()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn limits() {
        let b = Budget::new(0);
        assert!(b.hold(MAX_STREAM + 1).unwrap().is_none());
        let a = b.hold(MAX_STREAM).unwrap().unwrap();
        drop(a);
        let mut w = CappedWriter::new(Vec::new(), 4, Arc::new(AtomicBool::new(false)));
        assert!(w.write_all(b"abcd").is_ok());
        assert!(w.write_all(b"e").is_err());
    }
}

#[cfg(test)]
mod load_tests {
    use super::*;
    use std::sync::Mutex;

    static THREADS: Mutex<Vec<std::thread::ThreadId>> = Mutex::new(Vec::new());

    fn recording(id: (u32, u16), o: &mut Object) -> Option<((u32, u16), Object)> {
        THREADS.lock().unwrap().push(std::thread::current().id());
        load_filter(id, o)
    }

    /// `LOADED` is thread-local: it only adds up while lopdf calls the filter on the loading
    /// thread, which it does as long as its `rayon` feature is off (with it, a file over 16
    /// entries or 1 MB is parsed on rayon's pool). This fails if that ever changes.
    #[test]
    fn lopdf_loads_on_the_calling_thread() {
        let mut objs = crate::pdf::tests::one_page("<< >>", b"q Q");
        for i in 0..2000 {
            objs.push(crate::pdf::tests::obj(&format!("<< /N {i} /Pad ({}) >>", "x".repeat(600))));
        }
        let pdf = crate::pdf::tests::build(&objs);
        assert!(pdf.len() > 1 << 20 && objs.len() > 16, "big enough for a parallel load");
        THREADS.lock().unwrap().clear();
        start_load();
        let options = lopdf::LoadOptions { filter: Some(recording), ..Default::default() };
        let doc = lopdf::Document::load_mem_with_options(&pdf, options).unwrap();
        let me = std::thread::current().id();
        let threads = THREADS.lock().unwrap();
        assert!(threads.len() >= objs.len(), "the filter saw {} of {} objects", threads.len(), objs.len());
        assert!(threads.iter().all(|t| *t == me), "lopdf called the load filter from another thread");
        // And the count saw every object.
        let expected: usize = doc.objects.values().map(|o| held(o, 0)).sum();
        assert!(loaded() >= expected, "{} < {expected}", loaded());
    }
}
