// SPDX-License-Identifier: GPL-3.0-or-later
//! The stdio protocol: concurrent requests, out-of-order answers, progress, cancel, bad lines.

mod common;
use common::*;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};

struct Session {
    child: std::process::Child,
    stdin: std::process::ChildStdin,
    lines: std::sync::mpsc::Receiver<Value>,
}

impl Session {
    fn start(workers: usize) -> Self {
        let mut child = Command::new(bin())
            .args(["serve", "--workers", &workers.to_string()])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (tx, lines) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            for l in BufReader::new(stdout).lines() {
                let l = l.unwrap();
                let v: Value =
                    serde_json::from_str(&l).unwrap_or_else(|e| panic!("stdout must be JSON lines only: {l:?} ({e})"));
                if tx.send(v).is_err() {
                    break;
                }
            }
        });
        Session { child, stdin, lines }
    }

    fn send(&mut self, v: Value) {
        writeln!(self.stdin, "{v}").unwrap();
        self.stdin.flush().unwrap();
    }

    fn send_raw(&mut self, s: &str) {
        writeln!(self.stdin, "{s}").unwrap();
        self.stdin.flush().unwrap();
    }

    fn next(&self) -> Value {
        self.lines.recv_timeout(std::time::Duration::from_secs(120)).expect("engine answered")
    }

    fn finish(mut self) -> i32 {
        drop(self.stdin);
        self.child.wait().unwrap().code().unwrap_or(-1)
    }
}

#[test]
fn concurrent_requests_progress_and_out_of_order_answers() {
    let d = Dir::new();
    let big = d.write("big.png", &screenshot_png(2400, 1600));
    let small = d.write("small.jpg", &photo_jpeg(200, 150, 95));
    let mut s = Session::start(2);
    s.send(json!({"op": "hello"}));
    let h = s.next();
    assert_eq!(h["ok"], json!(true));
    assert_eq!(h["result"]["features"]["workers"], json!(2));

    s.send(
        json!({"id": "big", "op": "png.optimise", "input": big, "output": d.path("big-o.png"), "params": {"speed": 1}}),
    );
    s.send(json!({"id": "small", "op": "jpeg.optimise", "input": small, "output": d.path("small-o.jpg")}));
    s.send(json!({"id": 7, "op": "probe", "input": small}));
    s.send_raw("{not json");
    s.send(json!({"id": "unknown", "op": "levitate"}));

    let mut responses: HashMap<String, Value> = HashMap::new();
    let mut order = Vec::new();
    let mut progress: Vec<(String, f64)> = Vec::new();
    let mut started: Vec<String> = Vec::new();
    while responses.len() < 5 {
        let v = s.next();
        let id = match &v["id"] {
            Value::String(s) => s.clone(),
            Value::Null => "null".into(),
            other => other.to_string(),
        };
        if v["event"] == json!("started") {
            started.push(id.clone());
        } else if v["event"] == json!("progress") {
            progress.push((id, v["fraction"].as_f64().unwrap()));
        } else {
            assert!(
                !["big", "small"].contains(&id.as_str()) || started.contains(&id),
                "{id} answered without a started event"
            );
            order.push(id.clone());
            responses.insert(id, v);
        }
    }
    assert_eq!(responses["big"]["ok"], json!(true), "{}", responses["big"]);
    assert_eq!(responses["small"]["ok"], json!(true));
    assert_eq!(responses["7"]["result"]["format"], json!("jpeg"), "numeric ids are echoed");
    assert_eq!(responses["null"]["error"]["code"], json!("invalid_params"));
    assert_eq!(responses["unknown"]["error"]["code"], json!("unsupported"));
    let big_at = order.iter().position(|i| i == "big").unwrap();
    let small_at = order.iter().position(|i| i == "small").unwrap();
    assert!(small_at < big_at, "the small request finished first: {order:?}");
    let big_progress: Vec<f64> = progress.iter().filter(|p| p.0 == "big").map(|p| p.1).collect();
    assert!(!big_progress.is_empty(), "progress events for a long request");
    assert!(big_progress.windows(2).all(|w| w[0] < w[1]), "progress only goes up: {big_progress:?}");
    assert_eq!(s.finish(), 0);
}

