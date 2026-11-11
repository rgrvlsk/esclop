// SPDX-License-Identifier: GPL-3.0-or-later
//! `esclop-engine serve`: JSON lines on stdin, JSON lines on stdout.
//!
//! The reader thread parses requests and handles `hello` and `cancel` itself; everything else
//! queues for a fixed pool of workers, so at most `workers` requests run at once and the rest
//! wait in arrival order. A worker taking a request sends a `started` event first (a client's
//! time limit counts from there). A `cancel` for a request still queued is answered at once;
//! one already running gets its cancel flag and answers when it stops. Every request is answered
//! exactly once. Responses may come back out of order; `id` ties them together. On end of input
//! the engine finishes what it started and exits.

use crate::ctx::Ctx;
use crate::error::EngineError;
use crate::protocol::{ProgressEvent, Request, Response};
use crate::{WORKERS, error_response, log, respond};
use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// A request's stage: queued, running, or answered by a `cancel` while it was queued.
const QUEUED: u8 = 0;
const RUNNING: u8 = 1;
const ANSWERED: u8 = 2;

#[derive(Clone)]
struct Slot {
    cancel: Arc<AtomicBool>,
    stage: Arc<AtomicU8>,
}

type Inflight = Arc<Mutex<HashMap<String, Slot>>>;

struct Job {
    req: Request,
    key: String,
    slot: Slot,
}

/// Default pool size: half the cores, between 1 and 4. Every op is itself multithreaded.
pub fn default_workers() -> usize {
    if let Some(n) = std::env::var("ESCLOP_ENGINE_WORKERS").ok().and_then(|v| v.parse::<usize>().ok()) {
        return n.clamp(1, 64);
    }
    (std::thread::available_parallelism().map(|n| n.get()).unwrap_or(2) / 2).clamp(1, 4)
}

fn send(out: &Mutex<std::io::Stdout>, line: &impl serde::Serialize) {
    let Ok(mut s) = serde_json::to_string(line) else { return };
    s.push('\n');
    let mut o = out.lock().unwrap_or_else(|e| e.into_inner());
    // A closed stdout means the client went away; requests in flight still finish cleanly.
    let _ = o.write_all(s.as_bytes()).and_then(|_| o.flush());
}

fn id_key(id: &serde_json::Value) -> String {
    match id {
        serde_json::Value::String(s) => s.clone(),
        serde_json::Value::Null => String::new(),
        other => other.to_string(),
    }
}

pub fn serve(workers: usize) -> i32 {
    let workers = workers.max(1);
    WORKERS.store(workers, Ordering::Relaxed);
    let out = Arc::new(Mutex::new(std::io::stdout()));
    let inflight: Inflight = Arc::default();
    let (tx, rx) = mpsc::channel::<Job>();
    let rx = Arc::new(Mutex::new(rx));
    let pool: Vec<_> = (0..workers)
        .map(|_| {
            let (rx, out, inflight) = (rx.clone(), out.clone(), inflight.clone());
            std::thread::spawn(move || {
                loop {
                    let job = { rx.lock().unwrap_or_else(|e| e.into_inner()).recv() };
                    let Ok(job) = job else { break };
                    run_job(job, &out, &inflight);
                }
            })
        })
        .collect();

    let stdin = std::io::stdin();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let req: Request = match serde_json::from_str(line) {
            Ok(r) => r,
            Err(e) => {
                let id = serde_json::from_str::<serde_json::Value>(line)
                    .ok()
                    .and_then(|v| v.get("id").cloned())
                    .unwrap_or_default();
                send(&out, &error_response(id, EngineError::invalid(format!("bad request line: {e}"))));
                continue;
            }
        };
        let key = id_key(&req.id);
        match req.op.as_str() {
            "cancel" => {
                let mut map = inflight.lock().unwrap_or_else(|e| e.into_inner());
                match map.get(&key).cloned() {
                    Some(slot)
                        if slot
                            .stage
                            .compare_exchange(QUEUED, ANSWERED, Ordering::AcqRel, Ordering::Acquire)
                            .is_ok() =>
                    {
                        map.remove(&key);
                        drop(map);
                        send(&out, &error_response(req.id.clone(), EngineError::cancelled()));
                    }
                    Some(slot) => slot.cancel.store(true, Ordering::Relaxed),
                    None => log::debug(&format!("cancel: no request {key} in flight")),
                }
            }
            "hello" => send(&out, &respond(&req, &Ctx::silent())),
            _ => {
                let slot = Slot { cancel: Arc::new(AtomicBool::new(false)), stage: Arc::new(AtomicU8::new(QUEUED)) };
                {
                    let mut map = inflight.lock().unwrap_or_else(|e| e.into_inner());
                    if !key.is_empty() && map.contains_key(&key) {
                        send(
                            &out,
                            &error_response(
                                req.id.clone(),
                                EngineError::invalid(format!("a request with id {key} is already in flight")),
                            ),
                        );
                        continue;
                    }
                    if !key.is_empty() {
                        map.insert(key.clone(), slot.clone());
                    }
                }
                if tx.send(Job { req, key, slot }).is_err() {
                    break;
                }
            }
        }
    }
    drop(tx);
    for t in pool {
        let _ = t.join();
    }
    0
}

fn run_job(job: Job, out: &Arc<Mutex<std::io::Stdout>>, inflight: &Inflight) {
    // Answered already: cancelled while it waited.
    if job.slot.stage.compare_exchange(QUEUED, RUNNING, Ordering::AcqRel, Ordering::Acquire).is_err() {
        return;
    }
    let id = job.req.id.clone();
    send(out, &ProgressEvent { id: id.clone(), event: "started".into(), fraction: 0.0, stage: None });
    let progress_out = out.clone();
    let state = Mutex::new((0.0f32, Instant::now() - Duration::from_secs(1)));
    let progress = move |fraction: f32, stage: &str| {
        let mut s = state.lock().unwrap_or_else(|e| e.into_inner());
        // non-decreasing, at most every 100 ms or 5 %
        if fraction <= s.0 || (fraction - s.0 < 0.05 && s.1.elapsed() < Duration::from_millis(100)) {
            return;
        }
        *s = (fraction, Instant::now());
        drop(s);
        send(
            &progress_out,
            &ProgressEvent { id: id.clone(), event: "progress".into(), fraction, stage: Some(stage.to_string()) },
        );
    };
    let ctx = Ctx::new(job.slot.cancel.clone(), Arc::new(progress));
    let started = Instant::now();
    let resp: Response = if job.slot.cancel.load(Ordering::Relaxed) {
        error_response(job.req.id.clone(), EngineError::cancelled())
    } else {
        respond(&job.req, &ctx)
    };
    log::debug(&format!("{} {} done in {:?} ok={}", job.req.op, job.key, started.elapsed(), resp.ok));
    if !job.key.is_empty() {
        inflight.lock().unwrap_or_else(|e| e.into_inner()).remove(&job.key);
    }
    send(out, &resp);
}
