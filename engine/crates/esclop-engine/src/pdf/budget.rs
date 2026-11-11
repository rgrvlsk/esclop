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

use crate::error::{EngineError, Result};
use std::io::Write;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Condvar, Mutex};

pub const MAX_INPUT: usize = 1 << 30;
pub const MAX_STREAM: usize = 512 << 20;
pub const MAX_IN_FLIGHT: usize = 1 << 30;
pub const MAX_DECODED: u64 = 16 << 30;

pub fn max_output(input: usize) -> usize {
    input.saturating_mul(2).saturating_add(64 << 20)
}

pub struct Budget {
    in_flight: Mutex<usize>,
    room: Condvar,
    decoded: AtomicU64,
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
        Self { in_flight: Mutex::new(0), room: Condvar::new(), decoded: AtomicU64::new(0) }
    }

    /// Room for decoding `bytes`: `Ok(None)` when one stream may not hold that much (leave it
    /// as stored), an error when the operation has decoded too much in total.
    pub fn hold(&self, bytes: usize) -> Result<Option<Hold<'_>>> {
        if bytes > MAX_STREAM {
            return Ok(None);
        }
        let total = self.decoded.fetch_add(bytes as u64, Ordering::Relaxed) + bytes as u64;
        if total > MAX_DECODED {
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

/// A `Vec` writer that fails past `limit` bytes.
pub struct CappedWriter {
    pub buf: Vec<u8>,
    limit: usize,
}

impl CappedWriter {
    pub fn new(limit: usize) -> Self {
        Self { buf: Vec::new(), limit }
    }
}

impl Write for CappedWriter {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        if self.buf.len() + data.len() > self.limit {
            return Err(std::io::Error::other("output limit reached"));
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
        let mut w = CappedWriter::new(4);
        assert!(w.write_all(b"abcd").is_ok());
        assert!(w.write_all(b"e").is_err());
    }
}
