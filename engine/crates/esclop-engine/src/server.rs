// SPDX-License-Identifier: GPL-3.0-or-later
//! `esclop-engine serve`: JSON lines on stdin, JSON lines on stdout.
//!
//! The reader thread parses requests and handles `hello` and `cancel` itself; everything else
//! queues for a fixed pool of workers, so at most `workers` requests run at once and the rest
//! wait in arrival order. Responses may come back out of order; `id` ties them together. On end
//! of input the engine finishes what it started and exits.

use crate::ctx::Ctx;
use crate::error::EngineError;
use crate::protocol::{ProgressEvent, Request, Response};
use crate::{WORKERS, error_response, log, respond};
use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

type Inflight = Arc<Mutex<HashMap<String, Arc<AtomicBool>>>>;

struct Job {
    req: Request,
    key: String,
    cancel: Arc<AtomicBool>,
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
            "cancel" => match inflight.lock().unwrap_or_else(|e| e.into_inner()).get(&key) {
                Some(flag) => flag.store(true, Ordering::Relaxed),
                None => log::debug(&format!("cancel: no request {key} in flight")),
            },
            "hello" => send(&out, &respond(&req, &Ctx::silent())),
            _ => {
                let cancel = Arc::new(AtomicBool::new(false));
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
                        map.insert(key.clone(), cancel.clone());
                    }
                }
                if tx.send(Job { req, key, cancel }).is_err() {
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
    let id = job.req.id.clone();
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
    let ctx = Ctx::new(job.cancel.clone(), Arc::new(progress));
    let started = Instant::now();
    let resp: Response = if job.cancel.load(Ordering::Relaxed) {
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