#[test]
fn cancel_stops_a_running_request_and_writes_nothing() {
    let d = Dir::new();
    let src = d.write("p.jpg", &photo_jpeg(2400, 1800, 92));
    let out = d.path("o.webp");
    let mut s = Session::start(1);
    // fit runs many encodes and checks for cancellation between them
    s.send(json!({"id": "slow", "op": "fit", "input": src, "output": out, "params": {"target_bytes": 3000, "format": "webp", "min_scale": 0.01}}));
    s.send(json!({"id": "queued", "op": "probe", "input": src}));
    // wait until it is running, then cancel it and the queued one
    loop {
        let v = s.next();
        if v["id"] == json!("slow") && v["event"] == json!("progress") {
            break;
        }
        assert!(v["id"] != json!("slow") || v["event"].is_string(), "finished before it could be cancelled: {v}");
    }
    s.send(json!({"id": "slow", "op": "cancel"}));
    let mut got = HashMap::new();
    while got.len() < 2 {
        let v = s.next();
        if v.get("event").is_none() {
            got.insert(v["id"].as_str().unwrap().to_string(), v);
        }
    }
    assert_eq!(got["slow"]["error"]["code"], json!("cancelled"), "{}", got["slow"]);
    assert_eq!(got["queued"]["ok"], json!(true));
    assert!(!out.exists(), "a cancelled request writes nothing");
    assert!(
        std::fs::read_dir(d.0.path()).unwrap().all(|e| !e
            .unwrap()
            .file_name()
            .to_string_lossy()
            .ends_with(".esclop-tmp"))
    );
    assert_eq!(s.finish(), 0);
}

#[test]
fn duplicate_in_flight_ids_are_refused() {
    let d = Dir::new();
    let src = d.write("p.png", &screenshot_png(1600, 1200));
    let mut s = Session::start(1);
    s.send(json!({"id": "x", "op": "png.optimise", "input": src, "output": d.path("a.png"), "params": {"speed": 1}}));
    s.send(json!({"id": "x", "op": "probe", "input": src}));
    let mut codes = Vec::new();
    while codes.len() < 2 {
        let v = s.next();
        if v.get("event").is_none() {
            codes.push(if v["ok"] == json!(true) {
                "ok".to_string()
            } else {
                v["error"]["code"].as_str().unwrap().to_string()
            });
        }
    }
    codes.sort();
    assert_eq!(codes, vec!["invalid_params", "ok"]);
    assert_eq!(s.finish(), 0);
}

#[test]
fn a_queued_request_is_cancelled_at_once_and_a_started_event_marks_the_start() {
    let d = Dir::new();
    let src = d.write("p.jpg", &photo_jpeg(2400, 1800, 92));
    let mut s = Session::start(1);
    s.send(json!({"id": "slow", "op": "fit", "input": src, "output": d.path("a.webp"), "params": {"target_bytes": 3000, "format": "webp", "min_scale": 0.01}}));
    s.send(json!({"id": "queued", "op": "fit", "input": src, "output": d.path("b.webp"), "params": {"target_bytes": 3000, "format": "webp", "min_scale": 0.01}}));
    // `slow` starts (its event comes before its progress); `queued` waits for the one worker.
    loop {
        let v = s.next();
        assert_ne!(v["id"], json!("queued"), "the queued request ran or answered early: {v}");
        if v["id"] == json!("slow") && v["event"] == json!("started") {
            break;
        }
        assert!(v["event"].is_string(), "slow finished before the test could cancel: {v}");
    }
    s.send(json!({"id": "queued", "op": "cancel"}));
    // The queued request is answered now, while `slow` still runs.
    loop {
        let v = s.next();
        if v["id"] == json!("queued") {
            assert_eq!(v["error"]["code"], json!("cancelled"), "{v}");
            break;
        }
        assert!(v["event"].is_string(), "slow finished before the queued request was answered: {v}");
    }
    s.send(json!({"id": "slow", "op": "cancel"}));
    let mut answers = Vec::new();
    loop {
        let v = s.next();
        if v.get("event").is_none() {
            answers.push(v["id"].clone());
            if v["id"] == json!("slow") {
                break;
            }
        } else {
            assert_ne!(v["id"], json!("queued"), "the cancelled queued request started: {v}");
        }
    }
    assert_eq!(answers, vec![json!("slow")], "one answer per request");
    assert_eq!(s.finish(), 0);
    assert!(!d.path("b.webp").exists());
}
