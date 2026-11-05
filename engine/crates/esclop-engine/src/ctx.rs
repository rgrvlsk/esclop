// SPDX-License-Identifier: GPL-3.0-or-later
//! Per-request context: the cancel flag and the progress sink.

use crate::error::{EngineError, Result};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

pub type ProgressFn = dyn Fn(f32, &str) + Send + Sync;

#[derive(Clone)]
pub struct Ctx {
    cancel: Arc<AtomicBool>,
    progress: Arc<ProgressFn>,
}

impl Ctx {
    pub fn new(cancel: Arc<AtomicBool>, progress: Arc<ProgressFn>) -> Self {
        Self { cancel, progress }
    }

    /// A context that never reports progress and is never cancelled (tests, one-shot without --progress).
    pub fn silent() -> Self {
        Self::new(Arc::new(AtomicBool::new(false)), Arc::new(|_, _| {}))
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancel.load(Ordering::Relaxed)
    }

    pub fn cancel_flag(&self) -> Arc<AtomicBool> {
        self.cancel.clone()
    }

    /// Returns `cancelled` once the client asked to stop. Called between stages.
    pub fn check(&self) -> Result<()> {
        if self.is_cancelled() { Err(EngineError::cancelled()) } else { Ok(()) }
    }

    /// Reports progress in 0..=1 with a short stage name.
    pub fn progress(&self, fraction: f32, stage: &str) {
        (self.progress)(fraction.clamp(0.0, 1.0), stage);
    }

    /// A context whose progress is mapped into `[start, end]` of this one, for sub-steps.
    pub fn sub(&self, start: f32, end: f32) -> Ctx {
        let parent = self.progress.clone();
        Ctx {
            cancel: self.cancel.clone(),
            progress: Arc::new(move |f, s| parent(start + (end - start) * f.clamp(0.0, 1.0), s)),
        }
    }
}
